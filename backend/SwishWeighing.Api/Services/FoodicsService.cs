using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Services;

public class FoodicsBrandToken
{
    public string Code { get; set; } = "";
    public string Token { get; set; } = "";
}

public class FoodicsOptions
{
    public string BaseUrl { get; set; } = "https://api.foodics.com/v5";
    // Foodics sits behind Cloudflare, which blocks default HTTP clients (1010).
    // A browser-like User-Agent is required — same lesson as the tablet app.
    public string UserAgent { get; set; } =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 SWiSH-Weighing";
    public List<FoodicsBrandToken> Brands { get; set; } = new();

    /// How often the background auto-sync re-pulls every brand's catalog from
    /// Foodics (see FoodicsAutoSyncHostedService), in minutes. 0 or unset uses
    /// the service's own default (5 min). This is the mechanism that makes
    /// "a new Foodics item shows up automatically to be weighed" work with
    /// zero extra setup — the webhook below is a purely optional, faster
    /// alternative on top of it, not a requirement.
    public int AutoSyncIntervalMinutes { get; set; } = 5;

    /// An unguessable path segment for the OPTIONAL inbound Foodics webhook
    /// (POST /api/webhooks/foodics/{WebhookSecret}) — entirely unnecessary
    /// for automatic sync to work; the periodic sweep above already handles
    /// that on its own. This only matters if you later decide the ~5 minute
    /// sweep isn't fast enough and want near-instant sync instead — doing so
    /// requires emailing support@foodics.com with this app's webhook URL,
    /// since Foodics' own docs don't offer a signature/HMAC scheme or a
    /// self-service registration API. Unset (empty, the default) disables
    /// the endpoint entirely (404 for every request) rather than accepting
    /// unauthenticated calls.
    public string WebhookSecret { get; set; } = "";
}

/// <summary>
/// Pulls the menu (products + modifiers) from Foodics for a brand and upserts it
/// into SQL Server. New items land with NO weight (NULL) — never a guess — so the
/// admin portal and tablet both show them as "not configured" until set.
/// </summary>
public class FoodicsService
{
    private readonly HttpClient _http;
    private readonly FoodicsOptions _opts;
    private readonly AppDbContext _db;
    private readonly ILogger<FoodicsService> _log;

    public FoodicsService(HttpClient http, IOptions<FoodicsOptions> opts,
        AppDbContext db, ILogger<FoodicsService> log)
    {
        _http = http;
        _opts = opts.Value;
        _db = db;
        _log = log;
    }

    private string? TokenFor(string code) => _opts.Brands
        .FirstOrDefault(b => b.Code.Equals(code, StringComparison.OrdinalIgnoreCase))?.Token;

    public async Task<SyncResultDto> SyncBrandAsync(Brand brand, CancellationToken ct = default)
    {
        var token = TokenFor(brand.Code);
        if (string.IsNullOrWhiteSpace(token))
            throw new InvalidOperationException(
                $"No Foodics token configured for brand '{brand.Code}'. Add it under Foodics:Brands in configuration.");

        // Best-effort: captures Foodics' own business "reference" so a later
        // inbound webhook (which only identifies the business, not our
        // internal BrandId) can be routed back to this brand. Never blocks
        // the rest of the sync — a brand that's never resolved this simply
        // isn't reachable via webhook yet and keeps relying on the periodic
        // sweep, same as before this existed.
        try
        {
            var reference = await FetchBusinessReferenceAsync(token, ct);
            if (!string.IsNullOrEmpty(reference) && reference != brand.FoodicsAccount)
                brand.FoodicsAccount = reference;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Foodics whoami lookup failed for brand {Code}", brand.Code);
        }

        // ---- Modifiers first (best-effort; never fails the whole sync) ----
        // A Foodics "modifier" is a GROUP (e.g. "Choice of Fries", reference
        // "modbb-81") — not itself weighable, since each of its OPTIONS (e.g.
        // "Regular Fries", "Curly Fries") can weigh differently. We sync at the
        // option level: one row per selectable option, keyed by the option's
        // own Foodics id (the same id that appears on a live order line as
        // products[].options[].modifier_option.id once resolved), carrying its
        // own SKU plus the parent group's id/reference/name for display and
        // for resolving which options belong to a product's linked group
        // (done below, once products are synced too).
        // Synced BEFORE products so that by the time we read a product's
        // linked modifier groups, every option already has a ModifierId to
        // link against.
        int modAdded = 0, modUpdated = 0;
        var optionIdToModifierId = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var groupIdToOptionIds = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var modifierSyncOk = false;
        try
        {
            var raw = await FetchAllAsync(token, "modifiers?include=options", ct);
            var flat = new List<(string OptionId, string OptionName, string? OptionSku, bool OptionActive,
                string GroupId, string? GroupName, string? GroupReference)>();
            foreach (var m in raw)
            {
                var groupId = GetString(m, "id");
                var groupName = GetString(m, "name");
                var groupRef = GetString(m, "reference");
                if (string.IsNullOrEmpty(groupId)) continue;

                if (m.TryGetProperty("options", out var opts) && opts.ValueKind == JsonValueKind.Array)
                {
                    foreach (var o in opts.EnumerateArray())
                    {
                        var oid = GetString(o, "id");
                        var on = GetString(o, "name");
                        if (string.IsNullOrEmpty(oid) || string.IsNullOrEmpty(on)) continue;
                        flat.Add((oid, on, GetString(o, "sku"), GetBool(o, "is_active", true),
                            groupId, groupName, groupRef));
                    }
                }
                // If a group has no options at all, there's nothing weighable
                // to sync from it — it simply contributes no rows.
            }

            var existingMods = await _db.Modifiers.Where(x => x.BrandId == brand.BrandId).ToListAsync(ct);
            var modsById = existingMods.ToDictionary(x => x.FoodicsModifierId, StringComparer.OrdinalIgnoreCase);
            var seenIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var f in flat)
            {
                seenIds.Add(f.OptionId);
                groupIdToOptionIds.TryAdd(f.GroupId, new List<string>());
                groupIdToOptionIds[f.GroupId].Add(f.OptionId);

                if (modsById.TryGetValue(f.OptionId, out var mod))
                {
                    mod.Name = f.OptionName;
                    mod.Sku = f.OptionSku;
                    mod.ModifierGroupName = f.GroupName;
                    mod.FoodicsModifierGroupId = f.GroupId;
                    mod.ModifierGroupReference = f.GroupReference;
                    mod.IsActive = f.OptionActive;
                    mod.UpdatedAt = DateTime.UtcNow;
                    modUpdated++;
                }
                else
                {
                    mod = new Modifier
                    {
                        BrandId = brand.BrandId,
                        FoodicsModifierId = f.OptionId,
                        Name = f.OptionName,
                        Sku = f.OptionSku,
                        ModifierGroupName = f.GroupName,
                        FoodicsModifierGroupId = f.GroupId,
                        ModifierGroupReference = f.GroupReference,
                        IsActive = f.OptionActive,
                        UpdatedAt = DateTime.UtcNow,
                    };
                    _db.Modifiers.Add(mod);
                    modsById[f.OptionId] = mod;
                    modAdded++;
                }
            }

            // Anything no longer present (including the old group-level rows
            // from before this option-level sync existed) is deactivated, not
            // deleted — never touches a configured weight, just hides it from
            // the portal and tablet config.
            foreach (var stale in existingMods.Where(x => x.IsActive && !seenIds.Contains(x.FoodicsModifierId)))
            {
                stale.IsActive = false;
                stale.UpdatedAt = DateTime.UtcNow;
            }

            // Save now so every option (new or existing) has a ModifierId
            // before we resolve product -> group -> option -> ModifierId below.
            await _db.SaveChangesAsync(ct);
            foreach (var (oid, mod) in modsById)
                optionIdToModifierId[oid] = mod.ModifierId;
            modifierSyncOk = true;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Modifier sync skipped for brand {Code}", brand.Code);
        }

        // ---- Products -> MenuItems ----
        var products = await FetchAllAsync(token, "products?include=category,modifiers", ct);
        var existingItems = await _db.MenuItems.Where(m => m.BrandId == brand.BrandId).ToListAsync(ct);
        var itemsById = existingItems.ToDictionary(m => m.FoodicsProductId, StringComparer.OrdinalIgnoreCase);

        // A modifier GROUP is shared across many products — Foodics duplicates
        // its options once per product/combo that offers them (e.g. "Your
        // Choice Of Drink" can hold ~200 rows: ~19 near-identical "Arwa Water"
        // options, one per product that uses the group). The product<->group
        // pivot's excluded_options_ids is what actually narrows that shared
        // pool down to the handful genuinely offered on THIS product — without
        // applying it, every product using a shared group would appear to link
        // to every duplicate of every option in it. So we keep, per product,
        // the group id plus the set of option ids Foodics says are excluded.
        var productGroupLinks = new Dictionary<string, List<(string GroupId, HashSet<string> Excluded)>>(
            StringComparer.OrdinalIgnoreCase);

        int itemsAdded = 0, itemsUpdated = 0;
        foreach (var p in products)
        {
            var id = GetString(p, "id");
            var name = GetString(p, "name");
            if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(name)) continue;

            string? cat = null, catId = null, catRef = null;
            if (p.TryGetProperty("category", out var c) && c.ValueKind == JsonValueKind.Object)
            {
                cat = GetString(c, "name");
                catId = GetString(c, "id");
                catRef = GetString(c, "reference");
            }

            var linkedGroups = new List<(string GroupId, HashSet<string> Excluded)>();
            if (p.TryGetProperty("modifiers", out var pmods) && pmods.ValueKind == JsonValueKind.Array)
                foreach (var g in pmods.EnumerateArray())
                {
                    var gid = GetString(g, "id");
                    if (string.IsNullOrEmpty(gid)) continue;
                    var excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    if (g.TryGetProperty("pivot", out var pivot) && pivot.ValueKind == JsonValueKind.Object &&
                        pivot.TryGetProperty("excluded_options_ids", out var exArr) &&
                        exArr.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var ex in exArr.EnumerateArray())
                        {
                            var exId = ex.ValueKind == JsonValueKind.String ? ex.GetString() : null;
                            if (!string.IsNullOrEmpty(exId)) excluded.Add(exId);
                        }
                    }
                    linkedGroups.Add((gid, excluded));
                }
            productGroupLinks[id] = linkedGroups;

            var sku = GetString(p, "sku");
            var isActive = GetBool(p, "is_active", true);

            if (itemsById.TryGetValue(id, out var item))
            {
                // Refresh name/category/sku/active-state only — never touch configured weights.
                item.Name = name;
                item.CategoryName = cat;
                item.Sku = sku;
                item.FoodicsCategoryId = catId;
                item.CategoryReference = catRef;
                item.IsActive = isActive;
                item.UpdatedAt = DateTime.UtcNow;
                itemsUpdated++;
            }
            else
            {
                item = new MenuItem
                {
                    BrandId = brand.BrandId,
                    FoodicsProductId = id,
                    Name = name,
                    CategoryName = cat,
                    Sku = sku,
                    FoodicsCategoryId = catId,
                    CategoryReference = catRef,
                    IsActive = isActive,
                    UpdatedAt = DateTime.UtcNow,
                };
                _db.MenuItems.Add(item);
                itemsById[id] = item;
                itemsAdded++;
            }
        }

        // Save now so every item (new or existing) has a MenuItemId before
        // we write the item <-> modifier-option join rows below.
        await _db.SaveChangesAsync(ct);

        // ---- Item <-> modifier links (only if the modifier sync above actually
        // ran — otherwise we'd have no reliable group->option map and would
        // wrongly wipe out every existing link on a transient Foodics hiccup) ----
        if (modifierSyncOk)
        {
            var brandItemIds = itemsById.Values.Select(x => x.MenuItemId).ToList();
            var existingLinks = await _db.MenuItemModifiers
                .Where(x => brandItemIds.Contains(x.MenuItemId)).ToListAsync(ct);
            var existingByItem = existingLinks.GroupBy(x => x.MenuItemId)
                .ToDictionary(g => g.Key, g => g.Select(x => x.ModifierId).ToHashSet());

            foreach (var (productId, groups) in productGroupLinks)
            {
                if (!itemsById.TryGetValue(productId, out var item)) continue;
                var wanted = groups
                    .SelectMany(g => (groupIdToOptionIds.TryGetValue(g.GroupId, out var opts)
                        ? opts : Enumerable.Empty<string>()).Where(oid => !g.Excluded.Contains(oid)))
                    .Select(oid => optionIdToModifierId.TryGetValue(oid, out var mid) ? (int?)mid : null)
                    .Where(x => x.HasValue).Select(x => x!.Value)
                    .ToHashSet();
                var existing = existingByItem.TryGetValue(item.MenuItemId, out var e) ? e : new HashSet<int>();

                foreach (var mid in wanted.Except(existing))
                    _db.MenuItemModifiers.Add(new MenuItemModifier { MenuItemId = item.MenuItemId, ModifierId = mid });
                foreach (var mid in existing.Except(wanted))
                {
                    var link = existingLinks.First(x => x.MenuItemId == item.MenuItemId && x.ModifierId == mid);
                    _db.MenuItemModifiers.Remove(link);
                }
            }
        }

        // A deliberately separate signal from PublishedVersion (which only
        // moves when an admin explicitly clicks Publish) — see
        // docs/sql/13_brand_menu_sync_version.sql. Bumping it here, on every
        // sync that actually touched something, is what lets a tablet's cheap
        // ~20s version poll notice a Foodics-side catalog change (a new
        // product, a rename) without anyone visiting the portal at all.
        if (itemsAdded > 0 || itemsUpdated > 0 || modAdded > 0 || modUpdated > 0)
            brand.MenuSyncedVersion += 1;

        brand.UpdatedAt = DateTime.UtcNow;
        await _db.SaveChangesAsync(ct);

        var totalItems = await _db.MenuItems.CountAsync(m => m.BrandId == brand.BrandId && m.IsActive, ct);
        var missing = await _db.MenuItems.CountAsync(
            m => m.BrandId == brand.BrandId && m.IsActive && (m.MinWeightG == null || m.MaxWeightG == null), ct);

        return new SyncResultDto(itemsAdded, itemsUpdated, modAdded, modUpdated, totalItems, missing);
    }

    /// <summary>Best-effort: this token's business "reference" (GET /whoami), used
    /// only to route an inbound webhook back to the right brand. Returns null
    /// on any failure — never throws, since this is a nice-to-have, not core
    /// to syncing the catalog itself.</summary>
    private async Task<string?> FetchBusinessReferenceAsync(string token, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{_opts.BaseUrl}/whoami");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
        req.Headers.TryAddWithoutValidation("User-Agent", _opts.UserAgent);
        req.Headers.TryAddWithoutValidation("Accept", "application/json");

        using var resp = await _http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode) return null;
        var body = await resp.Content.ReadAsStringAsync(ct);
        using var doc = JsonDocument.Parse(body);
        if (!doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object)
            return null;
        if (!data.TryGetProperty("business", out var business) || business.ValueKind != JsonValueKind.Object)
            return null;
        return GetString(business, "reference");
    }

    /// <summary>Pulls this brand's branches (stores) from Foodics into SQL.</summary>
    public async Task<BranchSyncResultDto> SyncBranchesAsync(Brand brand, CancellationToken ct = default)
    {
        var token = TokenFor(brand.Code);
        if (string.IsNullOrWhiteSpace(token))
            throw new InvalidOperationException(
                $"No Foodics token configured for brand '{brand.Code}'.");

        var branches = await FetchAllAsync(token, "branches", ct);
        var existing = await _db.Branches.Where(b => b.BrandId == brand.BrandId).ToListAsync(ct);
        var byFid = existing.Where(b => b.FoodicsBranchId != null)
            .ToDictionary(b => b.FoodicsBranchId!, StringComparer.OrdinalIgnoreCase);

        int added = 0, updated = 0;
        foreach (var br in branches)
        {
            var id = GetString(br, "id");
            var name = GetString(br, "name");
            if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(name)) continue;
            var reference = GetString(br, "reference");
            var active = GetBool(br, "is_active", true);
            var nameLocalized = GetString(br, "name_localized");
            var openingFrom = GetString(br, "opening_from");
            var openingTo = GetString(br, "opening_to");

            if (byFid.TryGetValue(id, out var b))
            {
                b.Name = name;
                b.Code = reference;
                b.IsActive = active;
                b.NameLocalized = nameLocalized;
                b.OpeningFrom = openingFrom;
                b.OpeningTo = openingTo;
                updated++;
            }
            else
            {
                _db.Branches.Add(new Branch
                {
                    BrandId = brand.BrandId,
                    FoodicsBranchId = id,
                    Name = name,
                    Code = reference,
                    IsActive = active,
                    NameLocalized = nameLocalized,
                    OpeningFrom = openingFrom,
                    OpeningTo = openingTo,
                    CreatedAt = DateTime.UtcNow,
                });
                added++;
            }
        }
        await _db.SaveChangesAsync(ct);
        var total = await _db.Branches.CountAsync(b => b.BrandId == brand.BrandId, ct);
        return new BranchSyncResultDto(added, updated, total);
    }

    /// <summary>Fetches every page of a Foodics list endpoint and returns the flattened data rows.</summary>
    private async Task<List<JsonElement>> FetchAllAsync(string token, string path, CancellationToken ct)
    {
        var results = new List<JsonElement>();
        int page = 1, lastPage = 1;
        do
        {
            var sep = path.Contains('?') ? "&" : "?";
            var url = $"{_opts.BaseUrl}/{path}{sep}page={page}&per_page=50";

            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
            req.Headers.TryAddWithoutValidation("User-Agent", _opts.UserAgent);
            req.Headers.TryAddWithoutValidation("Accept", "application/json");

            using var resp = await _http.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode)
                throw new InvalidOperationException(
                    $"Foodics '{path}' returned {(int)resp.StatusCode}. {Trim(body)}");

            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
                foreach (var el in data.EnumerateArray())
                    results.Add(el.Clone());

            if (root.TryGetProperty("meta", out var meta) &&
                meta.TryGetProperty("last_page", out var lp) && lp.ValueKind == JsonValueKind.Number)
                lastPage = lp.GetInt32();

            page++;
        }
        while (page <= lastPage && page <= 200); // hard cap guards a runaway loop

        return results;
    }

    private static string? GetString(JsonElement e, string prop)
    {
        if (!e.TryGetProperty(prop, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.String => v.GetString(),
            JsonValueKind.Null => null,
            _ => v.ToString(),
        };
    }

    private static bool GetBool(JsonElement e, string prop, bool fallback)
    {
        if (!e.TryGetProperty(prop, out var v)) return fallback;
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.Number => v.TryGetInt32(out var n) ? n != 0 : fallback,
            JsonValueKind.String => v.GetString() is "1" or "true" or "True",
            _ => fallback,
        };
    }

    private static string Trim(string s) => s.Length > 300 ? s[..300] : s;
}
