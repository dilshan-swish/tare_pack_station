using ClosedXML.Excel;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Controllers;

/// <summary>
/// Export a brand's full menu (items, modifiers, modifier-pair overrides) to
/// an Excel workbook for offline editing, and import one back — strictly, in
/// exactly the format exported. Every row is matched by its internal numeric
/// id, never by name — names are shown for a human to read, but editing a
/// name column has no effect on import; this is deliberate, learned directly
/// from the BBT weight-sheet reconciliation, where matching by name turned
/// out to be unreliable (see docs/BBT_WEIGHT_RECONCILIATION.md).
///
/// Import validates the ENTIRE file first — every row, every sheet — before
/// writing anything. If any row fails, NOTHING is applied; the response
/// lists every problem so the whole file can be fixed and re-uploaded in one
/// pass, rather than partially applying and leaving the catalog in a mixed
/// old/new state.
/// </summary>
[ApiController]
[Route("api")]
public class MenuImportExportController : ControllerBase
{
    private readonly AppDbContext _db;
    public MenuImportExportController(AppDbContext db) => _db = db;

    private const string ItemsSheet = "Items";
    private const string ModifiersSheet = "Modifiers";
    private const string CombinationsSheet = "ModifierCombinations";

    [HttpGet("brands/{brandId:int}/menu-export.xlsx")]
    public async Task<IActionResult> Export(int brandId)
    {
        var brand = await _db.Brands.FindAsync(brandId);
        if (brand is null) return NotFound();

        var items = await _db.MenuItems.Where(m => m.BrandId == brandId).OrderBy(m => m.Name).ToListAsync();
        var mods = await _db.Modifiers.Where(m => m.BrandId == brandId).OrderBy(m => m.Name).ToListAsync();
        var modById = mods.ToDictionary(m => m.ModifierId);
        var combos = await _db.ModifierCombinationWeights.Where(c => c.BrandId == brandId)
            .OrderBy(c => c.ModifierIdsKey).ToListAsync();

        using var wb = new XLWorkbook();

        var wsItems = wb.Worksheets.Add(ItemsSheet);
        string[] itemHeaders =
            ["MenuItemId", "FoodicsProductId", "Name", "Category", "Active",
             "IdealWeightG", "MinWeightG", "MaxWeightG", "PackagingWeightG"];
        for (var i = 0; i < itemHeaders.Length; i++) wsItems.Cell(1, i + 1).Value = itemHeaders[i];
        var r = 2;
        foreach (var it in items)
        {
            wsItems.Cell(r, 1).Value = it.MenuItemId;
            wsItems.Cell(r, 2).Value = it.FoodicsProductId;
            wsItems.Cell(r, 3).Value = it.Name;
            wsItems.Cell(r, 4).Value = it.CategoryName ?? "";
            wsItems.Cell(r, 5).Value = it.IsActive ? "Yes" : "No";
            if (it.IdealWeightG.HasValue) wsItems.Cell(r, 6).Value = it.IdealWeightG.Value;
            if (it.MinWeightG.HasValue) wsItems.Cell(r, 7).Value = it.MinWeightG.Value;
            if (it.MaxWeightG.HasValue) wsItems.Cell(r, 8).Value = it.MaxWeightG.Value;
            if (it.PackagingWeightG.HasValue) wsItems.Cell(r, 9).Value = it.PackagingWeightG.Value;
            r++;
        }
        FormatSheet(wsItems, itemHeaders.Length);

        var wsMods = wb.Worksheets.Add(ModifiersSheet);
        string[] modHeaders =
            ["ModifierId", "FoodicsModifierId", "GroupName", "Name", "Active",
             "WeightG", "MinWeightG", "MaxWeightG"];
        for (var i = 0; i < modHeaders.Length; i++) wsMods.Cell(1, i + 1).Value = modHeaders[i];
        r = 2;
        foreach (var m in mods)
        {
            wsMods.Cell(r, 1).Value = m.ModifierId;
            wsMods.Cell(r, 2).Value = m.FoodicsModifierId;
            wsMods.Cell(r, 3).Value = m.ModifierGroupName ?? "";
            wsMods.Cell(r, 4).Value = m.Name;
            wsMods.Cell(r, 5).Value = m.IsActive ? "Yes" : "No";
            if (m.WeightG.HasValue) wsMods.Cell(r, 6).Value = m.WeightG.Value;
            if (m.MinWeightG.HasValue) wsMods.Cell(r, 7).Value = m.MinWeightG.Value;
            if (m.MaxWeightG.HasValue) wsMods.Cell(r, 8).Value = m.MaxWeightG.Value;
            r++;
        }
        FormatSheet(wsMods, modHeaders.Length);

        var wsCombos = wb.Worksheets.Add(CombinationsSheet);
        string[] comboHeaders =
            ["CombinationId",
             "ModifierId1", "ModifierName1", "ModifierId2", "ModifierName2",
             "ModifierId3", "ModifierName3", "ModifierId4", "ModifierName4",
             "AnchorModifierId", "AnchorModifierName",
             "WeightG", "MinWeightG", "MaxWeightG"];
        for (var i = 0; i < comboHeaders.Length; i++) wsCombos.Cell(1, i + 1).Value = comboHeaders[i];
        r = 2;
        foreach (var c in combos)
        {
            wsCombos.Cell(r, 1).Value = c.CombinationId;
            wsCombos.Cell(r, 2).Value = c.ModifierId1;
            wsCombos.Cell(r, 3).Value = modById.GetValueOrDefault(c.ModifierId1)?.Name ?? "?";
            wsCombos.Cell(r, 4).Value = c.ModifierId2;
            wsCombos.Cell(r, 5).Value = modById.GetValueOrDefault(c.ModifierId2)?.Name ?? "?";
            if (c.ModifierId3.HasValue)
            {
                wsCombos.Cell(r, 6).Value = c.ModifierId3.Value;
                wsCombos.Cell(r, 7).Value = modById.GetValueOrDefault(c.ModifierId3.Value)?.Name ?? "?";
            }
            if (c.ModifierId4.HasValue)
            {
                wsCombos.Cell(r, 8).Value = c.ModifierId4.Value;
                wsCombos.Cell(r, 9).Value = modById.GetValueOrDefault(c.ModifierId4.Value)?.Name ?? "?";
            }
            if (c.AnchorModifierId.HasValue)
            {
                wsCombos.Cell(r, 10).Value = c.AnchorModifierId.Value;
                wsCombos.Cell(r, 11).Value = modById.GetValueOrDefault(c.AnchorModifierId.Value)?.Name ?? "?";
            }
            wsCombos.Cell(r, 12).Value = c.WeightG;
            if (c.MinWeightG.HasValue) wsCombos.Cell(r, 13).Value = c.MinWeightG.Value;
            if (c.MaxWeightG.HasValue) wsCombos.Cell(r, 14).Value = c.MaxWeightG.Value;
            r++;
        }
        FormatSheet(wsCombos, comboHeaders.Length);

        var wsHelp = wb.Worksheets.Add("Instructions");
        var help = new[]
        {
            "How to use this file",
            "",
            "1. Every row is matched back to the database by its ID column",
            "   (MenuItemId / ModifierId / CombinationId) — NEVER by name. Editing a",
            "   Name/Category/GroupName column is fine for your own reading;",
            "   it has no effect on import. Do not change any ID column.",
            "",
            "2. Leave a weight cell blank to clear that value (mark it as not",
            "   configured). Do not type 0 unless the real weight is 0.",
            "",
            "3. ModifierCombinations sheet: this is for 2-4 modifiers that must",
            "   be selected TOGETHER for a combined weight that differs from",
            "   simply adding each one's own weight — e.g. a fries-type choice",
            "   paired with a combo-size choice. To add a NEW combination, add a",
            "   new row with ModifierId1 and ModifierId2 filled in (required),",
            "   plus ModifierId3 and/or ModifierId4 if a third/fourth modifier",
            "   is also part of it (look up ids on the Modifiers sheet) — leave",
            "   CombinationId blank. To remove an existing combination override,",
            "   leave its WeightG cell blank. Unlike a plain item or modifier,",
            "   WeightG here can't be blank while MinWeightG/MaxWeightG are",
            "   filled in — a combination row always needs its own ideal weight.",
            "",
            "   AnchorModifierId (optional, two-modifier rows only): the id of",
            "   whichever of ModifierId1/2 is \"context only\", e.g. a combo-size",
            "   choice — its own weight stays untouched and WeightG replaces",
            "   only the OTHER modifier's own weight instead. This lets the same",
            "   anchor (e.g. \"Medium\") be combined with several different",
            "   dependent modifiers (fries, then separately drinks) across",
            "   several rows without them conflicting. Leave blank for the older",
            "   behavior, where WeightG replaces the sum of both modifiers.",
            "",
            "4. Do not rename, delete, or add sheets. The import only accepts",
            "   a file with exactly these sheets: Items, Modifiers, ModifierCombinations",
            "   (this Instructions sheet is ignored either way).",
            "",
            "5. The whole file is validated before anything is applied — if",
            "   any row has a problem, NONE of the file is applied, and you'll",
            "   get a full list of every row that needs fixing.",
        };
        for (var i = 0; i < help.Length; i++) wsHelp.Cell(i + 1, 1).Value = help[i];
        wsHelp.Column(1).Width = 90;
        wsHelp.Cell(1, 1).Style.Font.Bold = true;

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        var fileName = $"{brand.Code}-menu-{DateTime.UtcNow:yyyyMMdd-HHmm}.xlsx";
        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
    }

    private static void FormatSheet(IXLWorksheet ws, int columnCount)
    {
        ws.Row(1).Style.Font.Bold = true;
        ws.SheetView.FreezeRows(1);
        ws.Columns(1, columnCount).AdjustToContents();
    }

    [HttpPost("brands/{brandId:int}/menu-import")]
    [RequestSizeLimit(20_000_000)]
    public async Task<ActionResult<MenuImportResultDto>> Import(int brandId, IFormFile file)
    {
        var brand = await _db.Brands.FindAsync(brandId);
        if (brand is null) return NotFound();
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "No file uploaded." });

        XLWorkbook wb;
        try
        {
            using var stream = file.OpenReadStream();
            wb = new XLWorkbook(stream);
        }
        catch (Exception ex)
        {
            return BadRequest(new
            {
                error = "Could not read this file as an Excel workbook (.xlsx). " +
                    "Make sure you're uploading the exported file, unmodified in structure. " +
                    $"Detail: {ex.Message}",
            });
        }
        using (wb)
        {
            var sheetNames = wb.Worksheets.Select(w => w.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var missing = new[] { ItemsSheet, ModifiersSheet, CombinationsSheet }
                .Where(s => !sheetNames.Contains(s)).ToList();
            if (missing.Count > 0)
                return BadRequest(new
                {
                    error = $"This file is missing required sheet(s): {string.Join(", ", missing)}. " +
                        "Only a file exported from this brand's \"Export menu\" — unmodified in " +
                        "structure — is accepted.",
                });

            var errors = new List<MenuImportRowError>();

            // ---- Items ----
            var existingItems = await _db.MenuItems.Where(m => m.BrandId == brandId).ToDictionaryAsync(m => m.MenuItemId);
            var itemUpdates = new List<(MenuItem Item, decimal? Ideal, decimal? Min, decimal? Max, decimal? Packaging)>();
            {
                var ws = wb.Worksheet(ItemsSheet);
                var cols = HeaderMap(ws, ["MenuItemId", "IdealWeightG", "MinWeightG", "MaxWeightG", "PackagingWeightG"], ItemsSheet, errors);
                if (cols != null)
                    foreach (var row in DataRows(ws))
                    {
                        var rowNum = row.RowNumber();
                        if (!TryReadInt(row, cols["MenuItemId"], out var itemId))
                        { errors.Add(new(ItemsSheet, rowNum, "MenuItemId is required and must be a whole number.")); continue; }
                        if (!existingItems.TryGetValue(itemId, out var item))
                        { errors.Add(new(ItemsSheet, rowNum, $"MenuItemId {itemId} does not belong to this brand (or was removed).")); continue; }
                        if (!TryReadDecimal(row, cols["IdealWeightG"], rowNum, ItemsSheet, "IdealWeightG", errors, out var ideal)) continue;
                        if (!TryReadDecimal(row, cols["MinWeightG"], rowNum, ItemsSheet, "MinWeightG", errors, out var min)) continue;
                        if (!TryReadDecimal(row, cols["MaxWeightG"], rowNum, ItemsSheet, "MaxWeightG", errors, out var max)) continue;
                        if (!TryReadDecimal(row, cols["PackagingWeightG"], rowNum, ItemsSheet, "PackagingWeightG", errors, out var packaging)) continue;
                        var itemErr = MenuController.ValidateItemWeights(ideal, min, max, packaging);
                        if (itemErr != null) { errors.Add(new(ItemsSheet, rowNum, itemErr)); continue; }
                        // Skip rows that would write back exactly what's already there —
                        // otherwise re-importing an unmodified export bumps UpdatedAt/
                        // UpdatedBy on every single item, and the result's "updated"
                        // count stops meaning "actually changed".
                        if (item.IdealWeightG == ideal && item.MinWeightG == min &&
                            item.MaxWeightG == max && item.PackagingWeightG == packaging)
                            continue;
                        itemUpdates.Add((item, ideal, min, max, packaging));
                    }
            }

            // ---- Modifiers ----
            var existingMods = await _db.Modifiers.Where(m => m.BrandId == brandId).ToDictionaryAsync(m => m.ModifierId);
            var modUpdates = new List<(Modifier Mod, decimal? Weight, decimal? Min, decimal? Max)>();
            {
                var ws = wb.Worksheet(ModifiersSheet);
                var cols = HeaderMap(ws, ["ModifierId", "WeightG", "MinWeightG", "MaxWeightG"], ModifiersSheet, errors);
                if (cols != null)
                    foreach (var row in DataRows(ws))
                    {
                        var rowNum = row.RowNumber();
                        if (!TryReadInt(row, cols["ModifierId"], out var modId))
                        { errors.Add(new(ModifiersSheet, rowNum, "ModifierId is required and must be a whole number.")); continue; }
                        if (!existingMods.TryGetValue(modId, out var mod))
                        { errors.Add(new(ModifiersSheet, rowNum, $"ModifierId {modId} does not belong to this brand (or was removed).")); continue; }
                        if (!TryReadDecimal(row, cols["WeightG"], rowNum, ModifiersSheet, "WeightG", errors, out var weight)) continue;
                        if (!TryReadDecimal(row, cols["MinWeightG"], rowNum, ModifiersSheet, "MinWeightG", errors, out var min)) continue;
                        if (!TryReadDecimal(row, cols["MaxWeightG"], rowNum, ModifiersSheet, "MaxWeightG", errors, out var max)) continue;
                        var modErr = MenuController.ValidateModifierWeights(weight, min, max);
                        if (modErr != null) { errors.Add(new(ModifiersSheet, rowNum, modErr)); continue; }
                        // Same "skip if unchanged" reasoning as the Items sheet above.
                        if (mod.WeightG == weight && mod.MinWeightG == min && mod.MaxWeightG == max)
                            continue;
                        modUpdates.Add((mod, weight, min, max));
                    }
            }

            // ---- ModifierCombinations (2-4 modifier ids per row) ----
            var existingCombos = await _db.ModifierCombinationWeights.Where(c => c.BrandId == brandId)
                .ToDictionaryAsync(c => c.ModifierIdsKey);
            var comboUpserts = new List<(string Key, List<int> Ids, int? AnchorId, decimal Weight, decimal? Min, decimal? Max)>();
            var comboRemovals = new List<string>();
            {
                var ws = wb.Worksheet(CombinationsSheet);
                var cols = HeaderMap(ws, ["ModifierId1", "ModifierId2", "WeightG", "MinWeightG", "MaxWeightG"], CombinationsSheet, errors);
                // ModifierId3/4/AnchorModifierId are optional columns — look
                // them up directly (not via HeaderMap, which would add a
                // spurious error if absent).
                var headerNames = ws.Row(1).CellsUsed()
                    .ToDictionary(c => c.GetString().Trim(), c => c.Address.ColumnNumber, StringComparer.OrdinalIgnoreCase);
                var col3 = headerNames.GetValueOrDefault("ModifierId3");
                var col4 = headerNames.GetValueOrDefault("ModifierId4");
                var colAnchor = headerNames.GetValueOrDefault("AnchorModifierId");
                if (cols != null)
                    foreach (var row in DataRows(ws))
                    {
                        var rowNum = row.RowNumber();
                        if (!TryReadInt(row, cols["ModifierId1"], out var id1) ||
                            !TryReadInt(row, cols["ModifierId2"], out var id2))
                        { errors.Add(new(CombinationsSheet, rowNum, "ModifierId1 and ModifierId2 are required and must be whole numbers.")); continue; }

                        var ids = new List<int> { id1, id2 };
                        var id3Present = col3 > 0 && CellHasValue(row, col3);
                        var id4Present = col4 > 0 && CellHasValue(row, col4);
                        if (id4Present && !id3Present)
                        { errors.Add(new(CombinationsSheet, rowNum, "ModifierId4 is set but ModifierId3 is blank — fill in ModifierId3 first.")); continue; }
                        if (id3Present)
                        {
                            if (!TryReadInt(row, col3, out var v3))
                            { errors.Add(new(CombinationsSheet, rowNum, "ModifierId3 must be a whole number, or blank.")); continue; }
                            ids.Add(v3);
                        }
                        if (id4Present)
                        {
                            if (!TryReadInt(row, col4, out var v4))
                            { errors.Add(new(CombinationsSheet, rowNum, "ModifierId4 must be a whole number, or blank.")); continue; }
                            ids.Add(v4);
                        }

                        int? anchorId = null;
                        var anchorPresent = colAnchor > 0 && CellHasValue(row, colAnchor);
                        if (anchorPresent)
                        {
                            if (!TryReadInt(row, colAnchor, out var va))
                            { errors.Add(new(CombinationsSheet, rowNum, "AnchorModifierId must be a whole number, or blank.")); continue; }
                            if (ids.Count != 2)
                            { errors.Add(new(CombinationsSheet, rowNum, "AnchorModifierId can only be set for a two-modifier row (leave ModifierId3/4 blank).")); continue; }
                            if (!ids.Contains(va))
                            { errors.Add(new(CombinationsSheet, rowNum, "AnchorModifierId must match ModifierId1 or ModifierId2 on this row.")); continue; }
                            anchorId = va;
                        }

                        (int Id1, int Id2, int? Id3, int? Id4, string Key) key;
                        try { key = ModifierCombinationKey.Canonicalize(ids); }
                        catch (ArgumentException ex) { errors.Add(new(CombinationsSheet, rowNum, ex.Message)); continue; }

                        var missingIds = ids.Where(mid => !existingMods.ContainsKey(mid)).ToList();
                        if (missingIds.Count > 0)
                        { errors.Add(new(CombinationsSheet, rowNum, $"ModifierId {string.Join(", ", missingIds)} does not belong to this brand (or was removed).")); continue; }

                        if (!TryReadDecimal(row, cols["MinWeightG"], rowNum, CombinationsSheet, "MinWeightG", errors, out var min)) continue;
                        if (!TryReadDecimal(row, cols["MaxWeightG"], rowNum, CombinationsSheet, "MaxWeightG", errors, out var max)) continue;
                        var weightCell = row.Cell(cols["WeightG"]);
                        if (weightCell.IsEmpty() || string.IsNullOrWhiteSpace(weightCell.GetString()))
                        {
                            // Unlike a plain modifier or item, a combination's WeightG is
                            // never nullable in the database — Min/Max without it isn't
                            // "leave weight unconfigured for now", it's a row we can't
                            // save at all. Catch it here with a clear message instead of
                            // either silently dropping the typed range (no existing combo
                            // to remove) or silently deleting an existing override along
                            // with whatever range was typed alongside the blank weight.
                            if (min is not null || max is not null)
                            { errors.Add(new(CombinationsSheet, rowNum, "MinWeightG/MaxWeightG are set but WeightG is blank — set an ideal weight too, or clear Min/Max as well.")); continue; }
                            if (existingCombos.ContainsKey(key.Key)) comboRemovals.Add(key.Key);
                            continue; // blank weight + no existing combination = nothing to do
                        }
                        if (!TryReadDecimal(row, cols["WeightG"], rowNum, CombinationsSheet, "WeightG", errors, out var weight) || weight is null)
                        { errors.Add(new(CombinationsSheet, rowNum, "WeightG must be a number, or blank to remove the combination.")); continue; }
                        var comboErr = MenuController.ValidateModifierWeights(weight, min, max);
                        if (comboErr != null) { errors.Add(new(CombinationsSheet, rowNum, comboErr)); continue; }
                        // Same "skip if unchanged" reasoning as Items/Modifiers above —
                        // a brand-new combination (no existing row) always counts as a
                        // real change.
                        if (existingCombos.TryGetValue(key.Key, out var existingCombo) &&
                            existingCombo.WeightG == weight.Value && existingCombo.MinWeightG == min &&
                            existingCombo.MaxWeightG == max && existingCombo.AnchorModifierId == anchorId)
                            continue;
                        comboUpserts.Add((key.Key, ids, anchorId, weight.Value, min, max));
                    }
            }

            if (errors.Count > 0)
                return Ok(new MenuImportResultDto(false, 0, 0, 0, 0, errors));

            // ---- Everything validated — apply atomically ----
            await using var tx = await _db.Database.BeginTransactionAsync();
            var now = DateTime.UtcNow;
            foreach (var (item, ideal, min, max, packaging) in itemUpdates)
            {
                item.IdealWeightG = ideal;
                item.MinWeightG = min;
                item.MaxWeightG = max;
                item.PackagingWeightG = packaging;
                item.UpdatedAt = now;
            }
            foreach (var (mod, weight, min, max) in modUpdates)
            {
                mod.WeightG = weight;
                mod.MinWeightG = min;
                mod.MaxWeightG = max;
                mod.UpdatedAt = now;
            }
            foreach (var key in comboRemovals)
                _db.ModifierCombinationWeights.Remove(existingCombos[key]);
            foreach (var (key, ids, anchorId, weight, min, max) in comboUpserts)
            {
                if (existingCombos.TryGetValue(key, out var combo))
                {
                    combo.AnchorModifierId = anchorId;
                    combo.WeightG = weight;
                    combo.MinWeightG = min;
                    combo.MaxWeightG = max;
                    combo.UpdatedAt = now;
                }
                else
                {
                    var (id1, id2, id3, id4, _) = ModifierCombinationKey.Canonicalize(ids);
                    _db.ModifierCombinationWeights.Add(new ModifierCombinationWeight
                    {
                        BrandId = brandId,
                        ModifierId1 = id1, ModifierId2 = id2, ModifierId3 = id3, ModifierId4 = id4,
                        ModifierIdsKey = key, AnchorModifierId = anchorId,
                        WeightG = weight, MinWeightG = min, MaxWeightG = max, UpdatedAt = now,
                    });
                }
            }
            await _db.SaveChangesAsync();
            await tx.CommitAsync();

            return Ok(new MenuImportResultDto(true, itemUpdates.Count, modUpdates.Count,
                comboUpserts.Count, comboRemovals.Count, Array.Empty<MenuImportRowError>()));
        }
    }

    /// <summary>Maps each required header name (case-insensitive) to its column
    /// number by reading row 1. Adds a sheet-level error and returns null if any
    /// required header is missing — the caller then skips that sheet's rows
    /// entirely (there's nothing reliable to read without the right columns).</summary>
    private static Dictionary<string, int>? HeaderMap(
        IXLWorksheet ws, string[] required, string sheetName, List<MenuImportRowError> errors)
    {
        var headerRow = ws.Row(1);
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var lastCol = headerRow.LastCellUsed()?.Address.ColumnNumber ?? 0;
        for (var c = 1; c <= lastCol; c++)
        {
            var name = headerRow.Cell(c).GetString().Trim();
            if (!string.IsNullOrEmpty(name) && !map.ContainsKey(name)) map[name] = c;
        }
        var missing = required.Where(h => !map.ContainsKey(h)).ToList();
        if (missing.Count > 0)
        {
            errors.Add(new MenuImportRowError(sheetName, 1,
                $"Missing required column(s): {string.Join(", ", missing)}. " +
                "Only a file exported from this brand's \"Export menu\" is accepted."));
            return null;
        }
        return map;
    }

    /// <summary>Data rows below the header, stopping at the end of used cells —
    /// including any row a person left with only some columns filled in.</summary>
    private static IEnumerable<IXLRow> DataRows(IXLWorksheet ws)
    {
        var lastRow = ws.LastRowUsed()?.RowNumber() ?? 1;
        for (var r = 2; r <= lastRow; r++)
        {
            var row = ws.Row(r);
            if (row.CellsUsed().Any()) yield return row;
        }
    }

    private static bool CellHasValue(IXLRow row, int col)
    {
        var cell = row.Cell(col);
        return !cell.IsEmpty() && !string.IsNullOrWhiteSpace(cell.GetString());
    }

    private static bool TryReadInt(IXLRow row, int col, out int value)
    {
        var cell = row.Cell(col);
        if (cell.IsEmpty() || string.IsNullOrWhiteSpace(cell.GetString())) { value = 0; return false; }
        if (cell.DataType == XLDataType.Number) { value = (int)cell.GetDouble(); return true; }
        return int.TryParse(cell.GetString().Trim(), out value);
    }

    /// <summary>Blank means null (not configured / cleared) — never an error.
    /// Anything present that isn't a valid number is a row error.</summary>
    private static bool TryReadDecimal(IXLRow row, int col, int rowNum, string sheet, string columnName,
        List<MenuImportRowError> errors, out decimal? value)
    {
        var cell = row.Cell(col);
        if (cell.IsEmpty() || string.IsNullOrWhiteSpace(cell.GetString())) { value = null; return true; }
        if (cell.DataType == XLDataType.Number) { value = (decimal)cell.GetDouble(); return true; }
        if (decimal.TryParse(cell.GetString().Trim(), out var parsed)) { value = parsed; return true; }
        errors.Add(new MenuImportRowError(sheet, rowNum, $"{columnName} must be a number, or blank."));
        value = null;
        return false;
    }
}
