using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace SwishWeighing.Api.Models;

// These entities map 1:1 to the tables created by docs/sql/01_schema.sql.
// The SQL script owns the schema; EF just reads/writes it (no migrations).

[Table("Brands")]
public class Brand
{
    [Key] public int BrandId { get; set; }
    public string Code { get; set; } = "";
    public string Name { get; set; } = "";

    /// Foodics' own business "reference" (from GET /whoami), captured during
    /// sync — how an inbound Foodics webhook (which only identifies the
    /// business, not our internal BrandId) is routed back to this brand.
    public string? FoodicsAccount { get; set; }

    public int PublishedVersion { get; set; }

    /// Bumped by the automatic Foodics sync (webhook-triggered or periodic)
    /// whenever the catalog actually changed — see docs/sql/13_brand_menu_sync_version.sql
    /// for why this is deliberately separate from PublishedVersion.
    public int MenuSyncedVersion { get; set; }

    public bool IsActive { get; set; } = true;
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
}

[Table("Branches")]
public class Branch
{
    [Key] public int BranchId { get; set; }
    public int BrandId { get; set; }
    public string? FoodicsBranchId { get; set; }
    public string? Code { get; set; }
    public string Name { get; set; } = "";

    /// Foodics' own localized display name (e.g. "Yard Branch" vs. the
    /// internal reference-style `Name`, e.g. "YRD-BBT") — preferred for
    /// anything a person reads; `Name` remains for internal/display fallback.
    public string? NameLocalized { get; set; }

    /// Foodics' daily opening/closing time (e.g. "06:00"), stored exactly as
    /// given — a plain "HH:mm" string, not a full timestamp. Equal
    /// from/to conventionally means open around the clock.
    public string? OpeningFrom { get; set; }
    public string? OpeningTo { get; set; }

    public bool IsActive { get; set; } = true;
    public DateTime CreatedAt { get; set; }
}

[Table("Devices")]
public class Device
{
    [Key] public int DeviceId { get; set; }
    public int BranchId { get; set; }
    public string Label { get; set; } = "";
    public byte[] ApiKeyHash { get; set; } = Array.Empty<byte>();
    public string? AppVersion { get; set; }
    public DateTime? LastSeenAt { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAt { get; set; }
}

[Table("MenuItems")]
public class MenuItem
{
    [Key] public int MenuItemId { get; set; }
    public int BrandId { get; set; }
    public string FoodicsProductId { get; set; } = "";
    public string Name { get; set; } = "";
    public string? CategoryName { get; set; }

    // Foodics catalog identifiers, surfaced in the portal for search/display
    // (e.g. SKU "BB8016", category reference "catbb-27") — separate from the
    // Foodics UUID above, which is an internal id rather than a human key.
    public string? Sku { get; set; }
    public string? FoodicsCategoryId { get; set; }
    public string? CategoryReference { get; set; }

    [Column(TypeName = "decimal(8,2)")] public decimal? IdealWeightG { get; set; }
    [Column(TypeName = "decimal(8,2)")] public decimal? MinWeightG { get; set; }
    [Column(TypeName = "decimal(8,2)")] public decimal? MaxWeightG { get; set; }
    [Column(TypeName = "decimal(8,2)")] public decimal? PackagingWeightG { get; set; }
    public bool IsActive { get; set; } = true;
    public string? UpdatedBy { get; set; }
    public DateTime UpdatedAt { get; set; }

    public bool IsConfigured => MinWeightG != null && MaxWeightG != null;
}

[Table("Modifiers")]
public class Modifier
{
    [Key] public int ModifierId { get; set; }
    public int BrandId { get; set; }

    // The Foodics *modifier option* id (e.g. "Curly Fries", "Coca-Cola Zero") —
    // this is the sellable, individually-weighable choice, not the group it
    // belongs to (e.g. "Choice of Fries"). One weight per selectable option.
    public string FoodicsModifierId { get; set; } = "";
    public string Name { get; set; } = "";

    // The parent modifier group's name from Foodics, kept purely for display
    // context in the portal (e.g. "Choice of Fries") — not used for lookups.
    public string? ModifierGroupName { get; set; }

    // The parent group's own Foodics id + reference (e.g. "modbb-81") — the
    // group id lets us fetch "which options belong to this product's linked
    // group" (see MenuItemModifiers); the reference is shown in the portal.
    public string? FoodicsModifierGroupId { get; set; }
    public string? ModifierGroupReference { get; set; }

    // The option's own SKU (e.g. "8300030"), distinct from FoodicsModifierId
    // (Foodics' internal UUID for this option).
    public string? Sku { get; set; }

    [Column(TypeName = "decimal(8,2)")] public decimal? WeightG { get; set; }

    // Optional measured range, same idea as MenuItem's Min/Max: a modifier
    // (extra sauce, a scoop of coleslaw, a handful of fries) can vary
    // pack-to-pack just like a full item. WeightG remains the ideal/mean.
    [Column(TypeName = "decimal(8,2)")] public decimal? MinWeightG { get; set; }
    [Column(TypeName = "decimal(8,2)")] public decimal? MaxWeightG { get; set; }

    public bool IsActive { get; set; } = true;
    public string? UpdatedBy { get; set; }
    public DateTime UpdatedAt { get; set; }

    public bool IsConfigured => WeightG != null;
}

// Which (option-level) modifiers apply to which item, e.g. so the portal can
// show "Extra Lettuce, Curly Fries…" when you open a product, and filter
// items by "has modifiers". Populated from Foodics' products.modifiers
// relation during sync, flattened down to the option rows in dbo.Modifiers.
[Table("MenuItemModifiers")]
public class MenuItemModifier
{
    public int MenuItemId { get; set; }
    public int ModifierId { get; set; }
}

[Table("WeighEvents")]
public class WeighEvent
{
    [Key] public long EventId { get; set; }
    public int? DeviceId { get; set; }
    public int BranchId { get; set; }
    public string? FoodicsOrderId { get; set; }

    // The order's short, staff-facing label at weigh time ("Order 63",
    // "#REF-123", or a customer name — the tablet's own Order.displayTitle) —
    // so the portal never has to show FoodicsOrderId's long UUID as if it
    // were what staff actually look at. Null for events reported before this
    // existed.
    public string? OrderLabel { get; set; }
    [Column(TypeName = "decimal(9,2)")] public decimal? ExpectedMinG { get; set; }
    [Column(TypeName = "decimal(9,2)")] public decimal? ExpectedMaxG { get; set; }
    [Column(TypeName = "decimal(9,2)")] public decimal? MeasuredG { get; set; }
    public string Verdict { get; set; } = "";
    public string? OverrideReason { get; set; }
    public bool? ItemMissing { get; set; }
    public DateTime WeighedAt { get; set; }
    public DateTime CreatedAt { get; set; }

    // The order's own item/modifier composition at the moment it was weighed
    // (JSON array of {menuItemId, name, modifiers:[{modifierId, name}]}) —
    // the raw material for the weighed-orders CSV export used to train an ML
    // model later. Null for events reported before this existed, and for any
    // report where the tablet couldn't resolve the order (never blocks the
    // weigh-event itself from being recorded).
    public string? ItemsJson { get; set; }

    // Exactly which item(s)/modifier(s) blocked the weight check for an
    // "unconfigured" verdict (JSON array of plain strings, e.g. "Chilli Lime
    // for Fillaa on Toast Duo Combo not weighed yet") — the tablet's own
    // findUnconfiguredWeightMessages() output, so the portal can say
    // precisely what's missing instead of just "unconfigured". Null for
    // events reported before this existed, and for any event that isn't
    // unconfigured in the first place.
    public string? UnconfiguredReasonsJson { get; set; }
}

[Table("DeviceEvents")]
public class DeviceEvent
{
    [Key] public int DeviceEventId { get; set; }
    public int DeviceId { get; set; }
    public string EventType { get; set; } = "";
    public string Reason { get; set; } = "";
    public string? Detail { get; set; }
    public DateTime OccurredAt { get; set; }
    public DateTime CreatedAt { get; set; }
}

[Table("ConfigPublications")]
public class ConfigPublication
{
    [Key] public int PublicationId { get; set; }
    public int BrandId { get; set; }
    public int Version { get; set; }
    public string? PublishedBy { get; set; }
    public string? Notes { get; set; }
    public DateTime PublishedAt { get; set; }
}

// The current ML weight-prediction model for a brand — published from the
// portal, downloaded and cached by that brand's tablets. One row per brand:
// a new upload replaces the previous model outright (Version increments),
// mirroring how menu publishing already works. See docs/AI_MODEL_CONTRACT.md
// for the exact input/output tensor shape any uploaded model must implement.
[Table("BrandWeightModels")]
public class BrandWeightModel
{
    [Key] public int BrandId { get; set; }
    public int Version { get; set; }
    public string FileName { get; set; } = "";
    public long SizeBytes { get; set; }
    public string Sha256Hash { get; set; } = "";
    public byte[] ModelBytes { get; set; } = [];
    public DateTime UploadedAt { get; set; }
    public string? UploadedBy { get; set; }
}

// The combined weight for up to 4 modifiers selected together on the same
// order line, when it genuinely isn't the sum of each one's own weight —
// e.g. a combo-SIZE choice can affect BOTH the fries-type portion AND the
// drink-type portion at once (a real 3-way interaction: size x fries-type x
// drink-type), which a 2-only design can't represent without silently
// resolving only one of the two. ModifierId1..4 are always in strictly
// increasing order — a canonical order so the same real-world combination
// is never stored twice — enforced both by ModifierCombinationKey below and
// a DB-level CHECK constraint as a backstop. A combination with no matching
// row here simply falls back to plain item+modifier addition; this table is
// an exception list, not a replacement for Modifier.WeightG.
[Table("ModifierCombinationWeights")]
public class ModifierCombinationWeight
{
    [Key] public int CombinationId { get; set; }
    public int BrandId { get; set; }
    public int ModifierId1 { get; set; }
    public int ModifierId2 { get; set; }
    public int? ModifierId3 { get; set; }
    public int? ModifierId4 { get; set; }
    public string ModifierIdsKey { get; set; } = "";

    /// Which of ModifierId1/2 is "context only" — its own standalone weight
    /// is added normally, unaffected (e.g. a combo-size chip, typically 0
    /// weight since it's a label, not a physical component) — so WeightG
    /// replaces only the OTHER (dependent) member's own weight. NULL keeps
    /// the older symmetric behavior (WeightG replaces the sum of both).
    /// Only meaningful for a true 2-member pair (ModifierId3/4 null) — see
    /// docs/sql/16_modifier_combination_anchor.sql. Letting the anchor's own
    /// weight go untouched is what lets ONE anchor value (e.g. "Medium") be
    /// shared across several independent dependent-group overrides (fries,
    /// drinks, ...) applied simultaneously, with no double-counting.
    public int? AnchorModifierId { get; set; }

    [Column(TypeName = "decimal(8,2)")] public decimal WeightG { get; set; }
    [Column(TypeName = "decimal(8,2)")] public decimal? MinWeightG { get; set; }
    [Column(TypeName = "decimal(8,2)")] public decimal? MaxWeightG { get; set; }
    public string? UpdatedBy { get; set; }
    public DateTime UpdatedAt { get; set; }

    [NotMapped]
    public IEnumerable<int> ModifierIds
    {
        get
        {
            yield return ModifierId1;
            yield return ModifierId2;
            if (ModifierId3.HasValue) yield return ModifierId3.Value;
            if (ModifierId4.HasValue) yield return ModifierId4.Value;
        }
    }
}

/// <summary>Canonicalizes a set of 2-4 modifier ids into the strictly-increasing
/// (ModifierId1..4, ModifierIdsKey) shape ModifierCombinationWeight requires —
/// the single place that ordering rule is implemented, shared by every caller
/// that creates or looks up a combination.</summary>
public static class ModifierCombinationKey
{
    public const int MinMembers = 2;
    public const int MaxMembers = 4;

    /// <summary>Throws ArgumentException if ids isn't 2-4 distinct values.</summary>
    public static (int Id1, int Id2, int? Id3, int? Id4, string Key) Canonicalize(IEnumerable<int> ids)
    {
        var sorted = ids.Distinct().OrderBy(x => x).ToList();
        if (sorted.Count != ids.Count())
            throw new ArgumentException("Modifier ids in a combination must be distinct.");
        if (sorted.Count is < MinMembers or > MaxMembers)
            throw new ArgumentException($"A combination needs {MinMembers}-{MaxMembers} modifiers.");
        return (
            sorted[0], sorted[1],
            sorted.Count > 2 ? sorted[2] : null,
            sorted.Count > 3 ? sorted[3] : null,
            string.Join(",", sorted));
    }
}
