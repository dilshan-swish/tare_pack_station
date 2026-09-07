using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;
using SwishWeighing.Api.Services;

namespace SwishWeighing.Api.Controllers;

[ApiController]
[Route("api")]
public class DevicesController : ControllerBase
{
    private readonly AppDbContext _db;
    public DevicesController(AppDbContext db) => _db = db;

    /// <summary>
    /// Tablets registered to a branch, with online status. Includes removed
    /// (IsActive = false) devices too, listed after the active ones — a
    /// removed device still needs to be findable in the portal so it can be
    /// reconnected via RegenerateKey below without losing its history,
    /// rather than only being reachable by re-adding it as a brand new one.
    /// </summary>
    [HttpGet("branches/{branchId:int}/devices")]
    public async Task<ActionResult<IEnumerable<DeviceDto>>> List(int branchId)
    {
        var devices = await _db.Devices
            .Where(d => d.BranchId == branchId)
            .OrderByDescending(d => d.IsActive)
            .ThenBy(d => d.Label)
            .ToListAsync();
        return Ok(devices.Select(d => new DeviceDto(
            d.DeviceId, d.BranchId, d.Label, d.AppVersion, d.LastSeenAt,
            d.IsActive && DeviceStatus.IsOnline(d.LastSeenAt), d.IsActive)));
    }

    /// <summary>Registers a tablet to a branch. Returns its key ONCE.</summary>
    [HttpPost("branches/{branchId:int}/devices")]
    public async Task<ActionResult<DeviceCreatedDto>> Create(int branchId, [FromBody] CreateDeviceDto body)
    {
        var branch = await _db.Branches.FindAsync(branchId);
        if (branch is null) return NotFound(new { error = "Branch not found." });
        if (string.IsNullOrWhiteSpace(body.Label))
            return BadRequest(new { error = "A label is required (e.g. 'Pack station 1')." });
        // Label maps to NVARCHAR(64) (docs/sql/01_schema.sql) — reject
        // oversized input with a clean error instead of letting a SQL
        // truncation exception surface as an unhandled 500.
        if (body.Label.Trim().Length > 64)
            return BadRequest(new { error = "Label must be 64 characters or fewer." });

        var key = DeviceKeys.Generate();
        var device = new Device
        {
            BranchId = branchId,
            Label = body.Label.Trim(),
            ApiKeyHash = DeviceKeys.Hash(key),
            IsActive = true,
            CreatedAt = DateTime.UtcNow,
        };
        _db.Devices.Add(device);
        await _db.SaveChangesAsync();
        return Ok(new DeviceCreatedDto(device.DeviceId, device.Label, key));
    }

    /// <summary>Deactivates (revokes) a tablet.</summary>
    [HttpDelete("devices/{id:int}")]
    public async Task<IActionResult> Deactivate(int id)
    {
        var d = await _db.Devices.FindAsync(id);
        if (d is null) return NotFound();
        d.IsActive = false;
        await _db.SaveChangesAsync();
        return Ok(new { d.DeviceId, d.IsActive });
    }

    /// <summary>
    /// Issues a brand-new key for an EXISTING device — its own DeviceId (and
    /// therefore every weigh event / connection-log entry already tied to it)
    /// is untouched, unlike deleting and re-adding a scale, which creates a
    /// new DeviceId and orphans its whole history. Reconnecting a scale that
    /// lost its key/connection, or bringing a previously-removed one back,
    /// should always use this instead of re-adding. Also reactivates the
    /// device (IsActive = true) so a previously removed scale can be brought
    /// back the same way. The new key is returned once, exactly like at
    /// creation — it is never stored or shown again after this response.
    /// </summary>
    [HttpPost("devices/{id:int}/regenerate-key")]
    public async Task<ActionResult<DeviceCreatedDto>> RegenerateKey(int id)
    {
        var device = await _db.Devices.FindAsync(id);
        if (device is null) return NotFound(new { error = "Device not found." });

        var key = DeviceKeys.Generate();
        device.ApiKeyHash = DeviceKeys.Hash(key);
        device.IsActive = true;
        await _db.SaveChangesAsync();
        return Ok(new DeviceCreatedDto(device.DeviceId, device.Label, key));
    }

    /// <summary>
    /// Moves a tablet to a different branch (and, transitively, a different
    /// brand, if the target branch belongs to one) — the scale's own key is
    /// untouched, so it keeps working with zero re-registration. The next
    /// time the tablet checks in (heartbeat / version-check / config fetch),
    /// it resolves brand+branch fresh from its own key, so it automatically
    /// picks up the new brand's menu — nothing else to wire up.
    /// </summary>
    [HttpPatch("devices/{id:int}")]
    public async Task<IActionResult> Reassign(int id, [FromBody] ReassignDeviceDto body)
    {
        var device = await _db.Devices.FindAsync(id);
        if (device is null) return NotFound(new { error = "Device not found." });

        var branch = await _db.Branches.FindAsync(body.BranchId);
        if (branch is null) return NotFound(new { error = "Target branch not found." });

        device.BranchId = body.BranchId;
        await _db.SaveChangesAsync();
        return Ok(new { device.DeviceId, device.BranchId });
    }

    /// <summary>
    /// One device's full detail for the portal's per-scale dashboard: its
    /// branch/brand (resolved fresh, same as MyConfig) and the most recent
    /// entry from its error/status log, if any.
    /// </summary>
    [HttpGet("devices/{id:int}")]
    public async Task<ActionResult<DeviceDetailDto>> Detail(int id)
    {
        var d = await _db.Devices.FindAsync(id);
        if (d is null) return NotFound();

        var branch = await _db.Branches.FindAsync(d.BranchId);
        if (branch is null) return NotFound(new { error = "This device's branch no longer exists." });
        var brand = await _db.Brands.FindAsync(branch.BrandId);
        if (brand is null) return NotFound(new { error = "This device's brand no longer exists." });

        var last = await _db.DeviceEvents
            .Where(e => e.DeviceId == id)
            .OrderByDescending(e => e.OccurredAt)
            .FirstOrDefaultAsync();

        return Ok(new DeviceDetailDto(
            d.DeviceId, d.Label, d.AppVersion, d.LastSeenAt,
            d.IsActive && DeviceStatus.IsOnline(d.LastSeenAt), d.IsActive,
            branch.BranchId, branch.Name, brand.BrandId, brand.Code, brand.Name,
            last is null ? null : new DeviceEventLogEntryDto(
                last.DeviceEventId, last.EventType, last.Reason, last.Detail, last.OccurredAt),
            branch.NameLocalized));
    }

    /// <summary>
    /// Cheap poll target for near-real-time menu sync: just the current
    /// published version for this device's own brand — nowhere near the cost
    /// of the full config, so the tablet can check it every ~20s and only
    /// pull the full item/modifier list when it actually changes.
    /// </summary>
    [HttpGet("devices/me/version")]
    public async Task<ActionResult<DeviceVersionDto>> MyVersion()
    {
        if (HttpContext.Items["BranchId"] is not int branchId)
            return Unauthorized(new { error = "A valid X-Device-Key is required." });

        var branch = await _db.Branches.FindAsync(branchId);
        if (branch is null) return NotFound();
        var brand = await _db.Brands.FindAsync(branch.BrandId);
        if (brand is null) return NotFound();

        return Ok(new DeviceVersionDto(brand.PublishedVersion, brand.MenuSyncedVersion));
    }

    /// <summary>
    /// Cheap poll target for the ML weight-prediction model — same "poll a
    /// version, only pull the full thing when it changed" pattern as the menu
    /// version check above. A null body (still 200) means this brand has no
    /// model published yet — a perfectly normal, permanent state until one is
    /// uploaded, not an error — in which case the tablet keeps using its
    /// statistical fallback. Deliberately not a 404: that would report as a
    /// failed request on every single poll for any brand without a model,
    /// despite being fully expected.
    /// </summary>
    [HttpGet("devices/me/model-version")]
    public async Task<ActionResult<ModelMetaDto?>> MyModelVersion()
    {
        if (HttpContext.Items["BranchId"] is not int branchId)
            return Unauthorized(new { error = "A valid X-Device-Key is required." });

        var branch = await _db.Branches.FindAsync(branchId);
        if (branch is null) return NotFound();
        var model = await _db.BrandWeightModels.FindAsync(branch.BrandId);
        if (model is null) return Ok(null);

        return Ok(new ModelMetaDto(model.Version, model.FileName, model.SizeBytes, model.Sha256Hash, model.UploadedAt));
    }

    /// <summary>The actual model bytes — downloaded only when MyModelVersion shows a new version.</summary>
    [HttpGet("devices/me/model")]
    public async Task<IActionResult> MyModel()
    {
        if (HttpContext.Items["BranchId"] is not int branchId)
            return Unauthorized(new { error = "A valid X-Device-Key is required." });

        var branch = await _db.Branches.FindAsync(branchId);
        if (branch is null) return NotFound();
        var model = await _db.BrandWeightModels.FindAsync(branch.BrandId);
        if (model is null) return NotFound();

        return File(model.ModelBytes, "application/octet-stream", model.FileName);
    }

    /// <summary>
    /// The tablet reports a connectivity problem (or its recovery) here — only
    /// on a CHANGE of classification, not on every failed poll, so this stays
    /// a signal rather than noise. Requires the tablet to have SOME working
    /// path to the API; a tablet with zero connectivity obviously can't phone
    /// home to explain why — the portal falls back to "last seen" staleness
    /// for that case.
    /// </summary>
    [HttpPost("devices/events")]
    public async Task<IActionResult> ReportEvent([FromBody] DeviceEventDto body)
    {
        if (HttpContext.Items["DeviceId"] is not int deviceId)
            return Unauthorized(new { error = "A valid X-Device-Key is required." });
        if (body is null || string.IsNullOrWhiteSpace(body.EventType) || string.IsNullOrWhiteSpace(body.Reason))
            return BadRequest(new { error = "eventType and reason are required." });
        // Columns are NVARCHAR(32)/NVARCHAR(64)/NVARCHAR(400)
        // (docs/sql/07_device_events.sql) — reject oversized input cleanly
        // instead of letting a SQL truncation exception become an
        // unhandled 500.
        if (body.EventType.Length > 32)
            return BadRequest(new { error = "eventType must be 32 characters or fewer." });
        if (body.Reason.Length > 64)
            return BadRequest(new { error = "reason must be 64 characters or fewer." });
        if (body.Detail is { Length: > 400 })
            return BadRequest(new { error = "detail must be 400 characters or fewer." });

        _db.DeviceEvents.Add(new DeviceEvent
        {
            DeviceId = deviceId,
            EventType = body.EventType,
            Reason = body.Reason,
            Detail = body.Detail,
            OccurredAt = body.OccurredAt ?? DateTime.UtcNow,
            CreatedAt = DateTime.UtcNow,
        });
        await _db.SaveChangesAsync();
        return Ok();
    }

    /// <summary>Recent error/status log entries for a device (portal-facing).</summary>
    [HttpGet("devices/{id:int}/events")]
    public async Task<ActionResult<IEnumerable<DeviceEventLogEntryDto>>> Events(int id, [FromQuery] int limit = 50)
    {
        var rows = await _db.DeviceEvents
            .Where(e => e.DeviceId == id)
            .OrderByDescending(e => e.OccurredAt)
            .Take(Math.Clamp(limit, 1, 200))
            .ToListAsync();
        return Ok(rows.Select(e => new DeviceEventLogEntryDto(
            e.DeviceEventId, e.EventType, e.Reason, e.Detail, e.OccurredAt)));
    }

    /// <summary>Called by the tablet (X-Device-Key). Marks it seen just now.</summary>
    [HttpPost("devices/heartbeat")]
    public async Task<IActionResult> Heartbeat([FromBody] HeartbeatDto? body)
    {
        if (HttpContext.Items["DeviceId"] is not int deviceId)
            return Unauthorized(new { error = "A valid X-Device-Key is required." });

        var d = await _db.Devices.FindAsync(deviceId);
        if (d is null) return NotFound();
        d.LastSeenAt = DateTime.UtcNow;
        if (!string.IsNullOrWhiteSpace(body?.AppVersion)) d.AppVersion = body.AppVersion;
        await _db.SaveChangesAsync();
        return Ok(new { d.DeviceId, d.LastSeenAt });
    }

    /// <summary>
    /// The tablet's own published config — items + modifiers with weights —
    /// resolved from its device key alone (device -> branch -> brand), so the
    /// tablet never needs to know or store a brand id. This is what makes a
    /// modifier weight set in the portal (e.g. "Curly Fries" = 150g) actually
    /// reach the pack station's weigh-check.
    /// </summary>
    [HttpGet("devices/me/config")]
    public async Task<ActionResult<BrandConfigDto>> MyConfig()
    {
        if (HttpContext.Items["BranchId"] is not int branchId)
            return Unauthorized(new { error = "A valid X-Device-Key is required." });

        var branch = await _db.Branches.FindAsync(branchId);
        if (branch is null) return NotFound(new { error = "Branch not found for this device." });

        var brand = await _db.Brands.FindAsync(branch.BrandId);
        if (brand is null) return NotFound(new { error = "Brand not found for this device's branch." });

        // Deliberately NOT filtered to IsActive: an item/modifier that Foodics
        // has marked inactive still needs to be visible to staff (e.g. it may
        // still be sitting, unweighed, on an old order) — the tablet greys
        // these out rather than hiding them, same as the portal.
        var items = await _db.MenuItems
            .Where(m => m.BrandId == brand.BrandId).OrderBy(m => m.Name).ToListAsync();
        var mods = await _db.Modifiers
            .Where(m => m.BrandId == brand.BrandId).OrderBy(m => m.Name).ToListAsync();
        var itemMods = await BrandsController.ItemModifierFoodicsIdsAsync(_db, brand.BrandId);
        var combinations = await BrandsController.ModifierCombinationConfigsAsync(_db, brand.BrandId);

        return Ok(new BrandConfigDto(
            brand.BrandId, brand.Code, brand.Name, brand.PublishedVersion,
            items.Select(m => BrandsController.ToItemDto(m, itemMods)).ToList(),
            mods.Select(BrandsController.ToModDto).ToList(),
            branch.FoodicsBranchId, branch.Name,
            branch.NameLocalized, branch.OpeningFrom, branch.OpeningTo,
            brand.MenuSyncedVersion, combinations));
    }
}
