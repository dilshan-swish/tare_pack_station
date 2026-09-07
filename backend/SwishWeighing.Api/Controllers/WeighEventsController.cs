using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Controllers;

[ApiController]
[Route("api/weigh-events")]
public class WeighEventsController : ControllerBase
{
    private readonly AppDbContext _db;
    public WeighEventsController(AppDbContext db) => _db = db;

    // Every OTHER JSON payload in this app goes back to the client through
    // ASP.NET's own controller response pipeline, which applies camelCase
    // property names by default — but ItemsJson is serialized/deserialized
    // manually (it's stored as a plain string column, not returned as a
    // typed response), which bypasses that and defaults to PascalCase
    // instead. Writing with camelCase keeps new rows consistent with
    // everything else the portal and tablet already parse; reading
    // case-insensitively means rows written before this fix (still
    // PascalCase on disk) keep working rather than silently losing their
    // item names/modifiers.
    private static readonly JsonSerializerOptions ItemsJsonWriteOptions =
        new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly JsonSerializerOptions ItemsJsonReadOptions =
        new() { PropertyNameCaseInsensitive = true };

    /// <summary>Records a weigh from a tablet (telemetry for dashboards + AI training).</summary>
    [HttpPost]
    public async Task<IActionResult> Create([FromBody] WeighEventDto body)
    {
        if (body is null) return BadRequest(new { error = "Missing body." });
        // Columns are NVARCHAR(16)/NVARCHAR(64)/NVARCHAR(128)
        // (docs/sql/01_schema.sql) — reject oversized input cleanly instead
        // of letting a SQL truncation exception become an unhandled 500.
        if (body.Verdict?.Length > 16)
            return BadRequest(new { error = "verdict must be 16 characters or fewer." });
        if (body.FoodicsOrderId?.Length > 64)
            return BadRequest(new { error = "foodicsOrderId must be 64 characters or fewer." });
        if (body.OverrideReason?.Length > 128)
            return BadRequest(new { error = "overrideReason must be 128 characters or fewer." });
        if (body.OrderLabel?.Length > 64)
            return BadRequest(new { error = "orderLabel must be 64 characters or fewer." });

        // Composition is optional and, in the worst case (a huge order),
        // still bounded — reject anything absurd cleanly rather than storing
        // an unbounded blob or letting a malformed payload 500.
        string? itemsJson = null;
        if (body.Items is { Count: > 0 })
        {
            if (body.Items.Count > 100)
                return BadRequest(new { error = "items must be 100 lines or fewer." });
            itemsJson = JsonSerializer.Serialize(body.Items, ItemsJsonWriteOptions);
            if (itemsJson.Length > 20_000)
                return BadRequest(new { error = "items payload is too large." });
        }

        // Same bound as Items above, and same reasoning: a handful of short
        // messages in the ordinary case, rejected cleanly if a malformed
        // payload ever sent something absurd instead.
        string? unconfiguredReasonsJson = null;
        if (body.UnconfiguredReasons is { Count: > 0 })
        {
            if (body.UnconfiguredReasons.Count > 100)
                return BadRequest(new { error = "unconfiguredReasons must be 100 lines or fewer." });
            unconfiguredReasonsJson = JsonSerializer.Serialize(body.UnconfiguredReasons, ItemsJsonWriteOptions);
            if (unconfiguredReasonsJson.Length > 20_000)
                return BadRequest(new { error = "unconfiguredReasons payload is too large." });
        }

        // If a tablet authenticated with its device key, trust the server's
        // device/branch over anything in the body, and mark the tablet as seen.
        var deviceId = HttpContext.Items["DeviceId"] as int? ?? body.DeviceId;
        var branchId = HttpContext.Items["BranchId"] as int? ?? body.BranchId;
        if (HttpContext.Items["DeviceId"] is int authDeviceId)
        {
            var dev = await _db.Devices.FindAsync(authDeviceId);
            if (dev != null) dev.LastSeenAt = DateTime.UtcNow;
        }

        var ev = new WeighEvent
        {
            BranchId = branchId,
            DeviceId = deviceId,
            FoodicsOrderId = body.FoodicsOrderId,
            OrderLabel = body.OrderLabel,
            ExpectedMinG = body.ExpectedMinG,
            ExpectedMaxG = body.ExpectedMaxG,
            MeasuredG = body.MeasuredG,
            Verdict = string.IsNullOrWhiteSpace(body.Verdict) ? "unknown" : body.Verdict,
            OverrideReason = body.OverrideReason,
            ItemMissing = body.ItemMissing,
            WeighedAt = body.WeighedAt ?? DateTime.UtcNow,
            CreatedAt = DateTime.UtcNow,
            ItemsJson = itemsJson,
            UnconfiguredReasonsJson = unconfiguredReasonsJson,
        };
        _db.WeighEvents.Add(ev);
        await _db.SaveChangesAsync();
        return Ok(new { ev.EventId });
    }

    /// <summary>Simple per-branch summary for the dashboards (counts by verdict).</summary>
    [HttpGet("summary")]
    public async Task<IActionResult> Summary([FromQuery] int? branchId, [FromQuery] int days = 30)
    {
        var since = DateTime.UtcNow.AddDays(-Math.Clamp(days, 1, 365));
        var q = _db.WeighEvents.Where(e => e.WeighedAt >= since);
        if (branchId.HasValue) q = q.Where(e => e.BranchId == branchId.Value);

        var total = await q.CountAsync();
        var onWeight = await q.CountAsync(e => e.Verdict == "onweight");
        var under = await q.CountAsync(e => e.Verdict == "under");
        var over = await q.CountAsync(e => e.Verdict == "over");
        return Ok(new { total, onWeight, under, over, offWeight = under + over, sinceUtc = since });
    }

    /// <summary>
    /// Individual weigh events for the per-scale portal dashboard — every
    /// recorded order/verdict/measured-weight row for one device (or a whole
    /// branch), newest first, within an optional date range. This is the raw
    /// data a future training pipeline would pull from.
    /// </summary>
    [HttpGet]
    public async Task<ActionResult<IEnumerable<WeighEventEntryDto>>> List(
        [FromQuery] int? deviceId, [FromQuery] int? branchId,
        [FromQuery] DateTime? from, [FromQuery] DateTime? to, [FromQuery] int limit = 200)
    {
        // A device-key caller (rather than the portal's admin key) can only
        // ever see its OWN weigh events — same rule already applied to
        // writing them in Create above.
        if (HttpContext.Items["DeviceId"] is int authDeviceId)
        {
            deviceId = authDeviceId;
            branchId = null;
        }

        if (deviceId is null && branchId is null)
            return BadRequest(new { error = "deviceId or branchId is required." });

        var q = _db.WeighEvents.AsQueryable();
        if (deviceId.HasValue) q = q.Where(e => e.DeviceId == deviceId.Value);
        if (branchId.HasValue) q = q.Where(e => e.BranchId == branchId.Value);
        if (from.HasValue) q = q.Where(e => e.WeighedAt >= from.Value);
        if (to.HasValue) q = q.Where(e => e.WeighedAt <= to.Value);

        var rows = await q.OrderByDescending(e => e.WeighedAt)
            .Take(Math.Clamp(limit, 1, 1000))
            .ToListAsync();

        return Ok(rows.Select(e => new WeighEventEntryDto(
            e.EventId, e.DeviceId, e.FoodicsOrderId, e.ExpectedMinG, e.ExpectedMaxG, e.MeasuredG,
            e.Verdict, e.OverrideReason, e.ItemMissing, e.WeighedAt, e.ItemsJson, e.OrderLabel,
            e.UnconfiguredReasonsJson)));
    }

    /// <summary>
    /// Every weighed order, filterable by brand(s), branch(es), device,
    /// verdict(s), and date range, as a CSV — either one row per order
    /// (<c>format=orders</c>, the aggregate view) or one row per
    /// order/item/modifier line (<c>format=items</c>, the "tidy" long format
    /// suited to training a weight-prediction model or item-level analytics
    /// without any JSON parsing downstream). "Weighed" is automatic here:
    /// this table only ever contains orders that actually went through
    /// Confirm &amp; Dispatch, so no extra filtering is needed for that.
    /// Portal-only — a tablet's own device key is scoped to its own events
    /// via List above, not this bulk export.
    /// </summary>
    [HttpGet("export")]
    public async Task<IActionResult> Export(
        [FromQuery] int? deviceId, [FromQuery] string? brandIds, [FromQuery] string? branchIds,
        [FromQuery] string? verdicts, [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] string format = "orders")
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });
        if (format != "orders" && format != "items")
            return BadRequest(new { error = "format must be 'orders' or 'items'." });

        var brandIdList = ParseIntList(brandIds);
        var branchIdList = ParseIntList(branchIds);
        var verdictList = ParseLowerList(verdicts);

        var q = _db.WeighEvents.AsQueryable();
        if (deviceId.HasValue) q = q.Where(e => e.DeviceId == deviceId.Value);
        if (branchIdList != null) q = q.Where(e => branchIdList.Contains(e.BranchId));
        if (from.HasValue) q = q.Where(e => e.WeighedAt >= from.Value);
        if (to.HasValue) q = q.Where(e => e.WeighedAt <= to.Value);
        if (verdictList != null) q = q.Where(e => verdictList.Contains(e.Verdict.ToLower()));

        // WeighEvent only stores a BranchId, so filtering by brand needs to
        // resolve which branches belong to the requested brand(s) first.
        if (brandIdList != null)
        {
            var branchesForBrands = await _db.Branches
                .Where(b => brandIdList.Contains(b.BrandId))
                .Select(b => b.BranchId)
                .ToListAsync();
            q = q.Where(e => branchesForBrands.Contains(e.BranchId));
        }

        var rows = await q.OrderBy(e => e.WeighedAt).ToListAsync();
        var branches = await _db.Branches.ToDictionaryAsync(b => b.BranchId);
        var brands = await _db.Brands.ToDictionaryAsync(b => b.BrandId);
        var deviceLabels = await _db.Devices.ToDictionaryAsync(d => d.DeviceId, d => d.Label);

        var csv = format == "items"
            ? BuildItemLevelCsv(rows, branches, brands, deviceLabels)
            : BuildOrderLevelCsv(rows, branches, brands, deviceLabels);

        var bytes = Encoding.UTF8.GetBytes(csv);
        var fileName = $"weighed-{format}-{DateTime.UtcNow:yyyyMMdd-HHmmss}.csv";
        return File(bytes, "text/csv", fileName);
    }

    private static List<int>? ParseIntList(string? csv)
    {
        if (string.IsNullOrWhiteSpace(csv)) return null;
        var result = csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(s => int.TryParse(s, out var n) ? n : (int?)null)
            .Where(n => n.HasValue).Select(n => n!.Value).ToList();
        return result.Count > 0 ? result : null;
    }

    private static List<string>? ParseLowerList(string? csv)
    {
        if (string.IsNullOrWhiteSpace(csv)) return null;
        var result = csv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(s => s.ToLowerInvariant()).ToList();
        return result.Count > 0 ? result : null;
    }

    /// One row per weighed order — the aggregate view, quick to skim.
    private static string BuildOrderLevelCsv(
        List<WeighEvent> rows, Dictionary<int, Branch> branches,
        Dictionary<int, Brand> brands, Dictionary<int, string> deviceLabels)
    {
        var csv = new StringBuilder();
        csv.AppendLine(CsvRow(
            "event_id", "brand_id", "brand_code", "branch_id", "branch_name",
            "device_id", "device_label", "order_label", "foodics_order_id", "weighed_at",
            "expected_min_g", "expected_max_g", "measured_g", "verdict",
            "override_reason", "item_missing", "items_json"));

        foreach (var e in rows)
        {
            branches.TryGetValue(e.BranchId, out var branch);
            brands.TryGetValue(branch?.BrandId ?? -1, out var brand);
            var deviceLabel = e.DeviceId.HasValue ? deviceLabels.GetValueOrDefault(e.DeviceId.Value, "") : "";
            csv.AppendLine(CsvRow(
                e.EventId.ToString(), branch?.BrandId.ToString() ?? "", brand?.Code ?? "",
                e.BranchId.ToString(), branch?.Name ?? "",
                e.DeviceId?.ToString() ?? "", deviceLabel, e.OrderLabel ?? "",
                e.FoodicsOrderId ?? "", e.WeighedAt.ToString("o"),
                e.ExpectedMinG?.ToString() ?? "", e.ExpectedMaxG?.ToString() ?? "",
                e.MeasuredG?.ToString() ?? "", e.Verdict, e.OverrideReason ?? "",
                e.ItemMissing?.ToString() ?? "", e.ItemsJson ?? ""));
        }
        return csv.ToString();
    }

    /// One row per order/item/modifier line — "tidy" long format: every
    /// order-level field repeats across its item rows, and every item with no
    /// modifiers still gets exactly one row (empty modifier columns), so
    /// grouping by event_id always reconstructs the whole order. Ready for a
    /// training pipeline or a pivot table with no JSON parsing anywhere.
    private static string BuildItemLevelCsv(
        List<WeighEvent> rows, Dictionary<int, Branch> branches,
        Dictionary<int, Brand> brands, Dictionary<int, string> deviceLabels)
    {
        var csv = new StringBuilder();
        csv.AppendLine(CsvRow(
            "event_id", "brand_id", "brand_code", "branch_id", "branch_name",
            "device_id", "device_label", "order_label", "foodics_order_id", "weighed_at",
            "expected_min_g", "expected_max_g", "measured_g", "verdict",
            "override_reason", "item_missing",
            "line_index", "menu_item_id", "menu_item_name", "modifier_id", "modifier_name"));

        foreach (var e in rows)
        {
            branches.TryGetValue(e.BranchId, out var branch);
            brands.TryGetValue(branch?.BrandId ?? -1, out var brand);
            var deviceLabel = e.DeviceId.HasValue ? deviceLabels.GetValueOrDefault(e.DeviceId.Value, "") : "";

            string[] common =
            [
                e.EventId.ToString(), branch?.BrandId.ToString() ?? "", brand?.Code ?? "",
                e.BranchId.ToString(), branch?.Name ?? "",
                e.DeviceId?.ToString() ?? "", deviceLabel, e.OrderLabel ?? "",
                e.FoodicsOrderId ?? "", e.WeighedAt.ToString("o"),
                e.ExpectedMinG?.ToString() ?? "", e.ExpectedMaxG?.ToString() ?? "",
                e.MeasuredG?.ToString() ?? "", e.Verdict, e.OverrideReason ?? "",
                e.ItemMissing?.ToString() ?? "",
            ];

            List<WeighEventItemDto>? items = null;
            if (!string.IsNullOrEmpty(e.ItemsJson))
            {
                try { items = JsonSerializer.Deserialize<List<WeighEventItemDto>>(e.ItemsJson, ItemsJsonReadOptions); }
                catch (JsonException) { items = null; } // malformed old data — treated as "no composition recorded"
            }

            if (items is null || items.Count == 0)
            {
                // No composition recorded (an older event, or the tablet
                // couldn't resolve the order) — still emit one row so this
                // event isn't silently dropped from item-level analysis.
                csv.AppendLine(CsvRow([.. common, "", "", "", "", ""]));
                continue;
            }

            for (var i = 0; i < items.Count; i++)
            {
                var item = items[i];
                if (item.Modifiers is null || item.Modifiers.Count == 0)
                {
                    csv.AppendLine(CsvRow([.. common, (i + 1).ToString(), item.MenuItemId, item.Name ?? "", "", ""]));
                    continue;
                }
                foreach (var mod in item.Modifiers)
                {
                    csv.AppendLine(CsvRow([
                        .. common, (i + 1).ToString(), item.MenuItemId, item.Name ?? "",
                        mod.ModifierId, mod.Name ?? "",
                    ]));
                }
            }
        }
        return csv.ToString();
    }

    private static string CsvRow(params string[] fields) => string.Join(",", fields.Select(CsvField));

    /// RFC-4180-ish escaping: any field containing a comma, quote, or newline
    /// gets quote-wrapped with internal quotes doubled — necessary here since
    /// order/modifier/branch names (and items_json itself) can contain any of these.
    private static string CsvField(string value) =>
        value.IndexOfAny(['"', ',', '\n', '\r']) >= 0
            ? "\"" + value.Replace("\"", "\"\"") + "\""
            : value;

    // -------------------------------------------------------------------
    // AI training data — cleaned + combination-resolved weighed orders,
    // ready to fit a per-component weight model against (see
    // docs/AI_TRAINING_DATA.md for the full format and how to use it).
    // "Clean" means dispatched on-weight with no override — anything else
    // reflects a pack the app itself flagged as off, or a human corrected
    // by hand, neither of which is ground truth for what a component
    // actually weighs. "Resolved" means selected modifiers are folded
    // through the SAME combination logic the tablet uses at weigh time
    // (lib/logic/modifier_pairing.dart's resolveSelectedModifiers) so a
    // combo-size choice, for example, contributes one dependent-modifier
    // component per group it affects — never its raw, unrelated standalone
    // modifier id.
    // -------------------------------------------------------------------

    /// <summary>A small, recent sample of matched orders (regardless of
    /// trust status, each flagged) plus full-set summary counts — the data
    /// behind the portal's interactive training-data preview. Never the
    /// bulk export itself (see TrainingExport for that).</summary>
    [HttpGet("training-preview")]
    public async Task<ActionResult<TrainingPreviewResultDto>> TrainingPreview(
        [FromQuery] string? brandIds, [FromQuery] string? branchIds,
        [FromQuery] DateTime? from, [FromQuery] DateTime? to, [FromQuery] int limit = 25)
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });

        limit = Math.Clamp(limit, 1, 100);
        var (matchedBranches, error) = await ResolveMatchedBranchesAsync(brandIds, branchIds);
        if (error != null) return BadRequest(new { error });
        var matchedBranchIds = matchedBranches.Select(b => b.BranchId).ToList();
        if (matchedBranchIds.Count == 0)
            return Ok(new TrainingPreviewResultDto(new(0, 0, 0, 0, 0), Array.Empty<TrainingOrderPreviewDto>()));

        var q = _db.WeighEvents.Where(e => matchedBranchIds.Contains(e.BranchId));
        if (from.HasValue) q = q.Where(e => e.WeighedAt >= from.Value);
        if (to.HasValue) q = q.Where(e => e.WeighedAt <= to.Value);

        var totalMatched = await q.CountAsync();
        var cleanCount = await q.CountAsync(e => e.Verdict == "onweight" && (e.OverrideReason == null || e.OverrideReason == ""));
        var excludedOffWeight = await q.CountAsync(e => e.Verdict != "onweight");
        var excludedOverride = totalMatched - cleanCount - excludedOffWeight;

        var sampleRows = await q.OrderByDescending(e => e.WeighedAt).Take(limit).ToListAsync();
        var brandsById = await _db.Brands.ToDictionaryAsync(b => b.BrandId);
        var branchesById = matchedBranches.ToDictionary(b => b.BranchId);
        var branchToBrand = matchedBranches.ToDictionary(b => b.BranchId, b => b.BrandId);
        var lookups = await LoadBrandLookupsAsync(matchedBranches.Select(b => b.BrandId).Distinct());

        var orderDtos = new List<TrainingOrderPreviewDto>();
        var sampledWithUnmapped = 0;
        foreach (var e in sampleRows)
        {
            var (components, unmappedCount) = ResolveOrderComponents(e, branchToBrand, lookups);
            if (unmappedCount > 0) sampledWithUnmapped++;
            var trusted = e.Verdict == "onweight" && string.IsNullOrEmpty(e.OverrideReason);
            var excludeReason = trusted
                ? null
                : e.Verdict != "onweight" ? $"off-weight ({e.Verdict})" : "dispatched with an override reason";
            var brandId = branchToBrand.GetValueOrDefault(e.BranchId);
            orderDtos.Add(new TrainingOrderPreviewDto(
                e.EventId, e.WeighedAt, brandsById.GetValueOrDefault(brandId)?.Code,
                branchesById.GetValueOrDefault(e.BranchId)?.Name, e.MeasuredG, e.Verdict, e.OverrideReason,
                trusted, excludeReason, components, unmappedCount));
        }

        return Ok(new TrainingPreviewResultDto(
            new TrainingPreviewSummaryDto(totalMatched, excludedOffWeight, excludedOverride, cleanCount, sampledWithUnmapped),
            orderDtos));
    }

    /// <summary>The full cleaned, resolved dataset as a CSV — either one row
    /// per order (<c>format=orders</c>, components semicolon-joined) or one
    /// row per order/component (<c>format=components</c>, the "tidy" long
    /// format a training script can one-hot encode with no JSON parsing).
    /// <c>trustedOnly</c> (default true) restricts to dispatched, on-weight,
    /// non-overridden orders — the only ones that are real ground truth for
    /// what a component actually weighs; turning it off is for inspecting
    /// excluded rows, never for training.</summary>
    [HttpGet("training-export")]
    public async Task<IActionResult> TrainingExport(
        [FromQuery] string? brandIds, [FromQuery] string? branchIds,
        [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] bool trustedOnly = true, [FromQuery] string format = "components")
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });
        if (format != "orders" && format != "components")
            return BadRequest(new { error = "format must be 'orders' or 'components'." });

        var (matchedBranches, branchError) = await ResolveMatchedBranchesAsync(brandIds, branchIds);
        if (branchError != null) return BadRequest(new { error = branchError });
        var matchedBranchIds = matchedBranches.Select(b => b.BranchId).ToList();

        var q = _db.WeighEvents.Where(e => matchedBranchIds.Contains(e.BranchId));
        if (from.HasValue) q = q.Where(e => e.WeighedAt >= from.Value);
        if (to.HasValue) q = q.Where(e => e.WeighedAt <= to.Value);
        if (trustedOnly) q = q.Where(e => e.Verdict == "onweight" && (e.OverrideReason == null || e.OverrideReason == ""));

        var rows = await q.OrderBy(e => e.WeighedAt).ToListAsync();
        var brandsById = await _db.Brands.ToDictionaryAsync(b => b.BrandId);
        var branchesById = matchedBranches.ToDictionary(b => b.BranchId);
        var branchToBrand = matchedBranches.ToDictionary(b => b.BranchId, b => b.BrandId);
        var lookups = await LoadBrandLookupsAsync(matchedBranches.Select(b => b.BrandId).Distinct());

        var csv = format == "components"
            ? BuildTrainingComponentsCsv(rows, branchToBrand, branchesById, brandsById, lookups)
            : BuildTrainingOrdersCsv(rows, branchToBrand, branchesById, brandsById, lookups);

        var bytes = Encoding.UTF8.GetBytes(csv);
        var fileName = $"training-{format}-{DateTime.UtcNow:yyyyMMdd-HHmmss}.csv";
        return File(bytes, "text/csv", fileName);
    }

    /// <summary>Every branch matching the given (optional) brand/branch id
    /// filters — both blank means every branch. Shared by the preview and
    /// export endpoints so their filtering can never drift apart.</summary>
    private async Task<(List<Branch> Branches, string? Error)> ResolveMatchedBranchesAsync(string? brandIds, string? branchIds)
    {
        var brandIdList = ParseIntList(brandIds);
        var branchIdList = ParseIntList(branchIds);
        var q = _db.Branches.AsQueryable();
        if (brandIdList != null) q = q.Where(b => brandIdList.Contains(b.BrandId));
        if (branchIdList != null) q = q.Where(b => branchIdList.Contains(b.BranchId));
        return (await q.ToListAsync(), null);
    }

    private sealed class BrandLookup
    {
        public required Dictionary<string, Modifier> ModifiersByFoodicsId { get; init; }
        public required Dictionary<string, MenuItem> ItemsByFoodicsId { get; init; }
        public required Dictionary<int, string> ModifierNamesById { get; init; }
        public required List<ModifierCombinationWeight> Combos { get; init; }
    }

    /// <summary>Loads exactly the modifiers/items/combinations needed to
    /// resolve components for the given brands, once per brand — reused
    /// across every order in the request instead of querying per line.</summary>
    private async Task<Dictionary<int, BrandLookup>> LoadBrandLookupsAsync(IEnumerable<int> brandIds)
    {
        var ids = brandIds.Distinct().ToList();
        if (ids.Count == 0) return new Dictionary<int, BrandLookup>();

        var mods = await _db.Modifiers.Where(m => ids.Contains(m.BrandId)).ToListAsync();
        var items = await _db.MenuItems.Where(i => ids.Contains(i.BrandId)).ToListAsync();
        var combos = await _db.ModifierCombinationWeights.Where(c => ids.Contains(c.BrandId)).ToListAsync();

        var result = new Dictionary<int, BrandLookup>();
        foreach (var brandId in ids)
        {
            var brandMods = mods.Where(m => m.BrandId == brandId).ToList();
            result[brandId] = new BrandLookup
            {
                // GroupBy+First defensively handles a duplicate Foodics id
                // (shouldn't happen, but this is read-only reporting code —
                // never worth a 500 over a data quirk).
                ModifiersByFoodicsId = brandMods.GroupBy(m => m.FoodicsModifierId)
                    .ToDictionary(g => g.Key, g => g.First()),
                ItemsByFoodicsId = items.Where(i => i.BrandId == brandId).GroupBy(i => i.FoodicsProductId)
                    .ToDictionary(g => g.Key, g => g.First()),
                ModifierNamesById = brandMods.ToDictionary(m => m.ModifierId, m => m.Name),
                Combos = combos.Where(c => c.BrandId == brandId).ToList(),
            };
        }
        return result;
    }

    /// <summary>Resolves one weigh event's whole ItemsJson into training
    /// components (base item + every selected modifier, combination-aware).
    /// Never throws on bad data — a missing brand, unparseable JSON, or an
    /// unmapped Foodics id all degrade to a visible "unmapped" component or
    /// an empty list rather than failing the whole export.</summary>
    private (List<TrainingComponentDto> Components, int UnmappedCount) ResolveOrderComponents(
        WeighEvent e, Dictionary<int, int> branchToBrand, Dictionary<int, BrandLookup> lookups)
    {
        var components = new List<TrainingComponentDto>();
        if (string.IsNullOrEmpty(e.ItemsJson)) return (components, 0);
        if (!branchToBrand.TryGetValue(e.BranchId, out var brandId)) return (components, 0);
        if (!lookups.TryGetValue(brandId, out var lookup)) return (components, 0);

        List<WeighEventItemDto>? items;
        try { items = JsonSerializer.Deserialize<List<WeighEventItemDto>>(e.ItemsJson, ItemsJsonReadOptions); }
        catch (JsonException) { return (components, 0); } // malformed old data — treated as "no composition recorded"
        if (items is null) return (components, 0);

        var unmapped = 0;
        // Foodics' own "quantity" isn't a multiplier field anywhere in this
        // app — the tablet already expands "3x Curly Fries" into three
        // separate order lines before it ever weighs or reports the order
        // (see FoodicsOrderRepository), and WeightEvaluator simply sums over
        // every line. So a repeated item here is not a duplicate to collapse
        // — it's a second (or third) real serving, and each occurrence must
        // keep its own line index so its components stay distinguishable
        // from any OTHER item on the same order, not just from each other.
        for (var lineIndex = 0; lineIndex < items.Count; lineIndex++)
        {
            var (lineComponents, lineUnmapped) = ResolveLineComponents(items[lineIndex], lineIndex, lookup);
            components.AddRange(lineComponents);
            unmapped += lineUnmapped;
        }
        return (components, unmapped);
    }

    /// One order line (one item + its selected modifiers) resolved into
    /// components — mirrors resolveSelectedModifiers's two-pass matching
    /// (symmetric combinations first, largest first; then anchored pairs,
    /// whose anchor is deliberately never "claimed" so it can drive several
    /// independent dependent-group overrides at once) so training data
    /// reflects exactly what the tablet itself computes at weigh time.
    private static (List<TrainingComponentDto> Components, int UnmappedCount) ResolveLineComponents(
        WeighEventItemDto item, int lineIndex, BrandLookup lookup)
    {
        var components = new List<TrainingComponentDto>();
        var unmapped = 0;

        if (lookup.ItemsByFoodicsId.TryGetValue(item.MenuItemId, out var menuItem))
            components.Add(new TrainingComponentDto(lineIndex, $"item:{menuItem.MenuItemId}", menuItem.Name, "item"));
        else
        {
            components.Add(new TrainingComponentDto(
                lineIndex, $"unmapped_item:{item.MenuItemId}", item.Name ?? "Unknown item", "unmapped"));
            unmapped++;
        }

        var mods = item.Modifiers ?? [];
        var idByFoodicsId = new Dictionary<string, int>();
        var selectedIds = new HashSet<int>();
        foreach (var m in mods)
        {
            if (lookup.ModifiersByFoodicsId.TryGetValue(m.ModifierId, out var mod))
            {
                idByFoodicsId[m.ModifierId] = mod.ModifierId;
                selectedIds.Add(mod.ModifierId);
            }
        }

        var claimed = new HashSet<int>();

        foreach (var combo in lookup.Combos
                     .Where(c => c.AnchorModifierId == null)
                     .Where(c => c.ModifierIds.All(selectedIds.Contains))
                     .OrderByDescending(c => c.ModifierIds.Count()))
        {
            if (combo.ModifierIds.Any(claimed.Contains)) continue;
            claimed.UnionWith(combo.ModifierIds);
            var label = string.Join(" + ", combo.ModifierIds.Select(id => lookup.ModifierNamesById.GetValueOrDefault(id, "?")));
            components.Add(new TrainingComponentDto(lineIndex, $"combo:{combo.ModifierIdsKey}", label, "combination"));
        }

        foreach (var combo in lookup.Combos
                     .Where(c => c.AnchorModifierId != null)
                     .Where(c => c.ModifierIds.All(selectedIds.Contains)))
        {
            var dependentId = combo.ModifierIds.First(id => id != combo.AnchorModifierId);
            if (claimed.Contains(dependentId)) continue;
            claimed.Add(dependentId); // anchor deliberately never claimed — see resolveSelectedModifiers
            var anchorName = lookup.ModifierNamesById.GetValueOrDefault(combo.AnchorModifierId!.Value, "?");
            var dependentName = lookup.ModifierNamesById.GetValueOrDefault(dependentId, "?");
            components.Add(new TrainingComponentDto(
                lineIndex, $"combo:{combo.ModifierIdsKey}", $"{dependentName} ({anchorName})", "combination"));
        }

        foreach (var m in mods)
        {
            if (!idByFoodicsId.TryGetValue(m.ModifierId, out var internalId))
            {
                components.Add(new TrainingComponentDto(
                    lineIndex, $"unmapped_modifier:{m.ModifierId}", m.Name ?? "Unknown option", "unmapped"));
                unmapped++;
                continue;
            }
            if (claimed.Contains(internalId)) continue;
            components.Add(new TrainingComponentDto(
                lineIndex, $"modifier:{internalId}", lookup.ModifierNamesById.GetValueOrDefault(internalId, "?"), "modifier"));
        }

        return (components, unmapped);
    }

    private string BuildTrainingOrdersCsv(
        List<WeighEvent> rows, Dictionary<int, int> branchToBrand, Dictionary<int, Branch> branchesById,
        Dictionary<int, Brand> brandsById, Dictionary<int, BrandLookup> lookups)
    {
        var csv = new StringBuilder();
        csv.AppendLine(CsvRow(
            "event_id", "brand_code", "branch_name", "weighed_at", "measured_g", "verdict",
            "override_reason", "trusted", "line_count", "lines", "unmapped_count"));

        foreach (var e in rows)
        {
            var brandId = branchToBrand.GetValueOrDefault(e.BranchId);
            var (components, unmapped) = ResolveOrderComponents(e, branchToBrand, lookups);
            var trusted = e.Verdict == "onweight" && string.IsNullOrEmpty(e.OverrideReason);
            // One "item: dependent1;dependent2" chunk per order line, joined
            // by " | " — so a two-item order visibly reads as two items each
            // with their own modifiers, never one flat bag of everything.
            var byLine = components.GroupBy(c => c.LineIndex).OrderBy(g => g.Key);
            var lineChunks = byLine.Select(line =>
            {
                // ResolveLineComponents always adds the item (or unmapped-item)
                // component first, before any modifier — so within one line's
                // group (GroupBy preserves encounter order) it's reliably the
                // first entry; everything after it is that item's own modifiers.
                var lineList = line.ToList();
                var itemLabel = lineList.Count > 0 ? lineList[0].Label : "?";
                var rest = lineList.Skip(1).Select(c => c.Label);
                return rest.Any() ? $"{itemLabel}: {string.Join(";", rest)}" : itemLabel;
            });
            csv.AppendLine(CsvRow(
                e.EventId.ToString(), brandsById.GetValueOrDefault(brandId)?.Code ?? "",
                branchesById.GetValueOrDefault(e.BranchId)?.Name ?? "", e.WeighedAt.ToString("o"),
                e.MeasuredG?.ToString() ?? "", e.Verdict, e.OverrideReason ?? "", trusted ? "true" : "false",
                byLine.Count().ToString(), string.Join(" | ", lineChunks), unmapped.ToString()));
        }
        return csv.ToString();
    }

    private string BuildTrainingComponentsCsv(
        List<WeighEvent> rows, Dictionary<int, int> branchToBrand, Dictionary<int, Branch> branchesById,
        Dictionary<int, Brand> brandsById, Dictionary<int, BrandLookup> lookups)
    {
        var csv = new StringBuilder();
        csv.AppendLine(CsvRow(
            "event_id", "brand_code", "branch_name", "weighed_at", "measured_g", "verdict", "trusted",
            "line_index", "component_key", "component_label", "component_type"));

        foreach (var e in rows)
        {
            var brandId = branchToBrand.GetValueOrDefault(e.BranchId);
            var (components, _) = ResolveOrderComponents(e, branchToBrand, lookups);
            var trusted = e.Verdict == "onweight" && string.IsNullOrEmpty(e.OverrideReason);
            string[] common =
            [
                e.EventId.ToString(), brandsById.GetValueOrDefault(brandId)?.Code ?? "",
                branchesById.GetValueOrDefault(e.BranchId)?.Name ?? "", e.WeighedAt.ToString("o"),
                e.MeasuredG?.ToString() ?? "", e.Verdict, trusted ? "true" : "false",
            ];
            if (components.Count == 0)
            {
                // No resolvable composition — still emit one row so this
                // event isn't silently dropped from component-level analysis.
                csv.AppendLine(CsvRow([.. common, "", "", "", ""]));
                continue;
            }
            foreach (var c in components)
                csv.AppendLine(CsvRow([.. common, c.LineIndex.ToString(), c.Key, c.Label, c.Type]));
        }
        return csv.ToString();
    }
}
