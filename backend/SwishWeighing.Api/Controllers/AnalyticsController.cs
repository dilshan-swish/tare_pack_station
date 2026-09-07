using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Controllers;

/// <summary>
/// Predefined-question analytics for the portal's "AI COO"-style insights
/// panel. Every answer here is computed directly from WeighEvents (plus the
/// item/modifier composition snapshotted in ItemsJson at weigh time) — there
/// is no live model call; the "AI" framing is the portal's presentation of
/// real statistics, not a language model in the loop. Where the data simply
/// doesn't support a question (e.g. a true weighed/total-orders ratio needs
/// an order count this system doesn't sync), the response says so plainly in
/// Caveat/Narrative rather than fabricating a number.
/// </summary>
[ApiController]
[Route("api/analytics")]
public class AnalyticsController : ControllerBase
{
    private readonly AppDbContext _db;
    public AnalyticsController(AppDbContext db) => _db = db;

    private static readonly JsonSerializerOptions ItemsJsonReadOptions =
        new() { PropertyNameCaseInsensitive = true };

    // Portal-only, like the CSV export — a tablet's own device key has no
    // business pulling cross-branch/cross-brand aggregate analytics.
    private IActionResult? DenyDeviceKey() =>
        HttpContext.Items["DeviceId"] is int
            ? StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." })
            : null;

    private async Task<List<WeighEvent>> LoadRange(DateTime? from, DateTime? to)
    {
        var q = _db.WeighEvents.AsQueryable();
        if (from.HasValue) q = q.Where(e => e.WeighedAt >= from.Value);
        if (to.HasValue) q = q.Where(e => e.WeighedAt <= to.Value);
        return await q.OrderBy(e => e.WeighedAt).ToListAsync();
    }

    private async Task<(Dictionary<int, Branch> branches, Dictionary<int, Brand> brands)> LoadBranchesBrands()
    {
        var branches = await _db.Branches.ToDictionaryAsync(b => b.BranchId);
        var brands = await _db.Brands.ToDictionaryAsync(b => b.BrandId);
        return (branches, brands);
    }

    private static string BranchLabel(Dictionary<int, Branch> branches, Dictionary<int, Brand> brands, int branchId)
    {
        branches.TryGetValue(branchId, out var b);
        var name = b?.NameLocalized ?? b?.Name ?? $"Branch {branchId}";
        return b != null && brands.TryGetValue(b.BrandId, out var brand) ? $"{brand.Code} · {name}" : name;
    }

    // ItemsJson is optional and only ever a best-effort snapshot — a missing
    // or malformed blob just means this order contributes nothing to
    // composition-based analytics, never a failed request.
    private List<WeighEventItemDto> ParseItems(WeighEvent e)
    {
        if (string.IsNullOrWhiteSpace(e.ItemsJson)) return new();
        try
        {
            return JsonSerializer.Deserialize<List<WeighEventItemDto>>(e.ItemsJson!, ItemsJsonReadOptions) ?? new();
        }
        catch
        {
            return new();
        }
    }

    private static decimal? MidG(WeighEvent e) =>
        e.ExpectedMinG.HasValue && e.ExpectedMaxG.HasValue ? (e.ExpectedMinG + e.ExpectedMaxG) / 2 : null;

    private static double StdDev(IReadOnlyList<double> values)
    {
        if (values.Count < 2) return 0;
        var mean = values.Average();
        var sumSq = values.Sum(v => (v - mean) * (v - mean));
        return Math.Sqrt(sumSq / (values.Count - 1));
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "…";

    /// <summary>
    /// Groups repeat orders by their exact item + modifier composition.
    /// mode=high ranks by weight SWING (highest standard deviation) — the
    /// least consistently packed combinations. mode=low ranks by average
    /// deviation from the configured expected weight — the combinations
    /// landing closest to target on average.
    /// </summary>
    [HttpGet("order-consistency")]
    public async Task<IActionResult> OrderConsistency(
        [FromQuery] string mode = "high", [FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        mode = mode.ToLowerInvariant();
        if (mode != "high" && mode != "low")
            return BadRequest(new { error = "mode must be 'high' or 'low'." });

        var events = await LoadRange(from, to);
        var groups = new Dictionary<string, (string Label, List<(double Measured, double? Mid)> Rows)>();

        foreach (var e in events)
        {
            if (e.MeasuredG is not { } measured) continue;
            var items = ParseItems(e);
            if (items.Count == 0) continue;

            var sig = string.Join(" + ", items
                .Select(i => (i.Name ?? i.MenuItemId) +
                    (i.Modifiers is { Count: > 0 }
                        ? "[" + string.Join(",", i.Modifiers.Select(m => m.Name ?? m.ModifierId).OrderBy(x => x)) + "]"
                        : ""))
                .OrderBy(x => x));
            if (string.IsNullOrWhiteSpace(sig)) continue;

            if (!groups.TryGetValue(sig, out var g))
            {
                g = (Truncate(sig, 70), new List<(double, double?)>());
                groups[sig] = g;
            }
            var midG = MidG(e);
            g.Rows.Add(((double)measured, midG.HasValue ? (double)midG.Value : null));
        }

        const int minSamples = 3;
        var stats = groups.Values
            .Where(g => g.Rows.Count >= minSamples)
            .Select(g =>
            {
                var measuredList = g.Rows.Select(r => r.Measured).ToList();
                var withMid = g.Rows.Where(r => r.Mid.HasValue).ToList();
                double? avgMid = withMid.Count > 0 ? withMid.Average(r => r.Mid!.Value) : null;
                double? avgDevPct = withMid.Count > 0
                    ? withMid.Average(r => r.Mid!.Value > 0 ? Math.Abs(r.Measured - r.Mid!.Value) / r.Mid!.Value * 100 : 0)
                    : null;
                return new
                {
                    g.Label,
                    Count = g.Rows.Count,
                    AvgMeasuredG = measuredList.Average(),
                    StdDevG = StdDev(measuredList),
                    AvgExpectedMidG = avgMid,
                    AvgDeviationPct = avgDevPct,
                };
            })
            .ToList();

        List<Dictionary<string, object?>> data;
        List<Dictionary<string, object?>> table;
        string headline, narrative;
        string? caveat = stats.Count == 0
            ? $"No order composition has been repeated at least {minSamples} times yet in this range — consistency needs repeat samples to mean anything."
            : null;

        if (mode == "high")
        {
            var top = stats.OrderByDescending(s => s.StdDevG).Take(8).ToList();
            data = top.Select(s => new Dictionary<string, object?>
            {
                ["label"] = s.Label, ["stdDevG"] = Math.Round(s.StdDevG, 1), ["count"] = s.Count,
            }).ToList();
            table = top.Select(s => new Dictionary<string, object?>
            {
                ["Combination"] = s.Label, ["Samples"] = s.Count,
                ["Avg measured"] = $"{Math.Round(s.AvgMeasuredG)}g", ["Weight swing (±1 SD)"] = $"{Math.Round(s.StdDevG)}g",
            }).ToList();
            var first = top.FirstOrDefault();
            headline = first == null
                ? "Not enough repeat orders yet to measure consistency."
                : $"\"{first.Label}\" is the least consistent repeat order — weights swing by about ±{Math.Round(first.StdDevG)}g across {first.Count} orders.";
            narrative = first == null
                ? "Once the same item/modifier combination has been weighed a few times, this compares how consistently it was packed."
                : $"Across {stats.Count} order combinations weighed at least {minSamples} times, \"{first.Label}\" showed the widest spread — averaging {Math.Round(first.AvgMeasuredG)}g but varying by roughly ±{Math.Round(first.StdDevG)}g order to order. A wide swing here usually points to packing variation rather than a scale or config issue.";
            return Ok(new AnalyticsResultDto(headline, narrative, caveat,
                new ChartDto("bar", "label", new[] { new ChartSeriesDto("stdDevG", "Weight swing (g)") }, data,
                    "Order combination", "Grams (±1 SD)"),
                new[] { "Combination", "Samples", "Avg measured", "Weight swing (±1 SD)" }, table));
        }
        else
        {
            var eligible = stats.Where(s => s.AvgDeviationPct.HasValue).ToList();
            var top = eligible.OrderBy(s => s.AvgDeviationPct).Take(8).ToList();
            data = top.Select(s => new Dictionary<string, object?>
            {
                ["label"] = s.Label, ["deviationPct"] = Math.Round(s.AvgDeviationPct!.Value, 1), ["count"] = s.Count,
            }).ToList();
            table = top.Select(s => new Dictionary<string, object?>
            {
                ["Combination"] = s.Label, ["Samples"] = s.Count,
                ["Avg measured"] = $"{Math.Round(s.AvgMeasuredG)}g", ["Avg expected"] = $"{Math.Round(s.AvgExpectedMidG!.Value)}g",
                ["Avg deviation"] = $"{Math.Round(s.AvgDeviationPct!.Value, 1)}%",
            }).ToList();
            var first = top.FirstOrDefault();
            caveat ??= eligible.Count == 0
                ? "None of the repeated combinations have a configured expected weight range to compare against yet."
                : null;
            headline = first == null
                ? "No repeated combination has a configured expected range to compare against yet."
                : $"\"{first.Label}\" is the most consistently on-target — averaging only {Math.Round(first.AvgDeviationPct!.Value, 1)}% off its expected weight.";
            narrative = first == null
                ? "This compares each repeated combination's average measured weight against its configured expected range."
                : $"Across {eligible.Count} order combinations with a configured expected weight, \"{first.Label}\" stayed closest to target — averaging {Math.Round(first.AvgMeasuredG)}g against an expected {Math.Round(first.AvgExpectedMidG!.Value)}g, a deviation of just {Math.Round(first.AvgDeviationPct!.Value, 1)}%.";
            return Ok(new AnalyticsResultDto(headline, narrative, caveat,
                new ChartDto("bar", "label", new[] { new ChartSeriesDto("deviationPct", "Avg deviation (%)") }, data,
                    "Order combination", "Deviation from expected (%)"),
                new[] { "Combination", "Samples", "Avg measured", "Avg expected", "Avg deviation" }, table));
        }
    }

    /// <summary>Which items are most often ordered together — co-occurrence
    /// across every order with two or more distinct items, the classic
    /// market-basket view.</summary>
    [HttpGet("market-basket")]
    public async Task<IActionResult> MarketBasket([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);

        var itemCounts = new Dictionary<string, int>();
        var pairCounts = new Dictionary<(string A, string B), int>();
        var totalOrdersWithItems = 0;
        var basketsWithTwoPlus = 0;

        foreach (var e in events)
        {
            var names = ParseItems(e)
                .Select(i => i.Name)
                .Where(n => !string.IsNullOrWhiteSpace(n))
                .Select(n => n!)
                .Distinct()
                .OrderBy(n => n)
                .ToList();
            if (names.Count == 0) continue;
            totalOrdersWithItems++;
            foreach (var n in names) itemCounts[n] = itemCounts.GetValueOrDefault(n) + 1;
            if (names.Count < 2) continue;
            basketsWithTwoPlus++;
            for (var i = 0; i < names.Count; i++)
                for (var j = i + 1; j < names.Count; j++)
                {
                    var key = (names[i], names[j]);
                    pairCounts[key] = pairCounts.GetValueOrDefault(key) + 1;
                }
        }

        var top = pairCounts
            .Select(kv => new
            {
                Label = $"{kv.Key.A} + {kv.Key.B}",
                Count = kv.Value,
                Support = basketsWithTwoPlus > 0 ? (double)kv.Value / basketsWithTwoPlus * 100 : 0,
                // Lift compares against how often each item appears across ALL
                // orders (not just multi-item ones) — using the multi-item
                // count here instead would compare two different populations
                // and produce a systematically wrong ratio.
                Lift = itemCounts[kv.Key.A] > 0 && itemCounts[kv.Key.B] > 0 && totalOrdersWithItems > 0
                    ? (double)kv.Value * totalOrdersWithItems / ((double)itemCounts[kv.Key.A] * itemCounts[kv.Key.B])
                    : 0,
            })
            .OrderByDescending(x => x.Count)
            .Take(10)
            .ToList();

        var data = top.Select(x => new Dictionary<string, object?>
        {
            ["label"] = Truncate(x.Label, 40), ["count"] = x.Count,
        }).ToList();
        var table = top.Select(x => new Dictionary<string, object?>
        {
            ["Pair"] = x.Label, ["Orders together"] = x.Count,
            ["Share of multi-item orders"] = $"{Math.Round(x.Support, 1)}%", ["Lift"] = Math.Round(x.Lift, 2),
        }).ToList();

        var first = top.FirstOrDefault();
        var headline = first == null
            ? "Not enough multi-item orders yet to find a pattern."
            : $"\"{first.Label}\" is the most common pairing — bought together in {first.Count} orders.";
        var narrative = first == null
            ? "Once there are enough multi-item orders, this shows which items tend to be ordered together."
            : $"Out of {basketsWithTwoPlus} orders with two or more items, \"{first.Label}\" appeared together {first.Count} times ({Math.Round(first.Support, 1)}% of them)." +
              (first.Lift > 1 ? $" Its lift of {Math.Round(first.Lift, 2)}× means that's a real association, not just two popular items showing up by chance." : "");

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            basketsWithTwoPlus == 0 ? "No multi-item orders found in this range." : null,
            top.Count > 0
                ? new ChartDto("bar", "label", new[] { new ChartSeriesDto("count", "Orders together") }, data, "Item pair", "Orders")
                : null,
            new[] { "Pair", "Orders together", "Share of multi-item orders", "Lift" }, table));
    }

    /// <summary>Ranks branches by the share of their weighed orders that
    /// landed exactly on weight — "closest to accurate" for orders.</summary>
    [HttpGet("branch-accuracy")]
    public async Task<IActionResult> BranchAccuracy([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);
        var (branches, brands) = await LoadBranchesBrands();

        const int minSamples = 3;
        var byBranch = events
            .Where(e => e.Verdict is "onweight" or "under" or "over")
            .GroupBy(e => e.BranchId)
            .Select(g =>
            {
                var withMid = g.Where(e => e.MeasuredG.HasValue && MidG(e).HasValue).ToList();
                return new
                {
                    Label = BranchLabel(branches, brands, g.Key),
                    Total = g.Count(),
                    OnWeight = g.Count(e => e.Verdict == "onweight"),
                    AvgDeviationPct = withMid.Count > 0
                        ? withMid.Average(e => MidG(e)!.Value > 0
                            ? (double)(Math.Abs(e.MeasuredG!.Value - MidG(e)!.Value) / MidG(e)!.Value) * 100
                            : 0)
                        : (double?)null,
                };
            })
            .Where(x => x.Total >= minSamples)
            .Select(x => new { x.Label, x.Total, x.OnWeight, AccuracyPct = (double)x.OnWeight / x.Total * 100, x.AvgDeviationPct })
            .OrderByDescending(x => x.AccuracyPct)
            .ToList();

        var data = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["label"] = x.Label, ["accuracyPct"] = Math.Round(x.AccuracyPct, 1), ["total"] = x.Total,
        }).ToList();
        var table = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["Branch"] = x.Label, ["Weighed orders"] = x.Total, ["On weight"] = x.OnWeight,
            ["Accuracy"] = $"{Math.Round(x.AccuracyPct, 1)}%",
            ["Avg deviation"] = x.AvgDeviationPct.HasValue ? $"{Math.Round(x.AvgDeviationPct.Value, 1)}%" : "—",
        }).ToList();

        var first = byBranch.FirstOrDefault();
        var headline = first == null
            ? "Not enough weighed orders yet to rank branch accuracy."
            : $"{first.Label} is the most accurate branch — {Math.Round(first.AccuracyPct, 1)}% of its weighed orders landed on weight.";
        var narrative = first == null
            ? "This ranks branches by the share of their weighed orders that landed exactly on weight."
            : $"Ranking {byBranch.Count} branch(es) with at least {minSamples} weighed orders in this range, {first.Label} leads with {first.OnWeight} of {first.Total} orders on weight ({Math.Round(first.AccuracyPct, 1)}%)." +
              (byBranch.Count > 1 ? $" The lowest-ranked branch shown, {byBranch.Last().Label}, is at {Math.Round(byBranch.Last().AccuracyPct, 1)}%." : "");

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            byBranch.Count > 0 ? $"Branches with fewer than {minSamples} weighed orders in this range aren't ranked." : null,
            byBranch.Count > 0
                ? new ChartDto("bar", "label", new[] { new ChartSeriesDto("accuracyPct", "On-weight accuracy (%)") }, data, "Branch", "Accuracy (%)")
                : null,
            new[] { "Branch", "Weighed orders", "On weight", "Accuracy", "Avg deviation" }, table));
    }

    /// <summary>Ranks branches by how much their measured weight swings
    /// around the expected weight, as a percentage (so branches with
    /// different typical order sizes stay comparable).</summary>
    [HttpGet("branch-variance")]
    public async Task<IActionResult> BranchVariance([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);
        var (branches, brands) = await LoadBranchesBrands();

        const int minSamples = 3;
        var byBranch = events
            .Where(e => e.MeasuredG.HasValue && MidG(e).HasValue)
            .GroupBy(e => e.BranchId)
            .Select(g => new
            {
                Label = BranchLabel(branches, brands, g.Key),
                Count = g.Count(),
                DeviationPcts = g.Select(e => MidG(e)!.Value > 0
                        ? (double)((e.MeasuredG!.Value - MidG(e)!.Value) / MidG(e)!.Value) * 100
                        : 0)
                    .ToList(),
            })
            .Where(x => x.Count >= minSamples)
            .Select(x => new { x.Label, x.Count, StdDevPct = StdDev(x.DeviationPcts), AvgAbsDeviationPct = x.DeviationPcts.Select(Math.Abs).Average() })
            .OrderByDescending(x => x.StdDevPct)
            .ToList();

        var data = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["label"] = x.Label, ["stdDevPct"] = Math.Round(x.StdDevPct, 1), ["count"] = x.Count,
        }).ToList();
        var table = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["Branch"] = x.Label, ["Weighed orders"] = x.Count,
            ["Weight variance (±1 SD)"] = $"{Math.Round(x.StdDevPct, 1)}%",
            ["Avg absolute deviation"] = $"{Math.Round(x.AvgAbsDeviationPct, 1)}%",
        }).ToList();

        var first = byBranch.FirstOrDefault();
        var headline = first == null
            ? "Not enough weighed orders with a configured expected weight yet to compare variance."
            : $"{first.Label} has the highest weight variance — swinging about ±{Math.Round(first.StdDevPct, 1)}% from its expected weight order to order.";
        var narrative = first == null
            ? "This compares how much each branch's measured weight typically swings around its expected weight, as a percentage."
            : $"Across {byBranch.Count} branch(es) with at least {minSamples} configured-weight orders, {first.Label} shows the widest swing at ±{Math.Round(first.StdDevPct, 1)}% — packing there is the least predictable in the group, even if not necessarily off-weight on average.";

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            byBranch.Count > 0 ? $"Only orders with a configured expected weight range count toward this, and branches with fewer than {minSamples} such orders aren't ranked." : null,
            byBranch.Count > 0
                ? new ChartDto("bar", "label", new[] { new ChartSeriesDto("stdDevPct", "Variance (±1 SD, %)") }, data, "Branch", "Deviation swing (%)")
                : null,
            new[] { "Branch", "Weighed orders", "Weight variance (±1 SD)", "Avg absolute deviation" }, table));
    }

    /// <summary>A true "weighed ÷ total orders" ratio needs each branch's full
    /// Foodics order count, which this system doesn't sync — it only ever
    /// records orders that were actually weighed. Returns weighed volume by
    /// branch instead, as the closest available proxy, and says so plainly.</summary>
    [HttpGet("weighed-volume")]
    public async Task<IActionResult> WeighedVolume([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);
        var (branches, brands) = await LoadBranchesBrands();

        var byBranch = events
            .GroupBy(e => e.BranchId)
            .Select(g => new { Label = BranchLabel(branches, brands, g.Key), Count = g.Count() })
            .OrderByDescending(x => x.Count)
            .ToList();

        var data = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["label"] = x.Label, ["count"] = x.Count,
        }).ToList();
        var table = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["Branch"] = x.Label, ["Weighed orders"] = x.Count,
        }).ToList();

        var first = byBranch.FirstOrDefault();
        var totalWeighed = events.Count;
        var headline = first == null
            ? "No weighed orders recorded in this range yet."
            : $"{first.Label} weighed the most orders in this range — {first.Count} of {totalWeighed} total.";
        var narrative = "A true weighed-to-total-orders ratio needs each branch's full Foodics order count, which isn't synced into this system today — only orders that were actually weighed ever reach here. " +
            (first == null
                ? "Once weigh events start coming in, this will rank branches by weighed volume as the closest available signal."
                : $"As the closest available proxy, here's weighed volume by branch: {first.Label} leads with {first.Count} orders" +
                  (byBranch.Count > 1 ? $", against {byBranch.Last().Count} for {byBranch.Last().Label} at the other end." : "."));

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            "This shows weighed order COUNT, not a ratio — the total-orders denominator would need a Foodics order sync this system doesn't have yet.",
            byBranch.Count > 0
                ? new ChartDto("bar", "label", new[] { new ChartSeriesDto("count", "Weighed orders") }, data, "Branch", "Weighed orders")
                : null,
            new[] { "Branch", "Weighed orders" }, table));
    }

    /// <summary>How each branch's weighed orders split across on/under/over
    /// weight — a branch-by-branch view of WHERE inaccuracy happens, not just
    /// how much of it. Capped to the busiest branches so the chart stays
    /// readable rather than listing every branch that's ever weighed one order.</summary>
    [HttpGet("branch-outcomes")]
    public async Task<IActionResult> BranchOutcomes([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);
        var (branches, brands) = await LoadBranchesBrands();

        const int maxBranches = 8;
        var byBranch = events
            .Where(e => e.Verdict is "onweight" or "under" or "over")
            .GroupBy(e => e.BranchId)
            .Select(g => new
            {
                Label = BranchLabel(branches, brands, g.Key),
                Total = g.Count(),
                OnWeight = g.Count(e => e.Verdict == "onweight"),
                Under = g.Count(e => e.Verdict == "under"),
                Over = g.Count(e => e.Verdict == "over"),
            })
            .OrderByDescending(x => x.Total)
            .Take(maxBranches)
            .ToList();

        var data = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["label"] = x.Label, ["onWeight"] = x.OnWeight, ["under"] = x.Under, ["over"] = x.Over,
        }).ToList();
        var table = byBranch.Select(x => new Dictionary<string, object?>
        {
            ["Branch"] = x.Label, ["Weighed orders"] = x.Total, ["On weight"] = x.OnWeight,
            ["Under"] = x.Under, ["Over"] = x.Over,
        }).ToList();

        var totalBranches = events.Where(e => e.Verdict is "onweight" or "under" or "over")
            .Select(e => e.BranchId).Distinct().Count();
        var worst = byBranch.OrderByDescending(x => x.Total > 0 ? (double)(x.Under + x.Over) / x.Total : 0).FirstOrDefault();
        var headline = byBranch.Count == 0
            ? "No weighed orders recorded in this range yet."
            : worst != null && worst.Under + worst.Over > 0
                ? $"{worst.Label} has the highest off-weight share among the busiest branches — {worst.Under} under, {worst.Over} over, out of {worst.Total} weighed."
                : $"Every one of the busiest {byBranch.Count} branch(es) came back on weight in this range.";
        var narrative = byBranch.Count == 0
            ? "This breaks down each branch's weighed orders into on-weight, under, and over, so a branch's OFF-weight orders can be seen by type, not just as one combined count."
            : $"Showing the {byBranch.Count} busiest of {totalBranches} branch(es) with weighed orders in this range, split by outcome — useful for spotting whether a branch's issue runs mostly under or mostly over.";

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            totalBranches > byBranch.Count ? $"Showing the {byBranch.Count} busiest branches only, out of {totalBranches} with weighed orders in this range." : null,
            byBranch.Count > 0
                ? new ChartDto("bar", "label", new[]
                {
                    new ChartSeriesDto("onWeight", "On weight"),
                    new ChartSeriesDto("under", "Under"),
                    new ChartSeriesDto("over", "Over"),
                }, data, "Branch", "Weighed orders", ColorMode: "status")
                : null,
            new[] { "Branch", "Weighed orders", "On weight", "Under", "Over" }, table));
    }

    /// <summary>Correctly-weighed vs. off-weight-but-dispatched-anyway counts,
    /// broken down by the reason staff gave.</summary>
    [HttpGet("verdict-breakdown")]
    public async Task<IActionResult> VerdictBreakdown([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);

        var total = events.Count;
        var onWeight = events.Count(e => e.Verdict == "onweight");
        var under = events.Count(e => e.Verdict == "under");
        var over = events.Count(e => e.Verdict == "over");
        var unresolved = Math.Max(0, total - onWeight - under - over);
        var missingSaved = events.Count(e => e.OverrideReason == "Item left off scale");
        var mixedUpSaved = events.Count(e => e.OverrideReason == "Wrong item packed");

        var shareData = new List<Dictionary<string, object?>>();
        if (onWeight > 0) shareData.Add(new() { ["name"] = "On weight", ["value"] = onWeight });
        if (under > 0) shareData.Add(new() { ["name"] = "Under", ["value"] = under });
        if (over > 0) shareData.Add(new() { ["name"] = "Over", ["value"] = over });
        if (unresolved > 0) shareData.Add(new() { ["name"] = "Unconfigured", ["value"] = unresolved });

        var reasonCounts = events
            .Where(e => !string.IsNullOrWhiteSpace(e.OverrideReason))
            .GroupBy(e => e.OverrideReason!)
            .Select(g => new { Reason = g.Key, Count = g.Count() })
            .OrderByDescending(x => x.Count)
            .ToList();

        var reasonData = reasonCounts.Select(x => new Dictionary<string, object?>
        {
            ["label"] = Truncate(x.Reason, 28), ["count"] = x.Count,
        }).ToList();
        var table = reasonCounts.Select(x => new Dictionary<string, object?>
        {
            ["Reason given"] = x.Reason, ["Orders"] = x.Count,
            ["Share of weighed orders"] = total > 0 ? $"{Math.Round((double)x.Count / total * 100, 1)}%" : "—",
        }).ToList();

        var headline = total == 0
            ? "No weighed orders recorded in this range yet."
            : $"{onWeight} of {total} weighed orders ({Math.Round((double)onWeight / total * 100, 1)}%) landed correctly on weight.";
        var narrative = total == 0
            ? "This tallies how many weighed orders were correctly on weight versus dispatched anyway with a reason."
            : $"Of {total} weighed orders, {onWeight} were correctly on weight. Staff dispatched {missingSaved} order(s) despite a missing item, and {mixedUpSaved} order(s) that had been packed with the wrong item — both caught at the scale and saved rather than sent out wrong.";

        return Ok(new AnalyticsResultDto(
            headline, narrative, null,
            shareData.Count > 0
                ? new ChartDto("pie", "name", new[] { new ChartSeriesDto("value", "Orders") }, shareData,
                    ColorMode: "status")
                : null,
            new[] { "Reason given", "Orders", "Share of weighed orders" }, table,
            reasonCounts.Count > 0
                ? new ChartDto("bar", "label", new[] { new ChartSeriesDto("count", "Orders") }, reasonData, "Override reason", "Orders")
                : null,
            reasonCounts.Count > 0 ? "Why orders were dispatched off-weight" : null));
    }

    /// <summary>Flags items/modifiers most often present in an order that was
    /// off-weight yet staff confirmed "Weight should be correct" — the
    /// clearest available signal that a specific item's CONFIGURED weight
    /// (not the pack itself) needs re-measuring on the scale.</summary>
    [HttpGet("reweigh-candidates")]
    public async Task<IActionResult> ReweighCandidates([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);

        var flagged = new Dictionary<(string Name, string Type), int>();
        var total = new Dictionary<(string Name, string Type), int>();

        foreach (var e in events)
        {
            var items = ParseItems(e);
            if (items.Count == 0) continue;
            var isFlaggedOrder = e.Verdict is "under" or "over" && e.OverrideReason == "Weight should be correct";
            var seenThisOrder = new HashSet<(string, string)>();

            foreach (var it in items)
            {
                if (!string.IsNullOrWhiteSpace(it.Name) && seenThisOrder.Add((it.Name!, "item")))
                {
                    var key = (it.Name!, "item");
                    total[key] = total.GetValueOrDefault(key) + 1;
                    if (isFlaggedOrder) flagged[key] = flagged.GetValueOrDefault(key) + 1;
                }
                foreach (var m in it.Modifiers ?? new())
                {
                    if (string.IsNullOrWhiteSpace(m.Name) || !seenThisOrder.Add((m.Name!, "modifier"))) continue;
                    var key = (m.Name!, "modifier");
                    total[key] = total.GetValueOrDefault(key) + 1;
                    if (isFlaggedOrder) flagged[key] = flagged.GetValueOrDefault(key) + 1;
                }
            }
        }

        const int minAppearances = 3;
        var ranked = flagged
            .Where(kv => kv.Value > 0 && total[kv.Key] >= minAppearances)
            .Select(kv => new
            {
                Name = kv.Key.Name, Type = kv.Key.Type, FlagCount = kv.Value, Total = total[kv.Key],
                Rate = (double)kv.Value / total[kv.Key] * 100,
            })
            .OrderByDescending(x => x.FlagCount)
            .ThenByDescending(x => x.Rate)
            .Take(10)
            .ToList();

        var data = ranked.Select(x => new Dictionary<string, object?>
        {
            ["label"] = Truncate(x.Name, 30), ["flagCount"] = x.FlagCount,
        }).ToList();
        var table = ranked.Select(x => new Dictionary<string, object?>
        {
            ["Item / modifier"] = x.Name, ["Type"] = x.Type == "item" ? "Item" : "Modifier",
            ["Flagged \"weight should be correct\""] = x.FlagCount,
            ["Out of appearances"] = x.Total, ["Rate"] = $"{Math.Round(x.Rate, 1)}%",
        }).ToList();

        var first = ranked.FirstOrDefault();
        var headline = first == null
            ? "No item or modifier has been flagged as needing recalibration yet."
            : $"\"{first.Name}\" is the top reweigh candidate — staff confirmed its weight was actually right {first.FlagCount} time(s) despite the order being flagged off-weight.";
        var narrative = first == null
            ? "When staff dispatch an off-weight order with the reason \"Weight should be correct\", it usually means the system's expected weight is wrong, not the pack — this finds which items/modifiers show up in that situation most."
            : $"\"{first.Name}\" ({(first.Type == "item" ? "item" : "modifier")}) appeared in an order marked off-weight-but-actually-correct {first.FlagCount} of the {first.Total} times it was ordered ({Math.Round(first.Rate, 1)}%). That pattern usually means its configured weight (or min/max range) needs to be re-measured on the scale and updated.";

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            $"Only items/modifiers ordered at least {minAppearances} times are considered. This reflects orders CONTAINING the item, not proof that specific item caused the mismatch — it narrows things down, it doesn't isolate it.",
            ranked.Count > 0
                ? new ChartDto("bar", "label", new[] { new ChartSeriesDto("flagCount", "Times flagged") }, data, "Item / modifier", "Times flagged")
                : null,
            new[] { "Item / modifier", "Type", "Flagged \"weight should be correct\"", "Out of appearances", "Rate" }, table));
    }

    /// <summary>Items most often present in an order dispatched despite "Item
    /// left off scale" — the closest available signal to "which item gets
    /// missed most", since the app records that SOMETHING was left off an
    /// order, not which specific line it was.</summary>
    [HttpGet("missed-items")]
    public async Task<IActionResult> MissedItems([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);

        var missingOccurrences = new Dictionary<string, int>();
        var totalOccurrences = new Dictionary<string, int>();
        var missingOrders = 0;

        foreach (var e in events)
        {
            var names = ParseItems(e)
                .Select(i => i.Name)
                .Where(n => !string.IsNullOrWhiteSpace(n))
                .Select(n => n!)
                .Distinct()
                .ToList();
            if (names.Count == 0) continue;
            var isMissingOrder = e.OverrideReason == "Item left off scale";
            if (isMissingOrder) missingOrders++;
            foreach (var n in names)
            {
                totalOccurrences[n] = totalOccurrences.GetValueOrDefault(n) + 1;
                if (isMissingOrder) missingOccurrences[n] = missingOccurrences.GetValueOrDefault(n) + 1;
            }
        }

        const int minAppearances = 3;
        var ranked = missingOccurrences
            .Where(kv => totalOccurrences[kv.Key] >= minAppearances)
            .Select(kv => new
            {
                Name = kv.Key, MissingCount = kv.Value, Total = totalOccurrences[kv.Key],
                Rate = (double)kv.Value / totalOccurrences[kv.Key] * 100,
            })
            .OrderByDescending(x => x.MissingCount)
            .ThenByDescending(x => x.Rate)
            .Take(10)
            .ToList();

        var data = ranked.Select(x => new Dictionary<string, object?>
        {
            ["label"] = Truncate(x.Name, 30), ["missingCount"] = x.MissingCount,
        }).ToList();
        var table = ranked.Select(x => new Dictionary<string, object?>
        {
            ["Item"] = x.Name, ["In missing-item orders"] = x.MissingCount, ["Total orders"] = x.Total,
            ["Rate"] = $"{Math.Round(x.Rate, 1)}%",
        }).ToList();

        var first = ranked.FirstOrDefault();
        var headline = first == null
            ? (missingOrders == 0 ? "No orders have been flagged with a missing item yet." : "Not enough repeat orders yet to single out a most-missed item.")
            : $"\"{first.Name}\" shows up most often in orders reported missing an item — {first.MissingCount} of its {first.Total} orders ({Math.Round(first.Rate, 1)}%).";
        var narrative = first == null
            ? "This can't identify the exact item left off an order — only that something was — but it can show which items appear disproportionately often in orders where that happened."
            : $"Out of {missingOrders} orders dispatched with \"Item left off scale\", \"{first.Name}\" was part of the order {first.MissingCount} times — {Math.Round(first.Rate, 1)}% of every time it was ordered at all. That's the strongest available signal for which item tends to get left behind, though it's a correlation across the whole order, not a confirmed record of the exact missing line.";

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            $"The app records that an order was missing an item, not which specific line — this ranks items by how often they're present in those orders (at least {minAppearances} total orders required), the closest available proxy, not a confirmed cause.",
            ranked.Count > 0
                ? new ChartDto("bar", "label", new[] { new ChartSeriesDto("missingCount", "Missing-item orders") }, data, "Item", "Orders")
                : null,
            new[] { "Item", "In missing-item orders", "Total orders", "Rate" }, table));
    }

    /// <summary>How on-weight accuracy has trended over the selected range —
    /// daily for a short range, weekly for a longer one.</summary>
    [HttpGet("accuracy-trend")]
    public async Task<IActionResult> AccuracyTrend([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);
        var qualifying = events.Where(e => e.Verdict is "onweight" or "under" or "over").ToList();

        if (qualifying.Count == 0)
        {
            return Ok(new AnalyticsResultDto(
                "No weighed orders recorded in this range yet.",
                "Once orders are weighed, this tracks how on-weight accuracy trends over time.",
                null, null, null, null));
        }

        var span = qualifying.Max(e => e.WeighedAt) - qualifying.Min(e => e.WeighedAt);
        var byWeek = span.TotalDays > 21;

        var groups = qualifying
            .GroupBy(e => byWeek
                ? $"{System.Globalization.ISOWeek.GetYear(e.WeighedAt)}-W{System.Globalization.ISOWeek.GetWeekOfYear(e.WeighedAt):00}"
                : e.WeighedAt.ToString("yyyy-MM-dd"))
            .OrderBy(g => g.Key)
            .Select(g => new
            {
                Period = g.Key, Total = g.Count(),
                OnWeight = g.Count(e => e.Verdict == "onweight"),
                Under = g.Count(e => e.Verdict == "under"),
                Over = g.Count(e => e.Verdict == "over"),
            })
            .Select(x => new
            {
                x.Period, x.Total, x.OnWeight, x.Under, x.Over,
                AccuracyPct = (double)x.OnWeight / x.Total * 100,
                UnderPct = (double)x.Under / x.Total * 100,
                OverPct = (double)x.Over / x.Total * 100,
            })
            .ToList();

        // A single "accuracy %" line answers the headline question, but the
        // same weekly/daily buckets also show WHERE the inaccuracy went —
        // under vs over — which a lone accuracy line can't distinguish.
        var data = groups.Select(x => new Dictionary<string, object?>
        {
            ["label"] = x.Period, ["onWeightPct"] = Math.Round(x.AccuracyPct, 1),
            ["underPct"] = Math.Round(x.UnderPct, 1), ["overPct"] = Math.Round(x.OverPct, 1),
            ["total"] = x.Total,
        }).ToList();
        var table = groups.Select(x => new Dictionary<string, object?>
        {
            ["Period"] = x.Period, ["Weighed orders"] = x.Total, ["On weight"] = x.OnWeight,
            ["Under"] = x.Under, ["Over"] = x.Over, ["Accuracy"] = $"{Math.Round(x.AccuracyPct, 1)}%",
        }).ToList();

        var first = groups.First();
        var last = groups.Last();
        var delta = last.AccuracyPct - first.AccuracyPct;
        var trendWord = Math.Round(delta, 1) == 0 ? "held steady around" : delta > 0 ? "improved by" : "dropped by";
        var headline = groups.Count < 2
            ? $"Accuracy in this range is {Math.Round(last.AccuracyPct, 1)}% so far — too short a span yet to show a trend."
            : Math.Round(delta, 1) == 0
                ? $"On-weight accuracy has held steady around {Math.Round(last.AccuracyPct, 1)}% across this range."
                : $"On-weight accuracy has {trendWord} {Math.Round(Math.Abs(delta), 1)} points, from {Math.Round(first.AccuracyPct, 1)}% to {Math.Round(last.AccuracyPct, 1)}%.";
        var narrative = groups.Count < 2
            ? $"There's only one {(byWeek ? "week" : "day")} of data in this range so far — pick a longer range to see a trend."
            : Math.Round(delta, 1) == 0
                ? $"Across {groups.Count} {(byWeek ? "weeks" : "days")}, on-weight accuracy stayed close to {Math.Round(last.AccuracyPct, 1)}% the whole way — {Math.Round(first.AccuracyPct, 1)}% at {first.Period}, {Math.Round(last.AccuracyPct, 1)}% at {last.Period}."
                : $"Across {groups.Count} {(byWeek ? "weeks" : "days")}, on-weight accuracy went from {Math.Round(first.AccuracyPct, 1)}% ({first.Period}) to {Math.Round(last.AccuracyPct, 1)}% ({last.Period}), a {(delta > 0 ? "gain" : "drop")} of {Math.Round(Math.Abs(delta), 1)} points.";

        return Ok(new AnalyticsResultDto(
            headline, narrative, null,
            new ChartDto("line", "label", new[]
            {
                new ChartSeriesDto("onWeightPct", "On weight"),
                new ChartSeriesDto("underPct", "Under"),
                new ChartSeriesDto("overPct", "Over"),
            }, data, byWeek ? "Week" : "Day", "Share of weighed orders (%)", ColorMode: "status"),
            new[] { "Period", "Weighed orders", "On weight", "Under", "Over", "Accuracy" }, table));
    }

    /// <summary>Off-weight rate by hour of day — spots a rush-hour packing
    /// dip. Hour is the scale's recorded (UTC) timestamp.</summary>
    [HttpGet("hourly-pattern")]
    public async Task<IActionResult> HourlyPattern([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);
        var qualifying = events.Where(e => e.Verdict is "onweight" or "under" or "over").ToList();

        var byHour = qualifying
            .GroupBy(e => e.WeighedAt.Hour)
            .Select(g => new { Hour = g.Key, Total = g.Count(), OffWeight = g.Count(e => e.Verdict != "onweight") })
            .OrderBy(x => x.Hour)
            .ToList();

        string HourLabel(int h) => h == 0 ? "12 AM" : h < 12 ? $"{h} AM" : h == 12 ? "12 PM" : $"{h - 12} PM";

        var data = byHour.Select(x => new Dictionary<string, object?>
        {
            ["label"] = HourLabel(x.Hour),
            ["offWeightPct"] = x.Total > 0 ? Math.Round((double)x.OffWeight / x.Total * 100, 1) : 0,
            ["total"] = x.Total,
        }).ToList();
        var table = byHour.Select(x => new Dictionary<string, object?>
        {
            ["Hour"] = HourLabel(x.Hour), ["Weighed orders"] = x.Total, ["Off weight"] = x.OffWeight,
            ["Off-weight rate"] = x.Total > 0 ? $"{Math.Round((double)x.OffWeight / x.Total * 100, 1)}%" : "—",
        }).ToList();

        var worst = byHour.Where(x => x.Total >= 3).OrderByDescending(x => (double)x.OffWeight / x.Total).FirstOrDefault();
        var headline = worst == null
            ? "Not enough weighed orders yet to spot an hourly pattern."
            : worst.OffWeight == 0
                ? "No off-weight orders in this range — nothing to compare across hours yet."
                : $"Off-weight orders spike around {HourLabel(worst.Hour)} — {Math.Round((double)worst.OffWeight / worst.Total * 100, 1)}% of orders weighed that hour missed.";
        var narrative = worst == null
            ? "This breaks down off-weight rate by hour of day, so a rush-hour packing dip is easy to spot."
            : worst.OffWeight == 0
                ? "Every hour with at least 3 weighed orders in this range came back 100% on weight, so there's no off-weight pattern to spot yet — this will start showing a shape once some orders come in under or over."
                : $"Of the hours with at least 3 weighed orders, {HourLabel(worst.Hour)} has the highest off-weight rate at {Math.Round((double)worst.OffWeight / worst.Total * 100, 1)}% ({worst.OffWeight} of {worst.Total}) — worth checking whether that lines up with a rush-hour staffing gap.";

        return Ok(new AnalyticsResultDto(
            headline, narrative,
            "Hour is the scale's recorded (UTC) timestamp, not necessarily the branch's local time — treat comparisons between hours as reliable, absolute clock-time labels as approximate.",
            byHour.Count > 0
                ? new ChartDto("area", "label", new[] { new ChartSeriesDto("offWeightPct", "Off-weight rate (%)") }, data, "Hour of day", "Off-weight rate (%)")
                : null,
            new[] { "Hour", "Weighed orders", "Off weight", "Off-weight rate" }, table));
    }

    /// <summary>Data health for the Analytics "Data" section — how much of
    /// what's recorded is actually usable (item composition captured,
    /// expected weight configured), and how coverage breaks down by
    /// branch. Not a chat-style answer — a dashboard of the underlying
    /// data itself.</summary>
    [HttpGet("data-quality")]
    public async Task<IActionResult> DataQuality([FromQuery] DateTime? from = null, [FromQuery] DateTime? to = null)
    {
        if (DenyDeviceKey() is { } deny) return deny;
        var events = await LoadRange(from, to);
        var (branches, brands) = await LoadBranchesBrands();
        var devices = await _db.Devices.ToListAsync();

        var withComposition = events.Count(e => !string.IsNullOrWhiteSpace(e.ItemsJson));
        var withRange = events.Count(e => e.ExpectedMinG.HasValue && e.ExpectedMaxG.HasValue);
        var branchIdsWithEvents = events.Select(e => e.BranchId).ToHashSet();
        var branchesWithNoWeighs = branches.Values.Count(b => b.IsActive && !branchIdsWithEvents.Contains(b.BranchId));

        var byBranch = events
            .GroupBy(e => e.BranchId)
            .Select(g => new BranchDataQualityDto(
                BranchLabel(branches, brands, g.Key),
                g.Count(),
                Math.Round((double)g.Count(e => !string.IsNullOrWhiteSpace(e.ItemsJson)) / g.Count() * 100, 1),
                Math.Round((double)g.Count(e => e.ExpectedMinG.HasValue && e.ExpectedMaxG.HasValue) / g.Count() * 100, 1),
                g.Max(e => (DateTime?)e.WeighedAt)))
            .OrderByDescending(b => b.EventCount)
            .ToList();

        return Ok(new DataQualitySummaryDto(
            events.Count,
            withComposition, events.Count > 0 ? Math.Round((double)withComposition / events.Count * 100, 1) : 0,
            withRange, events.Count > 0 ? Math.Round((double)withRange / events.Count * 100, 1) : 0,
            branches.Values.Count(b => b.IsActive), branches.Count,
            devices.Count(d => d.IsActive), devices.Count,
            branchesWithNoWeighs,
            events.Count > 0 ? events.Min(e => e.WeighedAt) : null,
            events.Count > 0 ? events.Max(e => e.WeighedAt) : null,
            byBranch));
    }
}
