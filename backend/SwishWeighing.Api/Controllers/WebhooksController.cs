using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Services;

namespace SwishWeighing.Api.Controllers;

/// <summary>
/// OPTIONAL. Automatic catalog sync does NOT depend on this — see
/// FoodicsAutoSyncHostedService's periodic sweep, which is what actually
/// makes "a new Foodics item shows up automatically to be weighed" work with
/// zero setup. This controller exists only for the (optional, later) case
/// where the ~5 minute sweep isn't fast enough: it receives Foodics' own
/// "menu.updated" webhook calls (fired for any product/category/modifier
/// create/update/delete) and triggers a near-instant sync for just that
/// brand instead of waiting for the next sweep. Until a webhook is actually
/// registered with Foodics (see WebhookSecret), nothing ever calls this and
/// it sits completely inert.
/// Exempt from the usual X-Api-Key/X-Device-Key gate (see ApiKeyMiddleware) —
/// Foodics sends neither, and its own docs don't offer a signature/HMAC
/// scheme, so the secret path segment IS the authentication here.
/// </summary>
[ApiController]
[Route("api/webhooks")]
public class WebhooksController : ControllerBase
{
    private readonly AppDbContext _db;
    private readonly IFoodicsSyncQueue _queue;
    private readonly FoodicsOptions _opts;
    private readonly ILogger<WebhooksController> _log;

    public WebhooksController(AppDbContext db, IFoodicsSyncQueue queue,
        IOptions<FoodicsOptions> opts, ILogger<WebhooksController> log)
    {
        _db = db;
        _queue = queue;
        _opts = opts.Value;
        _log = log;
    }

    /// <summary>
    /// Foodics requires a 2xx response within 5 seconds and ignores the body
    /// — so this only ever validates + enqueues, then returns immediately;
    /// the actual re-sync happens afterwards in FoodicsAutoSyncHostedService.
    /// Malformed/unexpected payloads are logged and swallowed, never thrown —
    /// a webhook is untrusted external input, same trust level as any other
    /// unauthenticated endpoint, and Foodics retries 2 more times on a
    /// non-2xx, so a bad payload turning into a 500 would just triple the
    /// noise for nothing.
    /// </summary>
    [HttpPost("foodics/{secret}")]
    public async Task<IActionResult> Foodics(string secret, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_opts.WebhookSecret) || !SecretMatches(secret, _opts.WebhookSecret))
        {
            // Not found, not unauthorized — an unregistered/guessed secret
            // shouldn't even confirm this endpoint exists.
            return NotFound();
        }

        try
        {
            using var doc = await JsonDocument.ParseAsync(Request.Body, cancellationToken: ct);
            var root = doc.RootElement;

            var eventName = root.TryGetProperty("event", out var ev) && ev.ValueKind == JsonValueKind.String
                ? ev.GetString()
                : null;
            // Every documented catalog-affecting event is "menu.updated"
            // (categories, products, modifiers, modifier options, combos,
            // menu groups, price tags all funnel through it) — anything else
            // Foodics might send here isn't something we act on.
            if (eventName is null || !eventName.StartsWith("menu.", StringComparison.OrdinalIgnoreCase))
                return Ok();

            string? reference = null;
            if (root.TryGetProperty("business", out var biz) && biz.ValueKind == JsonValueKind.Object &&
                biz.TryGetProperty("reference", out var refEl))
            {
                reference = refEl.ValueKind == JsonValueKind.String ? refEl.GetString() : refEl.ToString();
            }

            if (string.IsNullOrEmpty(reference))
            {
                _log.LogWarning("Foodics webhook: {Event} payload had no business.reference, ignoring", eventName);
                return Ok();
            }

            var brand = await _db.Brands
                .FirstOrDefaultAsync(b => b.IsActive && b.FoodicsAccount == reference, ct);
            if (brand is null)
            {
                // Most likely: this brand hasn't completed a sync yet (which
                // is what first populates FoodicsAccount) — the periodic
                // sweep will still catch it once it does.
                _log.LogWarning("Foodics webhook: no brand matches business reference {Reference}", reference);
                return Ok();
            }

            _queue.Enqueue(brand.BrandId);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Foodics webhook: failed to process payload");
        }

        return Ok();
    }

    /// Constant-time comparison — this secret is effectively a password
    /// embedded in a URL; no reason to let response timing narrow it down.
    private static bool SecretMatches(string provided, string expected)
    {
        var a = Encoding.UTF8.GetBytes(provided);
        var b = Encoding.UTF8.GetBytes(expected);
        return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
    }
}
