namespace SwishWeighing.Api.Dtos;

public record BrandSummaryDto(int BrandId, string Code, string Name, int PublishedVersion,
    int TotalItems, int MissingWeights);

// ModifierIds: the FoodicsModifierId of each option actually linked to THIS
// item (already narrowed via the product<->group pivot's excluded_options_ids
// — see FoodicsService — so it's the real, non-duplicated set a customer can
// actually pick on this item, not every catalog row sharing a shared group).
public record MenuItemDto(int MenuItemId, string FoodicsProductId, string Name, string? CategoryName,
    string? Sku, string? CategoryReference, bool IsActive, bool HasModifiers,
    IReadOnlyList<string> ModifierIds,
    decimal? IdealWeightG, decimal? MinWeightG, decimal? MaxWeightG, decimal? PackagingWeightG,
    bool IsConfigured);

public record ModifierDto(int ModifierId, string FoodicsModifierId, string Name,
    string? ModifierGroupName, string? Sku, string? ModifierGroupReference, bool IsActive,
    decimal? WeightG, decimal? MinWeightG, decimal? MaxWeightG, bool IsConfigured);

// A product's linked modifier GROUP (e.g. "Choice of Fries", reference
// "modbb-81") together with the weighable OPTIONS under it — shown when an
// item is expanded in the portal.
public record ItemModifierGroupDto(string GroupId, string? GroupName, string? GroupReference,
    IReadOnlyList<ModifierDto> Options);

public record ItemWeightUpdateDto(decimal? IdealWeightG, decimal? MinWeightG, decimal? MaxWeightG,
    decimal? PackagingWeightG, string? UpdatedBy);

public record ModifierWeightUpdateDto(decimal? WeightG, decimal? MinWeightG, decimal? MaxWeightG,
    string? UpdatedBy);

// Applies one weight to every ACTIVE modifier in a brand sharing the exact
// same name — e.g. the same physical "Arwa Water" bottle that Foodics has
// split into many separate catalog rows across different deals/combos.
// Deliberately exact-match on name (not fuzzy): different quantities like
// "2 Arwa Water" have their own distinct name and are never grouped in.
public record BulkModifierWeightUpdateDto(string Name, decimal? WeightG, decimal? MinWeightG,
    decimal? MaxWeightG, string? UpdatedBy);

public record BulkModifierUpdateResultDto(int UpdatedCount, IReadOnlyList<ModifierDto> Modifiers);

public record PublishDto(string? PublishedBy, string? Notes);

// FoodicsBranchId: the registered branch's own Foodics branch UUID, present
// only when resolved from a specific device (see DevicesController.MyConfig)
// — null for the brand-level admin endpoint, which has no single branch in
// scope. Lets the tablet auto-fetch live orders for exactly its own branch
// instead of relying on a separately, manually picked (and easily
// mismatched) brand/branch in Settings. BranchName is the human-readable
// label (e.g. "ARD-BBT") for display — the UUID is not fit to show a person.
// BranchNameLocalized is Foodics' own localized display name (e.g. "Yard
// Branch") — preferred over BranchName wherever a person reads it.
// BranchOpeningFrom/To are Foodics' daily opening/closing time ("HH:mm"
// strings, not full timestamps); equal from/to conventionally means open
// around the clock.
public record BrandConfigDto(int BrandId, string Code, string Name, int PublishedVersion,
    IReadOnlyList<MenuItemDto> Items, IReadOnlyList<ModifierDto> Modifiers,
    string? FoodicsBranchId = null, string? BranchName = null,
    string? BranchNameLocalized = null, string? BranchOpeningFrom = null, string? BranchOpeningTo = null,
    int MenuSyncedVersion = 0, IReadOnlyList<ModifierCombinationConfigDto>? ModifierCombinations = null);

// Tablet-facing combination override, keyed by Foodics modifier ids (the
// tablet's menuIndex never sees our internal int ModifierIds) — see
// docs/sql/15_modifier_combination_weights.sql for what this represents.
// AnchorFoodicsModifierId, when set, is the Foodics id (one of
// FoodicsModifierIds) whose own weight stays untouched — see
// docs/sql/16_modifier_combination_anchor.sql.
public record ModifierCombinationConfigDto(IReadOnlyList<string> FoodicsModifierIds,
    string? AnchorFoodicsModifierId, decimal WeightG, decimal? MinWeightG, decimal? MaxWeightG);

// Items is the order's own item/modifier composition at the moment it was
// weighed — optional (older tablet builds, or an order the tablet couldn't
// resolve, simply omit it) and never required for the weigh-event itself to
// be recorded. It's the raw material for the weighed-orders CSV export used
// to train an ML model later.
public record WeighEventDto(int BranchId, int? DeviceId, string? FoodicsOrderId,
    decimal? ExpectedMinG, decimal? ExpectedMaxG, decimal? MeasuredG,
    string Verdict, string? OverrideReason, bool? ItemMissing, DateTime? WeighedAt,
    List<WeighEventItemDto>? Items = null, string? OrderLabel = null,
    List<string>? UnconfiguredReasons = null);

public record WeighEventModifierDto(string ModifierId, string? Name);

public record WeighEventItemDto(string MenuItemId, string? Name, List<WeighEventModifierDto>? Modifiers);

public record SyncResultDto(int ItemsAdded, int ItemsUpdated, int ModifiersAdded, int ModifiersUpdated,
    int TotalItems, int MissingWeights);

// --- AI training-data preview/export (weighed orders, cleaned and resolved
// into combination-aware components — see WeighEventsController for the
// resolution logic, which mirrors the tablet's own resolveSelectedModifiers
// so training data reflects exactly what the app itself computes). ---

// Key is a stable identifier a training script can one-hot encode directly
// ("item:78", "modifier:847", "combo:668,847" — always the same string for
// the same real-world component). Type is "item" | "modifier" |
// "combination" | "unmapped" (a component whose Foodics id no longer
// resolves against the current catalog — kept, never silently dropped, so
// data-quality issues stay visible rather than quietly skewing the dataset).
// LineIndex (0-based) is which order line this component came from — an
// order with more than one item needs this to tell which modifiers belong
// to which item; without it, a two-item order's fries and a drink can't be
// told apart from which combo meal they actually came from.
public record TrainingComponentDto(int LineIndex, string Key, string Label, string Type);

public record TrainingOrderPreviewDto(long EventId, DateTime WeighedAt, string? BrandCode, string? BranchName,
    decimal? MeasuredG, string Verdict, string? OverrideReason, bool Trusted, string? ExcludeReason,
    IReadOnlyList<TrainingComponentDto> Components, int UnmappedCount);

// Counts are over the FULL filtered set (cheap COUNT queries), except
// SampledOrdersWithUnmapped which is only over the returned preview sample
// (resolving components for the whole set would be expensive) — the portal
// labels that one accordingly rather than implying it's global.
public record TrainingPreviewSummaryDto(int TotalMatched, int ExcludedOffWeight, int ExcludedOverride,
    int CleanCount, int SampledOrdersWithUnmapped);

public record TrainingPreviewResultDto(TrainingPreviewSummaryDto Summary,
    IReadOnlyList<TrainingOrderPreviewDto> Orders);

// --- Modifier combination weights (2-4 modifiers selected together whose
// combined weight isn't just the sum of each one's own — e.g. a combo-size
// choice affecting both the fries-type AND drink-type portions at once).
// ModifierIds is always returned sorted ascending. AnchorModifierId, when
// set, names which member is "context only" (its own weight is added
// normally, untouched) so WeightG replaces only the OTHER member's own
// weight — only valid for a true 2-member pair; NULL keeps the older
// symmetric behavior (WeightG replaces the sum of both members). ---

public record ModifierCombinationDto(int CombinationId, IReadOnlyList<int> ModifierIds,
    IReadOnlyList<string> ModifierNames, int? AnchorModifierId, decimal WeightG, decimal? MinWeightG,
    decimal? MaxWeightG, DateTime UpdatedAt, string? UpdatedBy);

// ModifierIds may arrive in any order and must be 2-4 distinct ids — the
// server always canonicalizes (sorted ascending) before storing. When
// AnchorModifierId is set it must be one of ModifierIds AND ModifierIds must
// have exactly 2 entries (anchoring only applies to a true pair).
public record ModifierCombinationUpdateDto(IReadOnlyList<int> ModifierIds, int? AnchorModifierId,
    decimal WeightG, decimal? MinWeightG, decimal? MaxWeightG, string? UpdatedBy);

// --- Menu export/import (Excel) ---

public record MenuImportRowError(string Sheet, int RowNumber, string Error);

// Dry-run-first result: if Errors is non-empty, NOTHING was written (the
// whole file is validated before anything is applied) and the counts below
// are what WOULD have changed. If Errors is empty, the counts reflect what
// was actually applied.
public record MenuImportResultDto(bool Applied, int ItemsUpdated, int ModifiersUpdated,
    int CombinationsUpserted, int CombinationsRemoved, IReadOnlyList<MenuImportRowError> Errors);

// --- Branches & devices (tablet connectivity) ---

public record BranchDto(int BranchId, string? FoodicsBranchId, string? Code, string Name,
    bool IsActive, int DeviceCount, int OnlineCount,
    string? NameLocalized = null, string? OpeningFrom = null, string? OpeningTo = null);

public record BranchSyncResultDto(int Added, int Updated, int Total);

public record DeviceDto(int DeviceId, int BranchId, string Label, string? AppVersion,
    DateTime? LastSeenAt, bool Online, bool IsActive);

public record CreateDeviceDto(string Label);

// Returned once, when a device is created — the only time the plaintext key is shown.
public record DeviceCreatedDto(int DeviceId, string Label, string DeviceKey);

public record HeartbeatDto(string? AppVersion);

// --- Device reassignment ---

public record ReassignDeviceDto(int BranchId);

// --- Fast menu-sync polling: cheap enough to hit every ~20s ---

// MenuSyncedVersion is the automatic-sync signal (see Brand.MenuSyncedVersion)
// — the tablet refetches the full config when EITHER this OR PublishedVersion
// has moved, so a Foodics catalog change reaches it without anyone touching
// the portal, while Publish keeps its separate human-reviewed meaning.
public record DeviceVersionDto(int PublishedVersion, int MenuSyncedVersion = 0);

// Cheap poll target for the ML weight-prediction model, mirroring
// DeviceVersionDto for the menu itself — a tablet checks this often and only
// downloads the full model (via the paired /model endpoint) when the version
// has actually changed.
public record ModelMetaDto(int Version, string FileName, long SizeBytes, string Sha256Hash, DateTime UploadedAt);

// --- Device error/status log ---

// EventType: "connection_error" | "recovered". Reason: a short machine code
// (e.g. "no_internet", "timeout", "unauthorized", "server_error",
// "malformed_response") the portal can map to a readable label; Detail is an
// optional human-readable elaboration (e.g. the exception message, truncated).
public record DeviceEventDto(string EventType, string Reason, string? Detail, DateTime? OccurredAt);

public record DeviceEventLogEntryDto(int DeviceEventId, string EventType, string Reason,
    string? Detail, DateTime OccurredAt);

// Single-device detail for the portal's per-scale dashboard.
// BranchNameLocalized is Foodics' own localized display name — preferred over
// BranchName wherever a person reads it, matching BranchDto/BrandConfigDto.
public record DeviceDetailDto(int DeviceId, string Label, string? AppVersion,
    DateTime? LastSeenAt, bool Online, bool IsActive,
    int BranchId, string BranchName, int BrandId, string BrandCode, string BrandName,
    DeviceEventLogEntryDto? LastEvent, string? BranchNameLocalized = null);

// ItemsJson is the raw JSON string captured at weigh time (see WeighEvent's
// own field for the shape) — passed through as-is rather than re-parsed here
// so the portal can render it directly without a round-trip through a
// strongly-typed shape that would need to stay in lockstep with the tablet's.
public record WeighEventEntryDto(long EventId, int? DeviceId, string? FoodicsOrderId,
    decimal? ExpectedMinG, decimal? ExpectedMaxG, decimal? MeasuredG,
    string Verdict, string? OverrideReason, bool? ItemMissing, DateTime WeighedAt,
    string? ItemsJson = null, string? OrderLabel = null, string? UnconfiguredReasonsJson = null);

// --- Analytics ("AI COO"-style predefined-question insights) ---

// One named data series to plot (e.g. {key:"count", label:"Orders"}) — a
// chart with more than one series (rare here, kept for future use) renders
// as grouped bars/lines sharing the same XKey.
public record ChartSeriesDto(string Key, string Label);

// Type: "bar" | "line" | "area" | "pie". Data rows are plain string-keyed
// dictionaries (the XKey plus each series' Key) rather than a fixed shape,
// since every question's chart has different columns — the frontend's chart
// renderer switches on Type and reads whichever keys Series/XKey name.
// ColorMode picks the palette a multi-series chart draws from: "status" for
// series whose color carries meaning (on/under/over-weight — good/bad, not
// just "series 2"), null/omitted for the default single-hue sequential ramp
// used by every plain magnitude ranking. A "status" chart's series Keys must
// match the frontend's fixed lookup (onWeightPct/underPct/overPct, etc.) so
// color follows meaning rather than series position.
public record ChartDto(string Type, string XKey, IReadOnlyList<ChartSeriesDto> Series,
    IReadOnlyList<Dictionary<string, object?>> Data, string? XLabel = null, string? YLabel = null,
    string? ColorMode = null);

// The full answer to one predefined analytics question. Headline is a single
// bold-worthy sentence; Narrative is 2-4 sentences of plain-English
// explanation grounded in the actual computed numbers (template-generated
// from real stats, not a live model call). Caveat, when present, is a
// data-limitation note the UI shows distinctly (e.g. "requires N+ samples,
// M compositions excluded") — used instead of silently guessing or omitting
// a number that would otherwise look confidently wrong. SecondaryChart is an
// optional second, differently-shaped visual for the same question (e.g. a
// verdict-share donut paired with a reason-code bar) — most questions leave
// it null; it exists so one question can carry more than one kind of insight
// without forcing unrelated data into a single chart.
public record AnalyticsResultDto(string Headline, string Narrative, string? Caveat,
    ChartDto? Chart, IReadOnlyList<string>? TableColumns = null,
    IReadOnlyList<Dictionary<string, object?>>? Table = null,
    ChartDto? SecondaryChart = null, string? SecondaryChartTitle = null);

// --- Data source & quality (Analytics "Data" section) ---

public record BranchDataQualityDto(string BranchLabel, int EventCount,
    double CompositionCapturePct, double ExpectedRangeCapturePct, DateTime? LastWeighedAt);

public record DataQualitySummaryDto(
    int TotalWeighEvents,
    int EventsWithComposition, double CompositionCapturePct,
    int EventsWithExpectedRange, double ExpectedRangeCapturePct,
    int ActiveBranches, int TotalBranches,
    int ActiveDevices, int TotalDevices,
    int BranchesWithNoWeighs,
    DateTime? OldestEventAt, DateTime? NewestEventAt,
    IReadOnlyList<BranchDataQualityDto> ByBranch);

