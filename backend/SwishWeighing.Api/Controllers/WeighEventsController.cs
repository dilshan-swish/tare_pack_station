using System.Text;
using System.Text.Json;
using ClosedXML.Excel;
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
        if (body.AggregatorName?.Length > 64)
            return BadRequest(new { error = "aggregatorName must be 64 characters or fewer." });
        if (body.AggregatorRef?.Length > 64)
            return BadRequest(new { error = "aggregatorRef must be 64 characters or fewer." });

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
            AggregatorName = body.AggregatorName,
            AggregatorRef = body.AggregatorRef,
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
            e.UnconfiguredReasonsJson, e.AggregatorName, e.AggregatorRef)));
    }

    /// <summary>
    /// One weigh event's full detail — including its raw item/modifier
    /// composition — for the Weigh History page's "View breakdown" action.
    /// That page's own list (Browse above) deliberately returns only a
    /// lightweight summary per row (it can already scan up to 20,000
    /// candidates when filtering by item), so this is the on-demand fetch for
    /// the ONE row someone actually wants to inspect, reusing the exact same
    /// detail shape the per-device dashboard already shows via List above.
    /// Portal-only, like Export/Browse/TrainingPreview.
    /// </summary>
    [HttpGet("{id:long}")]
    public async Task<ActionResult<WeighEventEntryDto>> GetById(long id)
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });

        var e = await _db.WeighEvents.FindAsync(id);
        if (e is null) return NotFound(new { error = "Weigh event not found." });

        return Ok(new WeighEventEntryDto(
            e.EventId, e.DeviceId, e.FoodicsOrderId, e.ExpectedMinG, e.ExpectedMaxG, e.MeasuredG,
            e.Verdict, e.OverrideReason, e.ItemMissing, e.WeighedAt, e.ItemsJson, e.OrderLabel,
            e.UnconfiguredReasonsJson, e.AggregatorName, e.AggregatorRef));
    }

    /// <summary>
    /// Every weighed order, filterable by brand(s), branch(es), device,
    /// verdict(s), item(s), and date range, as a CSV — either one row per
    /// order (<c>format=orders</c>, the aggregate view) or one row per
    /// order/item/modifier line (<c>format=items</c>, the "tidy" long format
    /// suited to training a weight-prediction model or item-level analytics
    /// without any JSON parsing downstream). "Weighed" is automatic here:
    /// this table only ever contains orders that actually went through
    /// Confirm &amp; Dispatch, so no extra filtering is needed for that.
    /// Portal-only — a tablet's own device key is scoped to its own events
    /// via List above, not this bulk export. Always matches whatever the
    /// Weigh History page currently shows — see Browse below, which applies
    /// the exact same filters (including itemIds and itemCount).
    /// </summary>
    [HttpGet("export")]
    public async Task<IActionResult> Export(
        [FromQuery] int? deviceId, [FromQuery] string? brandIds, [FromQuery] string? branchIds,
        [FromQuery] string? verdicts, [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] string? itemIds, [FromQuery] int? itemCount, [FromQuery] string format = "orders",
        [FromQuery] string fileType = "csv", [FromQuery] string? sortBy = null, [FromQuery] string? sortDir = null)
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });
        if (format != "orders" && format != "items")
            return BadRequest(new { error = "format must be 'orders' or 'items'." });
        if (fileType != "csv" && fileType != "xlsx")
            return BadRequest(new { error = "fileType must be 'csv' or 'xlsx'." });
        if (itemCount is < 0)
            return BadRequest(new { error = "itemCount must be 0 or greater." });

        var brandIdList = ParseIntList(brandIds);
        var branchIdList = ParseIntList(branchIds);
        var verdictList = ParseLowerList(verdicts);
        var itemIdList = ParseIntList(itemIds);

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

        // Unsorted here — the explicit ApplySort below (after every filter,
        // so it's the final step) is this endpoint's one real ordering; the
        // old unconditional `.OrderBy(e => e.WeighedAt)` moved into that same
        // call as its default, so behavior for an unspecified sort is unchanged.
        var rows = await q.ToListAsync();
        var branches = await _db.Branches.ToDictionaryAsync(b => b.BranchId);
        var brands = await _db.Brands.ToDictionaryAsync(b => b.BrandId);
        var deviceLabels = await _db.Devices.ToDictionaryAsync(d => d.DeviceId, d => d.Label);

        // Cheap — no brand lookup needed — so applied before the itemIds
        // resolve below to shrink the row set first.
        if (itemCount.HasValue)
            rows = rows.Where(e => GetItemLineCount(e) == itemCount.Value).ToList();

        // Item filtering needs each order's resolved composition (ItemsJson
        // stores raw Foodics ids, not the internal MenuItemId the portal's
        // item picker uses) — not expressible as a SQL predicate, so resolve
        // the already brand/branch/date/verdict-narrowed rows and keep only
        // the ones containing at least one selected item.
        if (itemIdList != null)
        {
            var branchToBrandForItems = branches.ToDictionary(kv => kv.Key, kv => kv.Value.BrandId);
            var lookupsForItems = await LoadBrandLookupsAsync(
                rows.Select(e => branchToBrandForItems.GetValueOrDefault(e.BranchId)).Distinct());
            var itemKeys = itemIdList.Select(id => $"item:{id}").ToHashSet();
            rows = rows.Where(e =>
            {
                var (components, _) = ResolveOrderComponents(e, branchToBrandForItems, lookupsForItems);
                return components.Any(c => c.Type == "item" && itemKeys.Contains(c.Key));
            }).ToList();
        }

        // Default (nothing specified) stays this endpoint's original
        // chronological-ascending order — the portal always sends its
        // current on-screen sort explicitly, so this default only matters
        // for any other caller of this URL.
        var sortKey = NormalizeSortBy(sortBy);
        var desc = (sortDir?.ToLowerInvariant() ?? "asc") == "desc";
        rows = ApplySort(rows, e => e, sortKey, desc, branches, deviceLabels);

        var (headers, table) = format == "items"
            ? BuildItemLevelTable(rows, branches, brands, deviceLabels)
            : BuildOrderLevelTable(rows, branches, brands, deviceLabels);

        var stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
        if (fileType == "xlsx")
        {
            var xlsxBytes = TableToXlsx(format == "items" ? "Item-level detail" : "Order summary", headers, table);
            return File(xlsxBytes,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                $"weighed-{format}-{stamp}.xlsx");
        }
        var csvBytes = Encoding.UTF8.GetBytes(TableToCsv(headers, table));
        return File(csvBytes, "text/csv", $"weighed-{format}-{stamp}.csv");
    }

    /// <summary>
    /// Paginated, richly-filterable weigh events for the portal's Weigh
    /// History page: brand(s), branch(es), device, verdict(s), date range,
    /// item(s) — orders containing ANY of the given menu items — and
    /// itemCount (orders whose composition has EXACTLY this many item
    /// lines). Distinct from List (device-scoped, for the tablet) and
    /// TrainingPreview (training-specific "clean vs excluded" framing) —
    /// this is the general-purpose operational browser, with Export above as
    /// its matching full-data download.
    /// </summary>
    [HttpGet("browse")]
    public async Task<ActionResult<WeighHistoryResultDto>> Browse(
        [FromQuery] string? brandIds, [FromQuery] string? branchIds, [FromQuery] int? deviceId,
        [FromQuery] string? verdicts, [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] string? itemIds, [FromQuery] int? itemCount,
        [FromQuery] string? sortBy, [FromQuery] string? sortDir,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 25)
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });
        if (itemCount is < 0)
            return BadRequest(new { error = "itemCount must be 0 or greater." });

        page = Math.Max(page, 1);
        pageSize = Math.Clamp(pageSize, 1, 200);

        var (matchedBranches, branchError) = await ResolveMatchedBranchesAsync(brandIds, branchIds);
        if (branchError != null) return BadRequest(new { error = branchError });
        var matchedBranchIds = matchedBranches.Select(b => b.BranchId).ToList();
        var emptyVerdictCounts = new WeighHistoryVerdictCountsDto(0, 0, 0, 0, 0);
        if (matchedBranchIds.Count == 0)
            return Ok(new WeighHistoryResultDto(0, Array.Empty<WeighHistoryRowDto>(), emptyVerdictCounts));

        var verdictList = ParseLowerList(verdicts);
        var itemIdList = ParseIntList(itemIds);
        var sortKey = NormalizeSortBy(sortBy);
        var desc = (sortDir?.ToLowerInvariant() ?? "desc") == "desc";
        // The one case that can stay a pure SQL Skip/Take with no in-memory
        // pass at all — every other sort needs branch/device name lookups
        // (or just a well-defined tie-break shared with Export) that only
        // exist as dictionaries here, see ApplySort.
        var isPlainNewestFirst = sortKey == "weighedat" && desc;

        var q = _db.WeighEvents.Where(e => matchedBranchIds.Contains(e.BranchId));
        if (deviceId.HasValue) q = q.Where(e => e.DeviceId == deviceId.Value);
        if (from.HasValue) q = q.Where(e => e.WeighedAt >= from.Value);
        if (to.HasValue) q = q.Where(e => e.WeighedAt <= to.Value);
        if (verdictList != null) q = q.Where(e => verdictList.Contains(e.Verdict.ToLower()));

        var branchToBrand = matchedBranches.ToDictionary(b => b.BranchId, b => b.BrandId);
        var brandsById = await _db.Brands.ToDictionaryAsync(b => b.BrandId);
        var branchesById = matchedBranches.ToDictionary(b => b.BranchId);
        var deviceLabels = await _db.Devices.ToDictionaryAsync(d => d.DeviceId, d => d.Label);
        var lookups = await LoadBrandLookupsAsync(matchedBranches.Select(b => b.BrandId).Distinct());

        // Item filtering needs each candidate's resolved composition, which
        // only exists once the row is loaded — capped so a request with
        // almost no other filter can't force an unbounded in-memory scan.
        // Every OTHER sort key needs the same in-memory pass for the same
        // reason (branch/device names, or just ApplySort's one shared
        // implementation — see its own comment), so the same cap applies
        // there too.
        const int maxScan = 20_000;

        if (itemIdList == null && !itemCount.HasValue && isPlainNewestFirst)
        {
            // Neither item filter nor a non-default sort is active — page
            // directly in SQL, cheap regardless of how much history exists.
            // `q` here already has every active filter applied (branch,
            // device, date, verdict), so this breakdown is exactly the
            // population "N orders match" describes — never a separately-
            // scoped "overall" number.
            var total = await q.CountAsync();
            var verdictGroups = await q.GroupBy(e => e.Verdict.ToLower())
                .Select(g => new { Verdict = g.Key, Count = g.Count() })
                .ToListAsync();
            int CountFor(string verdict) => verdictGroups.FirstOrDefault(g => g.Verdict == verdict)?.Count ?? 0;
            var pageCounts = new WeighHistoryVerdictCountsDto(
                total, CountFor("onweight"), CountFor("under"), CountFor("over"), CountFor("unconfigured"));

            var pageRows = await q.OrderByDescending(e => e.WeighedAt)
                .Skip((page - 1) * pageSize).Take(pageSize).ToListAsync();
            return Ok(new WeighHistoryResultDto(total, pageRows.Select(e =>
                ToBrowseRow(e, branchToBrand, branchesById, brandsById, deviceLabels, lookups)).ToList(),
                pageCounts));
        }

        if (itemIdList == null && !itemCount.HasValue)
        {
            // A non-default sort, but no item filter — still bounded by the
            // same cap as the item-filter path below, for the same reason
            // (everything has to come into memory to sort it).
            var total = await q.CountAsync();
            if (total > maxScan)
                return BadRequest(new
                {
                    error = $"That's {total:N0} matching orders — narrow the date range or branches first " +
                        $"(sorting by anything other than newest-first is capped at {maxScan:N0} rows)."
                });
            var verdictGroups = await q.GroupBy(e => e.Verdict.ToLower())
                .Select(g => new { Verdict = g.Key, Count = g.Count() })
                .ToListAsync();
            int CountFor(string verdict) => verdictGroups.FirstOrDefault(g => g.Verdict == verdict)?.Count ?? 0;
            var pageCounts = new WeighHistoryVerdictCountsDto(
                total, CountFor("onweight"), CountFor("under"), CountFor("over"), CountFor("unconfigured"));

            var allRows = await q.ToListAsync();
            var sortedRows = ApplySort(allRows, e => e, sortKey, desc, branchesById, deviceLabels);
            var pageRows = sortedRows.Skip((page - 1) * pageSize).Take(pageSize).ToList();
            return Ok(new WeighHistoryResultDto(total, pageRows.Select(e =>
                ToBrowseRow(e, branchToBrand, branchesById, brandsById, deviceLabels, lookups)).ToList(),
                pageCounts));
        }

        var candidateCount = await q.CountAsync();
        if (candidateCount > maxScan)
            return BadRequest(new
            {
                error = $"That's {candidateCount:N0} rows before the item filter — narrow the date range or " +
                    $"branches first (searching by item is capped at {maxScan:N0} candidate rows)."
            });

        var candidates = await q.ToListAsync();
        var itemKeys = itemIdList?.Select(id => $"item:{id}").ToHashSet();
        var matched = new List<(WeighEvent Event, List<TrainingComponentDto> Components)>();
        foreach (var e in candidates)
        {
            // Cheapest check first, so a non-matching row skips the (pricier)
            // component resolution below entirely.
            if (itemCount.HasValue && GetItemLineCount(e) != itemCount.Value) continue;
            var (components, _) = ResolveOrderComponents(e, branchToBrand, lookups);
            if (itemKeys != null && !components.Any(c => c.Type == "item" && itemKeys.Contains(c.Key)))
                continue;
            matched.Add((e, components));
        }

        // Same population as `matched.Count` (the "N orders match" figure) —
        // computed in-memory since `matched` is already fully resolved and
        // filtered (branch/device/date/verdict/items/itemCount all applied).
        var verdictCounts = new WeighHistoryVerdictCountsDto(
            matched.Count,
            matched.Count(m => m.Event.Verdict.ToLower() == "onweight"),
            matched.Count(m => m.Event.Verdict.ToLower() == "under"),
            matched.Count(m => m.Event.Verdict.ToLower() == "over"),
            matched.Count(m => m.Event.Verdict.ToLower() == "unconfigured"));

        var sortedMatched = ApplySort(matched, m => m.Event, sortKey, desc, branchesById, deviceLabels);
        var pageMatched = sortedMatched.Skip((page - 1) * pageSize).Take(pageSize).ToList();
        return Ok(new WeighHistoryResultDto(matched.Count, pageMatched.Select(m =>
            ToBrowseRow(m.Event, branchToBrand, branchesById, brandsById, deviceLabels, lookups, m.Components)).ToList(),
            verdictCounts));
    }

    /// <summary>
    /// Every weighed order matching EXACTLY the same filters as Browse
    /// (brand(s), branch(es), device, verdict(s), date range, item(s),
    /// itemCount) — but unpaginated, lightweight points for the portal's
    /// Expected-vs-Measured scatter chart rather than display rows. Two
    /// separate caps: the same 20,000-candidate scan cap Browse uses when an
    /// item filter needs resolving, and a much smaller 5,000-point plot cap
    /// (a scatter with more points than that stops being readable anyway —
    /// narrowing the filters is the right fix, not shipping more data the
    /// chart can't usefully show).
    /// </summary>
    [HttpGet("scatter")]
    public async Task<ActionResult<WeighScatterResultDto>> Scatter(
        [FromQuery] string? brandIds, [FromQuery] string? branchIds, [FromQuery] int? deviceId,
        [FromQuery] string? verdicts, [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] string? itemIds, [FromQuery] int? itemCount)
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });
        if (itemCount is < 0)
            return BadRequest(new { error = "itemCount must be 0 or greater." });

        var (matchedBranches, branchError) = await ResolveMatchedBranchesAsync(brandIds, branchIds);
        if (branchError != null) return BadRequest(new { error = branchError });
        var matchedBranchIds = matchedBranches.Select(b => b.BranchId).ToList();
        if (matchedBranchIds.Count == 0)
            return Ok(new WeighScatterResultDto(0, 0, Array.Empty<WeighScatterPointDto>()));

        var verdictList = ParseLowerList(verdicts);
        var itemIdList = ParseIntList(itemIds);

        var q = _db.WeighEvents.Where(e => matchedBranchIds.Contains(e.BranchId));
        if (deviceId.HasValue) q = q.Where(e => e.DeviceId == deviceId.Value);
        if (from.HasValue) q = q.Where(e => e.WeighedAt >= from.Value);
        if (to.HasValue) q = q.Where(e => e.WeighedAt <= to.Value);
        if (verdictList != null) q = q.Where(e => verdictList.Contains(e.Verdict.ToLower()));

        const int maxScan = 20_000;
        const int maxPoints = 5_000;

        // Needed for every point's BrandCode below, not just the item-filter
        // path — cheap (brand rows only), unlike the full per-order component
        // resolution that path does.
        var branchToBrandAll = matchedBranches.ToDictionary(b => b.BranchId, b => b.BrandId);
        var brandCodesById = await _db.Brands
            .Where(b => matchedBranches.Select(mb => mb.BrandId).Distinct().Contains(b.BrandId))
            .ToDictionaryAsync(b => b.BrandId, b => b.Code);

        List<WeighEvent> matchedEvents;
        if (itemIdList == null && !itemCount.HasValue)
        {
            var candidateCount = await q.CountAsync();
            if (candidateCount > maxScan)
                return BadRequest(new
                {
                    error = $"That's {candidateCount:N0} matching orders — narrow the date range or branches " +
                        $"first (the chart is capped at {maxScan:N0} candidate rows)."
                });
            matchedEvents = await q.ToListAsync();
        }
        else
        {
            var candidateCount = await q.CountAsync();
            if (candidateCount > maxScan)
                return BadRequest(new
                {
                    error = $"That's {candidateCount:N0} rows before the item filter — narrow the date range or " +
                        $"branches first (searching by item is capped at {maxScan:N0} candidate rows)."
                });

            var lookups = await LoadBrandLookupsAsync(matchedBranches.Select(b => b.BrandId).Distinct());
            var candidates = await q.ToListAsync();
            var itemKeys = itemIdList?.Select(id => $"item:{id}").ToHashSet();
            matchedEvents = new List<WeighEvent>();
            foreach (var e in candidates)
            {
                if (itemCount.HasValue && GetItemLineCount(e) != itemCount.Value) continue;
                if (itemKeys != null)
                {
                    var (components, _) = ResolveOrderComponents(e, branchToBrandAll, lookups);
                    if (!components.Any(c => c.Type == "item" && itemKeys.Contains(c.Key))) continue;
                }
                matchedEvents.Add(e);
            }
        }

        var points = new List<WeighScatterPointDto>();
        var excluded = 0;
        foreach (var e in matchedEvents)
        {
            if (e.ExpectedMinG is null || e.ExpectedMaxG is null || e.MeasuredG is null) { excluded++; continue; }
            var brandId = branchToBrandAll.GetValueOrDefault(e.BranchId);
            points.Add(new WeighScatterPointDto(e.EventId, e.ExpectedMinG.Value, e.ExpectedMaxG.Value,
                e.MeasuredG.Value, e.Verdict, brandCodesById.GetValueOrDefault(brandId)));
        }

        if (points.Count > maxPoints)
            return BadRequest(new
            {
                error = $"That's {points.Count:N0} plottable orders — narrow your filters first (the chart is " +
                    $"capped at {maxPoints:N0} points so it stays readable)."
            });

        return Ok(new WeighScatterResultDto(points.Count, excluded, points));
    }

    /// <summary>The number of item lines in one weigh event's composition
    /// snapshot (matches the count behind ToBrowseRow's own ItemNames column)
    /// — cheap on purpose: unlike the itemIds filter, a line count needs no
    /// brand/catalog lookup at all, just the raw ItemsJson. Null (never 0)
    /// when there's no parseable composition — an order with unknown
    /// composition can't be confirmed to match any specific count, so the
    /// item-count filter below excludes it rather than guessing.</summary>
    private static int? GetItemLineCount(WeighEvent e)
    {
        if (string.IsNullOrEmpty(e.ItemsJson)) return null;
        try
        {
            var items = JsonSerializer.Deserialize<List<WeighEventItemDto>>(e.ItemsJson, ItemsJsonReadOptions);
            return items?.Count;
        }
        catch (JsonException)
        {
            return null; // malformed old data — treated as "unknown", same as elsewhere in this file
        }
    }

    /// <summary>Builds one Weigh History row. [components], when supplied,
    /// skips re-resolving the order (the item-filter path in Browse above
    /// already resolved every candidate once to filter by item).</summary>
    private WeighHistoryRowDto ToBrowseRow(
        WeighEvent e, Dictionary<int, int> branchToBrand, Dictionary<int, Branch> branchesById,
        Dictionary<int, Brand> brandsById, Dictionary<int, string> deviceLabels,
        Dictionary<int, BrandLookup> lookups, List<TrainingComponentDto>? components = null)
    {
        var brandId = branchToBrand.GetValueOrDefault(e.BranchId);
        components ??= ResolveOrderComponents(e, branchToBrand, lookups).Components;
        // "unmapped" also covers unmapped MODIFIERS (Key "unmapped_modifier:…")
        // — only the item-level ones belong in this item-names summary.
        var itemNames = components
            .Where(c => c.Type == "item" || (c.Type == "unmapped" && c.Key.StartsWith("unmapped_item:")))
            .Select(c => c.Label).ToList();
        return new WeighHistoryRowDto(
            e.EventId, e.WeighedAt, brandsById.GetValueOrDefault(brandId)?.Code,
            branchesById.GetValueOrDefault(e.BranchId)?.Name,
            e.DeviceId.HasValue ? deviceLabels.GetValueOrDefault(e.DeviceId.Value) : null,
            e.OrderLabel, e.ExpectedMinG, e.ExpectedMaxG, e.MeasuredG, e.Verdict, e.OverrideReason, itemNames);
    }

    /// <summary>
    /// Permanently deletes every weigh event for the given branch(es) — the
    /// portal's "Clear weigh events" tool. Branch ids are required and never
    /// implied, so clearing every branch means selecting every branch
    /// explicitly rather than one "delete everything" shortcut. Portal-only,
    /// same as Export — there is no confirmation step here beyond the
    /// portal's own dialog, since this endpoint has no way to ask the person
    /// twice itself.
    /// </summary>
    [HttpPost("bulk-delete")]
    public async Task<IActionResult> BulkDelete([FromBody] BulkDeleteWeighEventsDto body)
    {
        if (HttpContext.Items["DeviceId"] is int)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Not available to a device key." });
        var ids = body.BranchIds?.Distinct().ToList() ?? [];
        if (ids.Count == 0)
            return BadRequest(new { error = "At least one branchId is required." });

        var deleted = await _db.WeighEvents.Where(e => ids.Contains(e.BranchId)).ExecuteDeleteAsync();
        return Ok(new { deletedCount = deleted, branchIds = ids });
    }

    /// Every column the Weigh History table (and its export) can be sorted
    /// by. Kept as one source of truth so Browse and Export can never
    /// recognize a different set of keys from each other.
    private static readonly HashSet<string> ValidSortKeys =
        new() { "weighedat", "branch", "device", "expected", "measured", "deviation", "verdict", "overridereason" };

    /// An unrecognized or missing key always falls back to "weighedat" rather
    /// than erroring — this only ever comes from the portal's own UI, so a
    /// stale/mistyped value should degrade gracefully, not break the page.
    private static string NormalizeSortBy(string? sortBy)
    {
        var s = sortBy?.Trim().ToLowerInvariant();
        return s != null && ValidSortKeys.Contains(s) ? s : "weighedat";
    }

    /// Sorts any sequence of (something carrying a WeighEvent) by one of the
    /// portal's table columns — used identically by Browse (paginating an
    /// already-filtered population) and Export (the full filtered file), so
    /// the on-screen order and the downloaded order can never silently
    /// disagree. Always resolved in memory rather than pushed to SQL:
    /// branch/device names only exist as lookup dictionaries here, and one
    /// sort implementation is far less likely to drift than a second,
    /// SQL-expression version that would have to agree with this one on
    /// every tie-break and null-ordering rule.
    private static List<T> ApplySort<T>(
        List<T> items, Func<T, WeighEvent> ev, string sortKey, bool desc,
        Dictionary<int, Branch> branchesById, Dictionary<int, string> deviceLabels)
    {
        // A missing value (no measurement yet, an unconfigured order with no
        // expected range, no override reason, an orphaned branch/device id)
        // always sorts to the END, regardless of direction — it represents
        // "nothing recorded", not "the smallest value". Flipping a page of
        // blanks to the TOP the instant someone clicks "ascending" would read
        // as a bug, not merely a quirky default — every mainstream
        // spreadsheet/table UI keeps blanks pinned last both ways.
        List<T> OrderNullsLast<TKey>(Func<T, TKey> key) =>
            (desc
                ? items.OrderBy(x => key(x) is null).ThenByDescending(key)
                : items.OrderBy(x => key(x) is null).ThenBy(key))
            .ToList();

        return sortKey switch
        {
            "measured" => OrderNullsLast(x => ev(x).MeasuredG),
            "expected" => OrderNullsLast(x => ev(x).ExpectedMinG),
            "deviation" => OrderNullsLast(x => DeviationOf(ev(x))),
            "verdict" => OrderNullsLast(x => ev(x).Verdict),
            "overridereason" => OrderNullsLast(x => ev(x).OverrideReason),
            "branch" => OrderNullsLast(x => branchesById.GetValueOrDefault(ev(x).BranchId)?.Name),
            "device" => OrderNullsLast(x => ev(x).DeviceId.HasValue ? deviceLabels.GetValueOrDefault(ev(x).DeviceId!.Value) : null),
            _ => OrderNullsLast(x => ev(x).WeighedAt),
        };
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

    /// measured − the midpoint of [expectedMin, expectedMax] — the exact same
    /// definition the portal's scatter chart already uses (deviationOf in
    /// WeighHistoryPage.tsx), so a number quoted from the table, the chart, or
    /// an export always means the same thing. Null whenever any of the three
    /// inputs is missing (an unconfigured verdict, most commonly) — never
    /// silently rendered as 0, which would read as "spot on" for an order
    /// that was never actually evaluated.
    private static decimal? DeviationOf(WeighEvent e) =>
        e.MeasuredG.HasValue && e.ExpectedMinG.HasValue && e.ExpectedMaxG.HasValue
            ? e.MeasuredG.Value - (e.ExpectedMinG.Value + e.ExpectedMaxG.Value) / 2
            : null;

    /// One row per weighed order — the aggregate view, quick to skim. Shared
    /// by the CSV and Excel export paths (see ExportTableToCsv/ExportTableToXlsx)
    /// so the two file types can never drift apart on what columns they carry.
    private static (string[] Headers, List<string[]> Rows) BuildOrderLevelTable(
        List<WeighEvent> rows, Dictionary<int, Branch> branches,
        Dictionary<int, Brand> brands, Dictionary<int, string> deviceLabels)
    {
        string[] headers =
        [
            "event_id", "brand_id", "brand_code", "branch_id", "branch_name",
            "device_id", "device_label", "order_label", "foodics_order_id", "weighed_at",
            "expected_min_g", "expected_max_g", "measured_g", "deviation_g", "verdict",
            "override_reason", "item_missing", "items_json",
        ];
        var body = new List<string[]>(rows.Count);
        foreach (var e in rows)
        {
            branches.TryGetValue(e.BranchId, out var branch);
            brands.TryGetValue(branch?.BrandId ?? -1, out var brand);
            var deviceLabel = e.DeviceId.HasValue ? deviceLabels.GetValueOrDefault(e.DeviceId.Value, "") : "";
            body.Add([
                e.EventId.ToString(), branch?.BrandId.ToString() ?? "", brand?.Code ?? "",
                e.BranchId.ToString(), branch?.Name ?? "",
                e.DeviceId?.ToString() ?? "", deviceLabel, e.OrderLabel ?? "",
                e.FoodicsOrderId ?? "", e.WeighedAt.ToString("o"),
                e.ExpectedMinG?.ToString() ?? "", e.ExpectedMaxG?.ToString() ?? "",
                e.MeasuredG?.ToString() ?? "", DeviationOf(e)?.ToString() ?? "", e.Verdict, e.OverrideReason ?? "",
                e.ItemMissing?.ToString() ?? "", e.ItemsJson ?? "",
            ]);
        }
        return (headers, body);
    }

    /// One row per order/item/modifier line — "tidy" long format: every
    /// order-level field repeats across its item rows, and every item with no
    /// modifiers still gets exactly one row (empty modifier columns), so
    /// grouping by event_id always reconstructs the whole order. Ready for a
    /// training pipeline or a pivot table with no JSON parsing anywhere.
    private static (string[] Headers, List<string[]> Rows) BuildItemLevelTable(
        List<WeighEvent> rows, Dictionary<int, Branch> branches,
        Dictionary<int, Brand> brands, Dictionary<int, string> deviceLabels)
    {
        string[] headers =
        [
            "event_id", "brand_id", "brand_code", "branch_id", "branch_name",
            "device_id", "device_label", "order_label", "foodics_order_id", "weighed_at",
            "expected_min_g", "expected_max_g", "measured_g", "deviation_g", "verdict",
            "override_reason", "item_missing",
            "line_index", "menu_item_id", "menu_item_name", "modifier_id", "modifier_name",
        ];
        var body = new List<string[]>();

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
                e.MeasuredG?.ToString() ?? "", DeviationOf(e)?.ToString() ?? "", e.Verdict, e.OverrideReason ?? "",
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
                body.Add([.. common, "", "", "", "", ""]);
                continue;
            }

            for (var i = 0; i < items.Count; i++)
            {
                var item = items[i];
                if (item.Modifiers is null || item.Modifiers.Count == 0)
                {
                    body.Add([.. common, (i + 1).ToString(), item.MenuItemId, item.Name ?? "", "", ""]);
                    continue;
                }
                foreach (var mod in item.Modifiers)
                {
                    body.Add([
                        .. common, (i + 1).ToString(), item.MenuItemId, item.Name ?? "",
                        mod.ModifierId, mod.Name ?? "",
                    ]);
                }
            }
        }
        return (headers, body);
    }

    private static string TableToCsv(string[] headers, List<string[]> rows)
    {
        var csv = new StringBuilder();
        csv.AppendLine(CsvRow(headers));
        foreach (var row in rows) csv.AppendLine(CsvRow(row));
        return csv.ToString();
    }

    /// Same table, as a real .xlsx workbook — a bold frozen header row and
    /// Excel's own native AutoFilter dropdowns on every column, so "sort and
    /// filter this in Excel" works immediately on open with no setup. Mirrors
    /// FormatSheet's conventions in MenuImportExportController.
    private static byte[] TableToXlsx(string sheetName, string[] headers, List<string[]> rows)
    {
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add(sheetName);
        for (var c = 0; c < headers.Length; c++) ws.Cell(1, c + 1).Value = headers[c];
        for (var r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            for (var c = 0; c < row.Length; c++) ws.Cell(r + 2, c + 1).Value = row[c];
        }
        ws.Row(1).Style.Font.Bold = true;
        ws.SheetView.FreezeRows(1);
        if (rows.Count > 0) ws.RangeUsed()?.SetAutoFilter();
        if (headers.Length > 0) ws.Columns(1, headers.Length).AdjustToContents();
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
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
