using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Services;

namespace SwishWeighing.Api.Controllers;

[ApiController]
[Route("api")]
public class BranchesController : ControllerBase
{
    private readonly AppDbContext _db;
    private readonly FoodicsService _foodics;

    public BranchesController(AppDbContext db, FoodicsService foodics)
    {
        _db = db;
        _foodics = foodics;
    }

    /// <summary>Branches for a brand, each with tablet count + how many are online.</summary>
    [HttpGet("brands/{brandId:int}/branches")]
    public async Task<ActionResult<IEnumerable<BranchDto>>> List(int brandId)
    {
        var cutoff = DateTime.UtcNow - DeviceStatus.OnlineWindow;
        var branches = await _db.Branches
            .Where(b => b.BrandId == brandId)
            .OrderBy(b => b.Name)
            .ToListAsync();

        var result = new List<BranchDto>();
        foreach (var b in branches)
        {
            var devices = await _db.Devices.Where(d => d.BranchId == b.BranchId && d.IsActive).ToListAsync();
            var online = devices.Count(d => d.LastSeenAt != null && d.LastSeenAt >= cutoff);
            result.Add(new BranchDto(b.BranchId, b.FoodicsBranchId, b.Code, b.Name, b.IsActive,
                devices.Count, online, b.NameLocalized, b.OpeningFrom, b.OpeningTo));
        }
        return Ok(result);
    }

    /// <summary>Pulls this brand's branches from Foodics into SQL.</summary>
    [HttpPost("brands/{brandId:int}/sync-branches")]
    public async Task<ActionResult<BranchSyncResultDto>> Sync(int brandId, CancellationToken ct)
    {
        var brand = await _db.Brands.FindAsync(brandId);
        if (brand is null) return NotFound();
        try
        {
            return Ok(await _foodics.SyncBranchesAsync(brand, ct));
        }
        catch (Exception ex)
        {
            return StatusCode(StatusCodes.Status502BadGateway, new { error = ex.Message });
        }
    }
}

/// <summary>Shared "online" window: a tablet seen within this is considered live.</summary>
public static class DeviceStatus
{
    public static readonly TimeSpan OnlineWindow = TimeSpan.FromMinutes(3);
    public static bool IsOnline(DateTime? lastSeen) =>
        lastSeen != null && lastSeen >= DateTime.UtcNow - OnlineWindow;
}
