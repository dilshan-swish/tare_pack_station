export interface BrandSummary {
  brandId: number;
  code: string;
  name: string;
  publishedVersion: number;
  totalItems: number;
  missingWeights: number;
}

export interface MenuItem {
  menuItemId: number;
  foodicsProductId: string;
  name: string;
  categoryName: string | null;
  sku: string | null;
  categoryReference: string | null;
  isActive: boolean;
  hasModifiers: boolean;
  idealWeightG: number | null;
  minWeightG: number | null;
  maxWeightG: number | null;
  packagingWeightG: number | null;
  isConfigured: boolean;
}

export interface Modifier {
  modifierId: number;
  foodicsModifierId: string;
  name: string;
  modifierGroupName: string | null;
  sku: string | null;
  modifierGroupReference: string | null;
  isActive: boolean;
  weightG: number | null;
  minWeightG: number | null;
  maxWeightG: number | null;
  isConfigured: boolean;
}

// A product's linked modifier group (e.g. "Choice of Fries", reference
// "modbb-81") with its weighable options — returned when an item is expanded.
export interface ItemModifierGroup {
  groupId: string;
  groupName: string | null;
  groupReference: string | null;
  options: Modifier[];
}

// 2-4 modifiers that must be weighed TOGETHER because their combined weight
// isn't simply the sum of each one's own — e.g. a combo-size choice can
// affect BOTH the fries-type portion AND the drink-type portion at once. See
// docs/sql/15_modifier_combination_weights.sql. anchorModifierId, when set
// (two-modifier combinations only — docs/sql/16_modifier_combination_anchor.sql),
// names which member is "context only" — its own weight is untouched, and
// weightG replaces only the OTHER member's own weight — so the same anchor
// (e.g. a combo size) can be combined with several different dependent
// modifiers across several rows without them conflicting.
export interface ModifierCombination {
  combinationId: number;
  modifierIds: number[];
  modifierNames: string[];
  anchorModifierId: number | null;
  weightG: number;
  minWeightG: number | null;
  maxWeightG: number | null;
  updatedAt: string;
  updatedBy: string | null;
}

export interface MenuImportRowError {
  sheet: string;
  rowNumber: number;
  error: string;
}

export interface MenuImportResult {
  applied: boolean;
  itemsUpdated: number;
  modifiersUpdated: number;
  combinationsUpserted: number;
  combinationsRemoved: number;
  errors: MenuImportRowError[];
}

export interface SyncResult {
  itemsAdded: number;
  itemsUpdated: number;
  modifiersAdded: number;
  modifiersUpdated: number;
  totalItems: number;
  missingWeights: number;
}

export interface WeighSummary {
  total: number;
  onWeight: number;
  under: number;
  over: number;
  offWeight: number;
}

export interface Branch {
  branchId: number;
  foodicsBranchId: string | null;
  code: string | null;
  name: string;
  isActive: boolean;
  deviceCount: number;
  onlineCount: number;
  // Foodics' own localized display name (e.g. "Ardiya Branch") — prefer this
  // over `name` (the short internal code, e.g. "ARD-BBT") wherever a person
  // reads it. Null until a branch sync has populated it.
  nameLocalized: string | null;
}

// --- AI training data (weighed orders cleaned + resolved into components) ---

// Key is a stable id a training script can one-hot encode directly
// ("item:78", "modifier:847", "combo:668,847"). "unmapped" means the raw
// Foodics id on the order no longer resolves against the current catalog —
// kept and labeled, never silently dropped. lineIndex (0-based) is which
// order line this came from — an order with more than one item needs this
// to tell which modifiers belong to which item (a 2x-quantity line arrives
// as two separate, identically-composed lines, each with its own index).
export interface TrainingComponent {
  lineIndex: number;
  key: string;
  label: string;
  type: "item" | "modifier" | "combination" | "unmapped";
}

export interface TrainingOrderPreview {
  eventId: number;
  weighedAt: string;
  brandCode: string | null;
  branchName: string | null;
  measuredG: number | null;
  verdict: string;
  overrideReason: string | null;
  // Dispatched on-weight with no override — the only orders that are real
  // ground truth for what a component actually weighs.
  trusted: boolean;
  excludeReason: string | null;
  components: TrainingComponent[];
  unmappedCount: number;
}

export interface TrainingPreviewSummary {
  totalMatched: number;
  excludedOffWeight: number;
  excludedOverride: number;
  cleanCount: number;
  // Over the returned sample only, not the whole filtered set (resolving
  // every matched order's components would be too expensive for a preview).
  sampledOrdersWithUnmapped: number;
}

export interface TrainingPreviewResult {
  summary: TrainingPreviewSummary;
  orders: TrainingOrderPreview[];
}

export interface Device {
  deviceId: number;
  branchId: number;
  label: string;
  appVersion: string | null;
  lastSeenAt: string | null;
  online: boolean;
  isActive: boolean;
}

export interface DeviceCreated {
  deviceId: number;
  label: string;
  deviceKey: string;
}

// A brand's published ML weight-prediction model (see docs/AI_MODEL_CONTRACT.md
// in the repo for the exact input/output shape a model must implement).
export interface ModelMeta {
  version: number;
  fileName: string;
  sizeBytes: number;
  sha256Hash: string;
  uploadedAt: string;
}

export interface BranchSyncResult {
  added: number;
  updated: number;
  total: number;
}

export interface DeviceEventLogEntry {
  deviceEventId: number;
  eventType: string; // "connection_error" | "recovered"
  reason: string; // machine code, e.g. "no_internet"
  detail: string | null;
  occurredAt: string;
}

// A single scale's full detail for the per-scale dashboard — brand/branch
// resolved fresh (same as what the tablet itself resolves via its key), plus
// the most recent entry from its connectivity log, if any.
export interface DeviceDetail {
  deviceId: number;
  label: string;
  appVersion: string | null;
  lastSeenAt: string | null;
  online: boolean;
  isActive: boolean;
  branchId: number;
  branchName: string;
  // Foodics' own localized display name — prefer this over branchName
  // wherever a person reads it. Null until a branch sync has populated it.
  branchNameLocalized: string | null;
  brandId: number;
  brandCode: string;
  brandName: string;
  lastEvent: DeviceEventLogEntry | null;
}

// The order's own item/modifier composition, captured at weigh time (see
// docs/AI_MODEL_CONTRACT.md in the repo). Absent on events recorded before
// this existed, or where the tablet couldn't resolve the order.
export interface WeighEventModifier {
  modifierId: string;
  name: string | null;
}
export interface WeighEventItem {
  menuItemId: string;
  name: string | null;
  modifiers: WeighEventModifier[] | null;
}

export interface WeighEventEntry {
  eventId: number;
  deviceId: number | null;
  foodicsOrderId: string | null;
  expectedMinG: number | null;
  expectedMaxG: number | null;
  measuredG: number | null;
  verdict: string;
  overrideReason: string | null;
  itemMissing: boolean | null;
  weighedAt: string;
  // Raw JSON string (WeighEventItem[]) — parse with parseWeighEventItems().
  itemsJson: string | null;
  // The order's short, staff-facing label ("Order 63", "#REF-123", or a
  // customer name) at weigh time — prefer this over foodicsOrderId wherever
  // a person reads it. Null for events reported before this existed.
  orderLabel: string | null;
  // Raw JSON string (string[]) — exactly which item(s)/modifier(s) blocked
  // the weight check for an "unconfigured" verdict, e.g. "Chilli Lime for
  // Fillaa on Toast Duo Combo not weighed yet". Parse with
  // parseUnconfiguredReasons(). Null for events reported before this
  // existed, and for any event that isn't unconfigured in the first place.
  unconfiguredReasonsJson: string | null;
}

/** Parses `WeighEventEntry.itemsJson`, or null if absent/malformed — never throws. */
export function parseWeighEventItems(itemsJson: string | null): WeighEventItem[] | null {
  if (!itemsJson) return null;
  try {
    const parsed: unknown = JSON.parse(itemsJson);
    return Array.isArray(parsed) ? (parsed as WeighEventItem[]) : null;
  } catch {
    return null;
  }
}

/** Parses `WeighEventEntry.unconfiguredReasonsJson`, or null if absent/malformed — never throws. */
export function parseUnconfiguredReasons(json: string | null): string[] | null {
  if (!json) return null;
  try {
    const parsed: unknown = JSON.parse(json);
    return Array.isArray(parsed) && parsed.every((x) => typeof x === "string")
      ? (parsed as string[])
      : null;
  } catch {
    return null;
  }
}

// --- Analytics ("AI COO"-style predefined-question insights) ---

export interface ChartSeries {
  key: string;
  label: string;
}

// A chart's rows are plain string-keyed records rather than a fixed shape —
// every question's chart has different columns — so the renderer reads
// whichever keys `xKey`/`series` name. colorMode picks the palette a
// multi-series chart draws from: "status" means each series' color carries
// meaning (on/under/over-weight — good/bad, matched by series key, not
// position) rather than the default single-hue sequential ramp used by
// plain magnitude rankings.
export interface ChartSpec {
  type: "bar" | "line" | "area" | "pie";
  xKey: string;
  series: ChartSeries[];
  data: Record<string, string | number | null>[];
  xLabel: string | null;
  yLabel: string | null;
  colorMode?: "status" | "sequential" | null;
}

export interface AnalyticsResult {
  headline: string;
  narrative: string;
  caveat: string | null;
  chart: ChartSpec | null;
  // An optional second, differently-shaped chart for the same question (e.g.
  // a verdict-share donut paired with a reason-code bar) — most questions
  // leave this null.
  secondaryChart?: ChartSpec | null;
  secondaryChartTitle?: string | null;
  tableColumns: string[] | null;
  table: Record<string, string | number | null>[] | null;
}

export interface BranchDataQuality {
  branchLabel: string;
  eventCount: number;
  compositionCapturePct: number;
  expectedRangeCapturePct: number;
  lastWeighedAt: string | null;
}

export interface DataQualitySummary {
  totalWeighEvents: number;
  eventsWithComposition: number;
  compositionCapturePct: number;
  eventsWithExpectedRange: number;
  expectedRangeCapturePct: number;
  activeBranches: number;
  totalBranches: number;
  activeDevices: number;
  totalDevices: number;
  branchesWithNoWeighs: number;
  oldestEventAt: string | null;
  newestEventAt: string | null;
  byBranch: BranchDataQuality[];
}
