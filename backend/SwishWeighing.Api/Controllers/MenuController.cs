using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Controllers;

[ApiController]
[Route("api")]
public class MenuController : ControllerBase
{
    private readonly AppDbContext _db;
    public MenuController(AppDbContext db) => _db = db;

    /// <summary>
    /// Items for a brand. <paramref name="search"/> matches name, SKU, category
    /// name, category reference, or the raw Foodics product id — so a staff
    /// member can look an item up by whichever value the Foodics console
    /// showed them. <paramref name="active"/>: omit for all, true/false to
    /// filter. <paramref name="hasModifiers"/>: omit for all, true/false to
    /// filter items that do/don't have any linked modifier options.
    /// </summary>
    [HttpGet("brands/{brandId:int}/items")]
    public async Task<ActionResult<IEnumerable<MenuItemDto>>> Items(
        int brandId, [FromQuery] string? search, [FromQuery] bool? missingOnly,
        [FromQuery] bool? active, [FromQuery] bool? hasModifiers)
    {
        var q = _db.MenuItems.Where(m => m.BrandId == brandId);
        if (active.HasValue)
            q = q.Where(m => m.IsActive == active.Value);
        if (missingOnly == true)
            q = q.Where(m => m.MinWeightG == null || m.MaxWeightG == null);
        if (!string.IsNullOrWhiteSpace(search))
        {
            var s = search.Trim();
            q = q.Where(m => m.Name.Contains(s) || m.FoodicsProductId.Contains(s) ||
                (m.Sku != null && m.Sku.Contains(s)) ||
                (m.CategoryName != null && m.CategoryName.Contains(s)) ||
                (m.CategoryReference != null && m.CategoryReference.Contains(s)));
        }
        var items = await q.OrderBy(m => m.Name).ToListAsync();

        var itemMods = await BrandsController.ItemModifierFoodicsIdsAsync(_db, brandId);
        if (hasModifiers.HasValue)
            items = items.Where(i => itemMods.ContainsKey(i.MenuItemId) == hasModifiers.Value).ToList();

        return Ok(items.Select(m => BrandsController.ToItemDto(m, itemMods)));
    }

    /// <summary>The modifier groups linked to an item, with each group's weighable options.</summary>
    [HttpGet("items/{id:int}/modifiers")]
    public async Task<ActionResult<IEnumerable<ItemModifierGroupDto>>> ItemModifiers(int id)
    {
        var item = await _db.MenuItems.FindAsync(id);
        if (item is null) return NotFound();

        var modifierIds = await _db.MenuItemModifiers
            .Where(x => x.MenuItemId == id).Select(x => x.ModifierId).ToListAsync();
        var options = await _db.Modifiers.Where(m => modifierIds.Contains(m.ModifierId)).ToListAsync();

        var groups = options
            .GroupBy(o => o.FoodicsModifierGroupId ?? "")
            .Select(g => new ItemModifierGroupDto(
                g.Key,
                g.First().ModifierGroupName,
                g.First().ModifierGroupReference,
                g.OrderBy(o => o.Name).Select(BrandsController.ToModDto).ToList()))
            .OrderBy(g => g.GroupName)
            .ToList();

        return Ok(groups);
    }

    /// <summary>Sets an item's Min/Max (+ packaging) weight.</summary>
    [HttpPut("items/{id:int}/weight")]
    public async Task<ActionResult<MenuItemDto>> UpdateItem(int id, [FromBody] ItemWeightUpdateDto body)
    {
        var item = await _db.MenuItems.FindAsync(id);
        if (item is null) return NotFound();

        var error = ValidateItemWeights(body.IdealWeightG, body.MinWeightG, body.MaxWeightG, body.PackagingWeightG);
        if (error != null) return BadRequest(new { error });

        item.IdealWeightG = body.IdealWeightG;
        item.MinWeightG = body.MinWeightG;
        item.MaxWeightG = body.MaxWeightG;
        item.PackagingWeightG = body.PackagingWeightG;
        item.UpdatedBy = body.UpdatedBy;
        item.UpdatedAt = DateTime.UtcNow;
        await _db.SaveChangesAsync();

        // Must include the item's real modifier links here — the portal
        // replaces its whole local copy of this item with this response, so
        // omitting them (as a stale comment on ToItemDto once assumed was
        // "irrelevant" for this endpoint) silently wiped out `hasModifiers`
        // and made the "Modifiers — show" toggle disappear after every save.
        var itemMods = await BrandsController.ItemModifierFoodicsIdsAsync(_db, item.BrandId);
        return Ok(BrandsController.ToItemDto(item, itemMods));
    }

    /// <summary>
    /// Modifiers for a brand. <paramref name="search"/> matches name, option
    /// SKU, group name, group reference (e.g. "modbb-81"), or the raw Foodics
    /// option id. <paramref name="active"/>: omit for all, true/false to filter.
    /// </summary>
    [HttpGet("brands/{brandId:int}/modifiers")]
    public async Task<ActionResult<IEnumerable<ModifierDto>>> Modifiers(
        int brandId, [FromQuery] string? search, [FromQuery] bool? active)
    {
        var q = _db.Modifiers.Where(m => m.BrandId == brandId);
        if (active.HasValue)
            q = q.Where(m => m.IsActive == active.Value);
        if (!string.IsNullOrWhiteSpace(search))
        {
            var s = search.Trim();
            q = q.Where(m => m.Name.Contains(s) || m.FoodicsModifierId.Contains(s) ||
                (m.Sku != null && m.Sku.Contains(s)) ||
                (m.ModifierGroupName != null && m.ModifierGroupName.Contains(s)) ||
                (m.ModifierGroupReference != null && m.ModifierGroupReference.Contains(s)));
        }
        var mods = await q.OrderBy(m => m.Name).ToListAsync();
        return Ok(mods.Select(BrandsController.ToModDto));
    }

    /// <summary>Sets a modifier's weight (+ optional measured Min/Max range).</summary>
    [HttpPut("modifiers/{id:int}/weight")]
    public async Task<ActionResult<ModifierDto>> UpdateModifier(int id, [FromBody] ModifierWeightUpdateDto body)
    {
        var mod = await _db.Modifiers.FindAsync(id);
        if (mod is null) return NotFound();

        var error = ValidateModifierWeights(body.WeightG, body.MinWeightG, body.MaxWeightG);
        if (error != null) return BadRequest(new { error });

        mod.WeightG = body.WeightG;
        mod.MinWeightG = body.MinWeightG;
        mod.MaxWeightG = body.MaxWeightG;
        mod.UpdatedBy = body.UpdatedBy;
        mod.UpdatedAt = DateTime.UtcNow;
        await _db.SaveChangesAsync();
        return Ok(BrandsController.ToModDto(mod));
    }

    /// <summary>
    /// Applies one weight to every active modifier in a brand that shares the
    /// exact same name — Foodics often splits one real physical item (e.g. a
    /// bottle of "Arwa Water") into many separate catalog rows, one per
    /// deal/combo it's linked to. This lets head office weigh it once instead
    /// of once per row, while every row stays individually editable afterward
    /// via <see cref="UpdateModifier"/> for the (rarer) case where a
    /// same-named entry is genuinely a different size/weight.
    /// </summary>
    [HttpPut("brands/{brandId:int}/modifiers/bulk-weight")]
    public async Task<ActionResult<BulkModifierUpdateResultDto>> BulkUpdateModifiers(
        int brandId, [FromBody] BulkModifierWeightUpdateDto body)
    {
        if (string.IsNullOrWhiteSpace(body.Name))
            return BadRequest(new { error = "Name is required." });

        var error = ValidateModifierWeights(body.WeightG, body.MinWeightG, body.MaxWeightG);
        if (error != null) return BadRequest(new { error });

        var name = body.Name.Trim();
        // SQL Server's default collation is case-INSENSITIVE, so the `==`
        // below (a coarse, index-friendly pre-filter) would otherwise also
        // match a differently-cased, textually-similar name — e.g. bulk-
        // applying to the "CHILLI LIME" group would silently also overwrite
        // a separate "Chilli Lime" group's weights, even though the portal
        // groups/displays them as two distinct, unrelated variant sets by
        // exact (case-sensitive) name. The ordinal filter after enforces
        // that same exactness so only the group the user actually clicked
        // "Apply to all" on is ever touched.
        //
        // Deliberately NOT filtered to IsActive: UpdateModifier (single-
        // variant edit, below) never discriminates on it either, and the
        // portal's "Apply to all N" button counts every variant it shows —
        // active and inactive alike (see WeightsPage's default "Active +
        // inactive" filter). Filtering here would silently leave inactive
        // variants at their old weight while the button claimed to have
        // updated all N of them.
        var mods = (await _db.Modifiers
            .Where(m => m.BrandId == brandId && m.Name == name)
            .ToListAsync())
            .Where(m => string.Equals(m.Name, name, StringComparison.Ordinal))
            .ToList();
        if (mods.Count == 0)
            return NotFound(new { error = $"No modifiers named \"{name}\" for this brand." });

        foreach (var m in mods)
        {
            m.WeightG = body.WeightG;
            m.MinWeightG = body.MinWeightG;
            m.MaxWeightG = body.MaxWeightG;
            m.UpdatedBy = body.UpdatedBy;
            m.UpdatedAt = DateTime.UtcNow;
        }
        await _db.SaveChangesAsync();
        return Ok(new BulkModifierUpdateResultDto(mods.Count, mods.Select(BrandsController.ToModDto).ToList()));
    }

    /// <summary>Shared by UpdateItem and the Excel importer so both enforce
    /// exactly the same rules, with no risk of the two drifting apart.</summary>
    internal static string? ValidateItemWeights(
        decimal? ideal, decimal? min, decimal? max, decimal? packaging)
    {
        if (ideal is < 0 || min is < 0 || max is < 0 || packaging is < 0)
            return "Weights cannot be negative.";
        if (min.HasValue && max.HasValue && max < min)
            return "Max weight must be greater than or equal to min weight.";
        if (ideal.HasValue &&
            ((min.HasValue && ideal < min) || (max.HasValue && ideal > max)))
            return "Ideal weight must fall between min and max.";
        return null;
    }

    // Unlike an item, a modifier's weight may be negative — e.g. "No Onion" or
    // "No Cheese" represents weight REMOVED from the base item's ideal weight,
    // not added. So no non-negative check here (deliberately, unlike
    // ItemWeightUpdateDto's validation in UpdateItem above).
    internal static string? ValidateModifierWeights(decimal? weight, decimal? min, decimal? max)
    {
        if (min.HasValue && max.HasValue && max < min)
            return "Max weight must be greater than or equal to min weight.";
        if (weight.HasValue && ((min.HasValue && weight < min) || (max.HasValue && weight > max)))
            return "Ideal weight must fall between min and max.";
        return null;
    }

    // -------------------------------------------------------------------
    // Modifier COMBINATION weights — see docs/sql/15_modifier_combination_weights.sql.
    // 2-4 modifiers selected together on the same order line whose combined
    // weight genuinely isn't the sum of each one's own (e.g. a combo-size
    // choice affecting both the fries-type AND drink-type portions at once —
    // a real 3-way interaction a 2-only design couldn't represent). A
    // combination with no row here just falls back to plain addition — this
    // is an exception list.
    // -------------------------------------------------------------------

    /// <summary>All configured combination overrides for a brand (used by the
    /// portal's list view and by the Excel export).</summary>
    [HttpGet("brands/{brandId:int}/modifier-combinations")]
    public async Task<ActionResult<IEnumerable<ModifierCombinationDto>>> BrandModifierCombinations(int brandId)
    {
        var combos = await _db.ModifierCombinationWeights.Where(c => c.BrandId == brandId).ToListAsync();
        if (combos.Count == 0) return Ok(Array.Empty<ModifierCombinationDto>());

        var ids = combos.SelectMany(c => c.ModifierIds).Distinct().ToList();
        var names = await _db.Modifiers.Where(m => ids.Contains(m.ModifierId))
            .ToDictionaryAsync(m => m.ModifierId, m => m.Name);

        return Ok(combos.OrderBy(c => c.ModifierIdsKey).Select(ToComboDto));

        ModifierCombinationDto ToComboDto(ModifierCombinationWeight c)
        {
            var memberIds = c.ModifierIds.ToList();
            return new ModifierCombinationDto(c.CombinationId, memberIds,
                memberIds.Select(id => names.GetValueOrDefault(id, "?")).ToList(),
                c.AnchorModifierId, c.WeightG, c.MinWeightG, c.MaxWeightG, c.UpdatedAt, c.UpdatedBy);
        }
    }

    /// <summary>Creates or updates one combination override (2-4 modifiers). The
    /// ids may be given in any order — canonicalized (sorted ascending) before
    /// storing, so the same real-world combination is never duplicated as two
    /// rows.</summary>
    [HttpPut("modifier-combinations")]
    public async Task<ActionResult<ModifierCombinationDto>> UpsertModifierCombination(
        [FromBody] ModifierCombinationUpdateDto body)
    {
        (int Id1, int Id2, int? Id3, int? Id4, string Key) key;
        try
        {
            key = ModifierCombinationKey.Canonicalize(body.ModifierIds);
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new { error = ex.Message });
        }

        var memberIds = new[] { key.Id1, key.Id2, key.Id3, key.Id4 }.Where(x => x.HasValue).Select(x => x!.Value).ToList();
        var mods = await _db.Modifiers.Where(m => memberIds.Contains(m.ModifierId)).ToListAsync();
        if (mods.Count != memberIds.Count) return NotFound(new { error = "One or more modifiers were not found." });
        if (mods.Select(m => m.BrandId).Distinct().Count() != 1)
            return BadRequest(new { error = "All modifiers in a combination must belong to the same brand." });

        if (body.AnchorModifierId.HasValue)
        {
            if (memberIds.Count != 2)
                return BadRequest(new { error = "An anchor (\"depends on\") modifier can only be set for a two-modifier combination." });
            if (!memberIds.Contains(body.AnchorModifierId.Value))
                return BadRequest(new { error = "The anchor modifier must be one of the two modifiers in the combination." });
        }

        var error = ValidateModifierWeights(body.WeightG, body.MinWeightG, body.MaxWeightG);
        if (error != null) return BadRequest(new { error });

        var combo = await _db.ModifierCombinationWeights
            .FirstOrDefaultAsync(c => c.BrandId == mods[0].BrandId && c.ModifierIdsKey == key.Key);
        if (combo is null)
        {
            combo = new ModifierCombinationWeight
            {
                BrandId = mods[0].BrandId,
                ModifierId1 = key.Id1, ModifierId2 = key.Id2, ModifierId3 = key.Id3, ModifierId4 = key.Id4,
                ModifierIdsKey = key.Key,
            };
            _db.ModifierCombinationWeights.Add(combo);
        }
        combo.AnchorModifierId = body.AnchorModifierId;
        combo.WeightG = body.WeightG;
        combo.MinWeightG = body.MinWeightG;
        combo.MaxWeightG = body.MaxWeightG;
        combo.UpdatedBy = body.UpdatedBy;
        combo.UpdatedAt = DateTime.UtcNow;
        await _db.SaveChangesAsync();

        var namesById = mods.ToDictionary(m => m.ModifierId, m => m.Name);
        return Ok(new ModifierCombinationDto(combo.CombinationId, memberIds,
            memberIds.Select(id => namesById[id]).ToList(),
            combo.AnchorModifierId, combo.WeightG, combo.MinWeightG, combo.MaxWeightG, combo.UpdatedAt, combo.UpdatedBy));
    }

    /// <summary>Removes a combination override — that set of modifiers falls back
    /// to plain item+modifier addition again.</summary>
    [HttpDelete("modifier-combinations/{combinationId:int}")]
    public async Task<IActionResult> DeleteModifierCombination(int combinationId)
    {
        var combo = await _db.ModifierCombinationWeights.FindAsync(combinationId);
        if (combo is null) return NotFound();
        _db.ModifierCombinationWeights.Remove(combo);
        await _db.SaveChangesAsync();
        return NoContent();
    }
}
