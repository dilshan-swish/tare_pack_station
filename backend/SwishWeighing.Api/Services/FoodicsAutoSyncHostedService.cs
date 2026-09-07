using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Services;

/// <summary>
/// Keeps every brand's synced menu from drifting out of date with Foodics'
/// own catalog without relying on an admin remembering to click "Sync
/// Foodics" in the portal. Without this, a product added in Foodics (or
/// renamed/deactivated there) simply never reaches <c>MenuItems</c> until
/// someone notices and syncs manually — which is exactly what happened when
/// a tablet showed "Unknown item" for a product ("Old Skool Deal") that
/// existed in Foodics but had never been pulled into head office's DB.
///
/// Two paths keep the catalog current — only the first is required, and it
/// needs zero setup beyond deploying with Foodics brand tokens configured
/// (already required for every other Foodics call this app makes):
///  - Primary: every active brand is swept on a fixed interval (default 5
///    min — see <see cref="FoodicsOptions.AutoSyncIntervalMinutes"/>), so a
///    product added in Foodics reaches this app's own database — and is
///    visible to an admin opening the portal to set its weight — without
///    anyone ever touching "Sync Foodics" by hand. This alone is enough for
///    "new items show up automatically to be weighed"; nothing else needs to
///    be configured for it to work once deployed.
///  - Optional fast path: IF a Foodics webhook is ever registered (see
///    WebhooksController — requires emailing support@foodics.com, a step
///    outside this app), <see cref="IFoodicsSyncQueue"/> lets that specific
///    brand react within moments instead of waiting for the sweep. Nothing
///    breaks or needs reconfiguring if this is never set up — the queue
///    simply never receives anything, and the sweep alone keeps everything
///    current.
///
/// One brand's failure (missing token, Foodics hiccup) never blocks the
/// others or crashes the app — each is caught and logged individually, same
/// as the tablet's own "a head-office hiccup keeps the last-known-good data"
/// philosophy.
/// </summary>
public class FoodicsAutoSyncHostedService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IFoodicsSyncQueue _queue;
    private readonly ILogger<FoodicsAutoSyncHostedService> _log;
    private readonly TimeSpan _interval;

    // This is the ONLY mechanism most deployments rely on (no webhook set
    // up) — 5 minutes keeps "add a product in Foodics" to "visible in the
    // portal to weigh" comfortably within the time it takes staff to
    // actually switch over and look, without polling Foodics' API
    // excessively often across every configured brand.
    private static readonly TimeSpan DefaultInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan StartupDelay = TimeSpan.FromMinutes(1);

    public FoodicsAutoSyncHostedService(
        IServiceScopeFactory scopeFactory,
        IFoodicsSyncQueue queue,
        IOptions<FoodicsOptions> opts,
        ILogger<FoodicsAutoSyncHostedService> log)
    {
        _scopeFactory = scopeFactory;
        _queue = queue;
        _log = log;
        _interval = opts.Value.AutoSyncIntervalMinutes > 0
            ? TimeSpan.FromMinutes(opts.Value.AutoSyncIntervalMinutes)
            : DefaultInterval;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // The queue drain and the periodic sweep are two independent loops —
        // a webhook arriving mid-sweep must react immediately, not wait for
        // the sweep to finish first.
        var drain = DrainQueueAsync(stoppingToken);
        var sweep = PeriodicSweepAsync(stoppingToken);
        await Task.WhenAll(drain, sweep);
    }

    private async Task DrainQueueAsync(CancellationToken ct)
    {
        try
        {
            await foreach (var brandId in _queue.ReadAllAsync(ct))
            {
                // Fire-and-forget per brand so a slow sync for one brand
                // never delays reacting to the next queued brand; MarkDone
                // (in the finally below) is what lets that SAME brand be
                // queued again later, so this never overlaps itself.
                _ = SyncOneBrandSafeAsync(brandId, "webhook", ct);
            }
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown.
        }
    }

    private async Task PeriodicSweepAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(StartupDelay, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            await SweepAllBrandsAsync(stoppingToken);
            try
            {
                await Task.Delay(_interval, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task SweepAllBrandsAsync(CancellationToken ct)
    {
        List<int> brandIds;
        using (var scope = _scopeFactory.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            try
            {
                brandIds = await db.Brands.Where(b => b.IsActive).Select(b => b.BrandId).ToListAsync(ct);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "FoodicsAutoSync: could not load brand list, skipping this cycle");
                return;
            }
        }

        foreach (var brandId in brandIds)
        {
            if (ct.IsCancellationRequested) return;
            await SyncOneBrandSafeAsync(brandId, "sweep", ct);
        }
    }

    /// <summary>
    /// Syncs one brand end to end in a single scope — <c>brand</c> and the
    /// <see cref="FoodicsService"/> doing the sync MUST share the same
    /// <see cref="AppDbContext"/> instance, otherwise mutations SyncBrandAsync
    /// makes directly on the Brand entity (FoodicsAccount, MenuSyncedVersion,
    /// UpdatedAt) are invisible to that context's SaveChangesAsync and are
    /// silently dropped. Never throws; always releases the queue's pending
    /// guard for this brand so a later webhook for it can be queued again.
    /// </summary>
    private async Task SyncOneBrandSafeAsync(int brandId, string trigger, CancellationToken ct)
    {
        try
        {
            using var scope = _scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var brand = await db.Brands.FindAsync(new object?[] { brandId }, ct);
            if (brand is null || !brand.IsActive) return;

            var foodics = scope.ServiceProvider.GetRequiredService<FoodicsService>();
            var result = await foodics.SyncBrandAsync(brand, ct);
            if (result.ItemsAdded > 0 || result.ItemsUpdated > 0 || result.ModifiersAdded > 0)
            {
                _log.LogInformation(
                    "FoodicsAutoSync ({Trigger}): {Code} — {Added} item(s) added, {Updated} updated, {ModAdded} modifier(s) added",
                    trigger, brand.Code, result.ItemsAdded, result.ItemsUpdated, result.ModifiersAdded);
            }
        }
        catch (InvalidOperationException)
        {
            // No Foodics token configured for this brand — expected for
            // brands that aren't Foodics-connected yet, not worth logging
            // every cycle.
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "FoodicsAutoSync ({Trigger}): sync failed for brand {BrandId}", trigger, brandId);
        }
        finally
        {
            _queue.MarkDone(brandId);
        }
    }
}
