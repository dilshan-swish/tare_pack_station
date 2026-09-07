using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;
using SwishWeighing.Api.Services;

namespace SwishWeighing.Api.Controllers;

[ApiController]
[Route("api/brands")]
public class BrandsController : ControllerBase
{
    private readonly AppDbContext _db;
    private readonly FoodicsService _foodics;

    public BrandsController(AppDbContext db, FoodicsService foodics)
    {
        _db = db;
        _foodics = foodics;
    }

    /// <summary>All brands with weight-coverage counts (for the portal home).</summary>
    [HttpGet]
    public async Task<ActionResult<IEnumerable<BrandSummaryDto>>> List()
    {
        var brands = await _db.Brands.Where(b => b.IsActive).OrderBy(b => b.Code).ToListAsync();
        var result = new List<BrandSummaryDto>();
        foreach (var b in brands)
        {
            var total = await _db.MenuItems.CountAsync(m => m.BrandId == b.BrandId && m.IsActive);
            var missing = await _db.MenuItems.CountAsync(m =>
                m.BrandId == b.BrandId && m.IsActive && (m.MinWeightG == null || m.MaxWeightG == null));
            result.Add(new BrandSummaryDto(b.BrandId, b.Code, b.Name, b.PublishedVersion, total, missing));
        }
        return Ok(result);
    }

    /// <summary>The published config a tablet pulls: items + modifiers with weights.</summary>
    [HttpGet("{brandId:int}/config")]
    public async Task<ActionResult<BrandConfigDto>> Config(int brandId)
    {
        var brand = await _db.Brands.FindAsync(brandId);
        if (brand is null) return NotFound();

        // Not filtered to IsActive — inactive items/modifiers still need to be
        // visible (greyed out) to staff, not hidden. See DevicesController.MyConfig.
        var items = await _db.MenuItems
            .Where(m => m.BrandId == brandId).OrderBy(m => m.Name).ToListAsync();
        var mods = await _db.Modifiers
            .Where(m => m.BrandId == brandId).OrderBy(m => m.Name).ToListAsync();
        var itemMods = await ItemModifierFoodicsIdsAsync(_db, brandId);
        var combinations = await ModifierCombinationConfigsAsync(_db, brandId);

        return Ok(new BrandConfigDto(
            brand.BrandId, brand.Code, brand.Name, brand.PublishedVersion,
            items.Select(m => ToItemDto(m, itemMods)).ToList(),
            mods.Select(ToModDto).ToList(),
            MenuSyncedVersion: brand.MenuSyncedVersion, ModifierCombinations: combinations));
    }

    /// <summary>
    /// Per-item modifier links for a brand, keyed by MenuItemId, resolved to
    /// the linked options' FoodicsModifierId (what the tablet/portal key
    /// modifiers by) — the same MenuItemModifiers join FoodicsService
    /// populates during sync, already narrowed to each item's real, distinct
    /// options (not every duplicate sharing a shared Foodics modifier group).
    /// </summary>
    internal static async Task<Dictionary<int, List<string>>> ItemModifierFoodicsIdsAsync(
        AppDbContext db, int brandId, CancellationToken ct = default)
    {
        var itemIds = await db.MenuItems
            .Where(m => m.BrandId == brandId).Select(m => m.MenuItemId).ToListAsync(ct);
        var links = await db.MenuItemModifiers
            .Where(x => itemIds.Contains(x.MenuItemId)).ToListAsync(ct);
        if (links.Count == 0) return new Dictionary<int, List<string>>();

        var modifierIds = links.Select(l => l.ModifierId).Distinct().ToList();
        var foodicsIdByModifierId = await db.Modifiers
            .Where(m => modifierIds.Contains(m.ModifierId))
            .ToDictionaryAsync(m => m.ModifierId, m => m.FoodicsModifierId, ct);

        return links.GroupBy(l => l.MenuItemId).ToDictionary(
            g => g.Key,
            g => g.Select(l => foodicsIdByModifierId.GetValueOrDefault(l.ModifierId))
                .Where(id => !string.IsNullOrEmpty(id)).Select(id => id!).ToList());
    }

    /// <summary>Every configured modifier-combination override for a brand,
    /// translated to Foodics modifier ids for the tablet (see
    /// docs/sql/15_modifier_combination_weights.sql). Shared by both this
    /// controller's own /config preview and DevicesController.MyConfig so a
    /// tablet and the portal's preview always agree on exactly the same
    /// combinations.</summary>
    internal static async Task<List<ModifierCombinationConfigDto>> ModifierCombinationConfigsAsync(
        AppDbContext db, int brandId, CancellationToken ct = default)
    {
        var combos = await db.ModifierCombinationWeights.Where(c => c.BrandId == brandId).ToListAsync(ct);
        if (combos.Count == 0) return new List<ModifierCombinationConfigDto>();

        var ids = combos.SelectMany(c => c.ModifierIds).Distinct().ToList();
        var foodicsIdByModifierId = await db.Modifiers
            .Where(m => ids.Contains(m.ModifierId))
            .ToDictionaryAsync(m => m.ModifierId, m => m.FoodicsModifierId, ct);

        var result = new List<ModifierCombinationConfigDto>();
        foreach (var c in combos)
        {
            var foodicsIds = new List<string>();
            var allResolved = true;
            foreach (var mid in c.ModifierIds)
            {
                if (!foodicsIdByModifierId.TryGetValue(mid, out var fid)) { allResolved = false; break; }
                foodicsIds.Add(fid);
            }
            if (!allResolved) continue;
            var anchorFoodicsId = c.AnchorModifierId.HasValue
                ? foodicsIdByModifierId.GetValueOrDefault(c.AnchorModifierId.Value)
                : null;
            result.Add(new ModifierCombinationConfigDto(foodicsIds, anchorFoodicsId, c.WeightG, c.MinWeightG, c.MaxWeightG));
        }
        return result;
    }

    /// <summary>Bumps the published version so tablets know to re-sync.</summary>
    [HttpPost("{brandId:int}/publish")]
    public async Task<IActionResult> Publish(int brandId, [FromBody] PublishDto? body)
    {
        var brand = await _db.Brands.FindAsync(brandId);
        if (brand is null) return NotFound();

        brand.PublishedVersion += 1;
        brand.UpdatedAt = DateTime.UtcNow;
        _db.ConfigPublications.Add(new ConfigPublication
        {
            BrandId = brandId,
            Version = brand.PublishedVersion,
            PublishedBy = body?.PublishedBy,
            Notes = body?.Notes,
            PublishedAt = DateTime.UtcNow,
        });
        await _db.SaveChangesAsync();
        return Ok(new { brand.PublishedVersion });
    }

    /// <summary>Pulls this brand's menu from Foodics and upserts it into SQL.</summary>
    [HttpPost("{brandId:int}/sync-foodics")]
    public async Task<ActionResult<SyncResultDto>> SyncFoodics(int brandId, CancellationToken ct)
    {
        var brand = await _db.Brands.FindAsync(brandId);
        if (brand is null) return NotFound();
        try
        {
            var res = await _foodics.SyncBrandAsync(brand, ct);
            return Ok(res);
        }
        catch (Exception ex)
        {
            // Upstream/config problem — surface it as a readable 502, never a 500 stack.
            return StatusCode(StatusCodes.Status502BadGateway, new { error = ex.Message });
        }
    }

    // itemMods (from ItemModifierFoodicsIdsAsync) drives both HasModifiers and
    // ModifierIds from the one source of truth. Only omit it where a caller
    // never sends the DTO back to a client that might replace its whole local
    // copy of the item with it (an omission here previously made the portal's
    // own "Modifiers — show" toggle vanish right after saving an item's
    // weight, since HasModifiers/ModifierIds would silently come back
    // empty/false and overwrite what was already known client-side).
    internal static MenuItemDto ToItemDto(MenuItem m, Dictionary<int, List<string>>? itemMods = null)
    {
        var modifierIds = itemMods?.GetValueOrDefault(m.MenuItemId) ?? new List<string>();
        return new(
            m.MenuItemId, m.FoodicsProductId, m.Name, m.CategoryName,
            m.Sku, m.CategoryReference, m.IsActive, modifierIds.Count > 0, modifierIds,
            m.IdealWeightG, m.MinWeightG, m.MaxWeightG, m.PackagingWeightG, m.IsConfigured);
    }

    internal static ModifierDto ToModDto(Modifier m) => new(
        m.ModifierId, m.FoodicsModifierId, m.Name, m.ModifierGroupName,
        m.Sku, m.ModifierGroupReference, m.IsActive,
        m.WeightG, m.MinWeightG, m.MaxWeightG, m.IsConfigured);
}
