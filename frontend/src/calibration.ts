// Turns a Weigh History "item-level detail" CSV export into calibrated
// ideal/min/max suggestions, purely client-side — nothing here writes
// anything back to the API. See CalibratorPage for the UI this feeds.
//
// The method, precisely (so it's auditable, not a black box):
//  - Only orders that are "clean" — verdict onweight, no override reason —
//    are used, matching the same ground-truth definition the rest of the
//    app already uses for training data.
//  - Only SINGLE-ITEM orders are used. measured_g is the whole order's
//    total, not any one item's own weight, so a multi-item order can't be
//    safely attributed to one item without guessing — it's excluded and
//    counted, never silently dropped.
//  - A single-item order with no modifiers is a direct sample of that
//    item's own weight. With exactly one modifier, it's a direct sample of
//    "item + that modifier" together; if the item's own weight is already
//    known confidently from the first case, subtracting it isolates the
//    modifier's own weight IN THAT ITEM'S CONTEXT — the same modifier under
//    a different item is a different bucket entirely, on purpose. With two
//    or more modifiers at once, isolating any single one would require
//    guessing, so it's kept as one bundled "combo" figure instead.
import { parseCsvObjects } from "./csv";
import type { MenuItem, Modifier, ModifierCombination } from "./types";

export type Confidence = "insufficient" | "low" | "medium" | "high";

export interface CalibrationStats {
  n: number;
  mean: number;
  sd: number;
  /// "measured" = every sample is a direct scale reading. "derived" = this
  /// is a subtraction of two measured stats (a modifier isolated from its
  /// item) — same math, but there's no single raw reading behind it.
  basis: "measured" | "derived";
  suggestedIdeal: number;
  suggestedMin: number;
  suggestedMax: number;
  observedMin: number;
  observedMax: number;
  confidence: Confidence;
}

function round1(n: number): number {
  return Math.round(n * 10) / 10;
}

/// n < 3: too little data to say anything. Otherwise high/medium/low by
/// sample size, stepped down a level when the relative spread (coefficient
/// of variation) is high enough that the count alone would overstate how
/// tight the resulting band really is.
function confidenceFor(n: number, cv: number): Confidence {
  if (n < 3) return "insufficient";
  let base: Confidence = n >= 30 ? "high" : n >= 10 ? "medium" : "low";
  if (cv > 0.2 && base === "high") base = "medium";
  if (cv > 0.35 && base === "medium") base = "low";
  return base;
}

function statsFromSamples(samples: number[], allowNegative: boolean): CalibrationStats {
  const n = samples.length;
  if (n === 0) {
    return {
      n: 0, mean: 0, sd: 0, basis: "measured",
      suggestedIdeal: 0, suggestedMin: 0, suggestedMax: 0,
      observedMin: 0, observedMax: 0, confidence: "insufficient",
    };
  }
  const mean = samples.reduce((a, b) => a + b, 0) / n;
  const variance = n > 1 ? samples.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1) : 0;
  const sd = Math.sqrt(variance);
  const cv = mean !== 0 ? sd / Math.abs(mean) : 0;
  const floor = allowNegative ? -Infinity : 0;
  return {
    n, mean: round1(mean), sd: round1(sd), basis: "measured",
    suggestedIdeal: round1(mean),
    suggestedMin: round1(Math.max(floor, mean - 2 * sd)),
    suggestedMax: round1(mean + 2 * sd),
    observedMin: round1(Math.min(...samples)),
    observedMax: round1(Math.max(...samples)),
    confidence: confidenceFor(n, cv),
  };
}

/// Isolates a modifier's own weight under one specific item by subtracting
/// that item's already-known alone-weight from the bundled (item+modifier)
/// figure — variances add in quadrature, the same rule WeightEvaluator uses
/// server-side to combine independent standard deviations. Null when the
/// item was never observed alone confidently enough to subtract from.
function deriveInContext(bundled: CalibrationStats, itemAlone: CalibrationStats | null): CalibrationStats | null {
  if (!itemAlone || itemAlone.n < 3) return null;
  const mean = bundled.mean - itemAlone.mean;
  const sd = Math.sqrt(bundled.sd ** 2 + itemAlone.sd ** 2);
  const n = Math.min(bundled.n, itemAlone.n);
  const cv = mean !== 0 ? sd / Math.abs(mean) : 0;
  return {
    n, mean: round1(mean), sd: round1(sd), basis: "derived",
    suggestedIdeal: round1(mean),
    suggestedMin: round1(mean - 2 * sd), // a modifier can legitimately subtract weight (e.g. "No cheese")
    suggestedMax: round1(mean + 2 * sd),
    observedMin: round1(mean - 2 * sd),
    observedMax: round1(mean + 2 * sd),
    confidence: confidenceFor(n, cv),
  };
}

export type MatchStatus = "good" | "review" | "recalibrate" | "unconfigured" | "unknown";

/// "good": the currently configured ideal already falls inside the newly
/// calibrated band. "review"/"recalibrate": outside it, by less or more than
/// the band's own half-width. "unconfigured": nothing set yet. "unknown":
/// not enough data to judge either way.
export function matchStatusFor(currentIdeal: number | null, stats: CalibrationStats): MatchStatus {
  if (stats.confidence === "insufficient") return "unknown";
  if (currentIdeal == null) return "unconfigured";
  if (currentIdeal >= stats.suggestedMin && currentIdeal <= stats.suggestedMax) return "good";
  const halfWidth = Math.max((stats.suggestedMax - stats.suggestedMin) / 2, 0.5);
  const distance = currentIdeal < stats.suggestedMin ? stats.suggestedMin - currentIdeal : currentIdeal - stats.suggestedMax;
  return distance <= halfWidth ? "review" : "recalibrate";
}

interface OrderLine {
  menuItemId: string; // Foodics product id, as stored on the weigh event
  menuItemName: string;
  modifiers: Map<string, string>; // Foodics modifier id -> name
}

export interface ParseSummary {
  totalRows: number;
  totalOrders: number;
  trustedOrders: number;
  excludedOffWeight: number;
  excludedOverride: number;
  excludedNoComposition: number;
  excludedMultiItem: number;
  excludedUnmeasured: number;
  usableSamples: number;
  brands: { brandId: number; brandCode: string }[];
}

interface RawAloneBucket { brandId: number; itemId: string; itemName: string; samples: number[] }
interface RawModifierBucket { brandId: number; itemId: string; itemName: string; modifierId: string; modifierName: string; samples: number[] }
interface RawComboBucket { brandId: number; itemId: string; itemName: string; modifierIds: string[]; modifierNames: string[]; samples: number[] }

export interface ParsedCalibrationInput {
  summary: ParseSummary;
  aloneBuckets: RawAloneBucket[];
  modifierBuckets: RawModifierBucket[];
  comboBuckets: RawComboBucket[];
}

const REQUIRED_COLUMNS = [
  "event_id", "brand_id", "brand_code", "measured_g", "verdict", "override_reason",
  "line_index", "menu_item_id", "menu_item_name", "modifier_id", "modifier_name",
];

// The other export shape Weigh History can produce: one row per ORDER, with
// the composition folded into a single items_json blob instead of tidy
// line_index/menu_item_id/... columns.
const ORDER_LEVEL_COLUMNS = ["event_id", "brand_id", "brand_code", "measured_g", "verdict", "override_reason", "items_json"];

interface WeighEventItemJson {
  menuItemId?: string | null;
  name?: string | null;
  modifiers?: { modifierId?: string | null; name?: string | null }[] | null;
}

/// Expands one "Order summary" row's items_json blob into the same tidy,
/// one-row-per-item(/modifier) shape "Item-level detail" already produces
/// for that exact same underlying composition — mirrors the backend's own
/// BuildItemLevelCsv exactly (one row per item with no modifiers; one row
/// per modifier when it has any). A row whose items_json is missing or
/// fails to parse degrades to a single "no composition recorded" row (blank
/// line_index) rather than losing that order's onweight/measured data
/// entirely — same fail-open convention the tidy export itself already uses
/// for an order Foodics couldn't resolve.
function expandOrderRow(r: Record<string, string>): Record<string, string>[] {
  const base = {
    event_id: r.event_id, brand_id: r.brand_id, brand_code: r.brand_code,
    measured_g: r.measured_g, verdict: r.verdict, override_reason: r.override_reason,
  };
  const noComposition = { ...base, line_index: "", menu_item_id: "", menu_item_name: "", modifier_id: "", modifier_name: "" };
  if (!r.items_json) return [noComposition];

  let items: WeighEventItemJson[];
  try {
    const parsed: unknown = JSON.parse(r.items_json);
    if (!Array.isArray(parsed)) return [noComposition];
    items = parsed as WeighEventItemJson[];
  } catch {
    return [noComposition];
  }
  if (items.length === 0) return [noComposition];

  const expanded: Record<string, string>[] = [];
  items.forEach((item, i) => {
    const lineIndex = String(i + 1);
    const menuItemId = item.menuItemId ?? "";
    const menuItemName = item.name ?? "";
    const mods = Array.isArray(item.modifiers) ? item.modifiers : [];
    if (mods.length === 0) {
      expanded.push({ ...base, line_index: lineIndex, menu_item_id: menuItemId, menu_item_name: menuItemName, modifier_id: "", modifier_name: "" });
    } else {
      for (const mod of mods) {
        expanded.push({
          ...base, line_index: lineIndex, menu_item_id: menuItemId, menu_item_name: menuItemName,
          modifier_id: mod.modifierId ?? "", modifier_name: mod.name ?? "",
        });
      }
    }
  });
  return expanded;
}

export function parseWeighHistoryCsv(text: string): ParsedCalibrationInput | { error: string } {
  const { header, rows: parsedRows } = parseCsvObjects(text);
  if (header.length === 0) return { error: "That file is empty." };

  // Either export shape is accepted — the underlying composition data is
  // identical either way, just tidy-columns vs. a JSON blob, so there's no
  // real reason to force a re-download over which toggle was picked.
  let rows: Record<string, string>[];
  if (REQUIRED_COLUMNS.every((c) => header.includes(c))) {
    rows = parsedRows;
  } else if (ORDER_LEVEL_COLUMNS.every((c) => header.includes(c))) {
    rows = parsedRows.flatMap(expandOrderRow);
  } else {
    const missing = REQUIRED_COLUMNS.filter((c) => !header.includes(c));
    return {
      error:
        `This doesn't look like a Weigh History export — missing column${missing.length === 1 ? "" : "s"} ` +
        `${missing.join(", ")}. Download it from Weigh History (either "Item-level detail" or ` +
        `"Order summary" both work), then upload that file.`,
    };
  }
  if (rows.length === 0) return { error: "That file has a header row but no data rows." };

  interface OrderAcc {
    brandId: number;
    brandCode: string;
    measuredG: string;
    verdict: string;
    overrideReason: string;
    lines: Map<string, OrderLine>;
  }
  const orders = new Map<string, OrderAcc>();

  for (const r of rows) {
    const eventId = r.event_id;
    if (!eventId) continue;
    let order = orders.get(eventId);
    if (!order) {
      order = {
        brandId: Number(r.brand_id) || 0,
        brandCode: r.brand_code ?? "",
        measuredG: r.measured_g,
        verdict: r.verdict ?? "",
        overrideReason: r.override_reason ?? "",
        lines: new Map(),
      };
      orders.set(eventId, order);
    }
    if (!r.line_index) continue; // "no composition recorded" row for this event
    let line = order.lines.get(r.line_index);
    if (!line) {
      line = { menuItemId: r.menu_item_id, menuItemName: r.menu_item_name || "Unnamed item", modifiers: new Map() };
      order.lines.set(r.line_index, line);
    }
    if (r.modifier_id) line.modifiers.set(r.modifier_id, r.modifier_name || "Unnamed modifier");
  }

  const summary: ParseSummary = {
    totalRows: rows.length,
    totalOrders: orders.size,
    trustedOrders: 0,
    excludedOffWeight: 0,
    excludedOverride: 0,
    excludedNoComposition: 0,
    excludedMultiItem: 0,
    excludedUnmeasured: 0,
    usableSamples: 0,
    brands: [],
  };
  const brandsSeen = new Map<number, string>();
  const aloneBuckets = new Map<string, RawAloneBucket>();
  const modifierBuckets = new Map<string, RawModifierBucket>();
  const comboBuckets = new Map<string, RawComboBucket>();

  for (const o of orders.values()) {
    if (o.brandId) brandsSeen.set(o.brandId, o.brandCode);
    const isOnWeight = o.verdict.trim().toLowerCase() === "onweight";
    const hasOverride = o.overrideReason.trim() !== "";
    if (!isOnWeight) {
      summary.excludedOffWeight++;
      continue;
    }
    if (hasOverride) {
      summary.excludedOverride++;
      continue;
    }
    summary.trustedOrders++;
    if (o.lines.size === 0) {
      summary.excludedNoComposition++;
      continue;
    }
    if (o.lines.size > 1) {
      summary.excludedMultiItem++;
      continue;
    }
    const measured = Number(o.measuredG);
    if (!o.measuredG || Number.isNaN(measured)) {
      summary.excludedUnmeasured++;
      continue;
    }

    summary.usableSamples++;
    const [line] = [...o.lines.values()];
    const modIds = [...line.modifiers.keys()];

    if (modIds.length === 0) {
      const key = `${o.brandId}:${line.menuItemId}`;
      const existing = aloneBuckets.get(key);
      if (existing) existing.samples.push(measured);
      else aloneBuckets.set(key, { brandId: o.brandId, itemId: line.menuItemId, itemName: line.menuItemName, samples: [measured] });
    } else if (modIds.length === 1) {
      const modId = modIds[0];
      const key = `${o.brandId}:${line.menuItemId}:${modId}`;
      const existing = modifierBuckets.get(key);
      if (existing) existing.samples.push(measured);
      else
        modifierBuckets.set(key, {
          brandId: o.brandId,
          itemId: line.menuItemId,
          itemName: line.menuItemName,
          modifierId: modId,
          modifierName: line.modifiers.get(modId)!,
          samples: [measured],
        });
    } else {
      const sortedIds = [...modIds].sort();
      const key = `${o.brandId}:${line.menuItemId}:${sortedIds.join(",")}`;
      const existing = comboBuckets.get(key);
      if (existing) existing.samples.push(measured);
      else
        comboBuckets.set(key, {
          brandId: o.brandId,
          itemId: line.menuItemId,
          itemName: line.menuItemName,
          modifierIds: sortedIds,
          modifierNames: sortedIds.map((id) => line.modifiers.get(id) ?? id),
          samples: [measured],
        });
    }
  }

  summary.brands = [...brandsSeen.entries()].map(([brandId, brandCode]) => ({ brandId, brandCode }));
  return {
    summary,
    aloneBuckets: [...aloneBuckets.values()],
    modifierBuckets: [...modifierBuckets.values()],
    comboBuckets: [...comboBuckets.values()],
  };
}

// --- Joining against what's currently configured, per brand -----------------

export interface BrandCatalog {
  itemsByFoodicsId: Map<string, MenuItem>;
  modifiersByFoodicsId: Map<string, Modifier>;
  combinations: ModifierCombination[];
}

export interface ItemCalibrationRow {
  kind: "item";
  brandId: number;
  brandCode: string;
  itemId: string;
  itemName: string;
  stats: CalibrationStats;
  current: { idealG: number | null; minG: number | null; maxG: number | null } | null;
  matchStatus: MatchStatus;
}

export interface ModifierCalibrationRow {
  kind: "modifier";
  brandId: number;
  brandCode: string;
  itemId: string;
  itemName: string;
  modifierId: string;
  modifierName: string;
  bundled: CalibrationStats; // item + this one modifier, as directly measured
  isolated: CalibrationStats | null; // the modifier alone, once the item's own weight is subtracted
  current: { weightG: number | null; minG: number | null; maxG: number | null } | null;
  matchStatus: MatchStatus;
}

export interface ComboCalibrationRow {
  kind: "combo";
  brandId: number;
  brandCode: string;
  itemId: string;
  itemName: string;
  modifierNames: string[];
  bundled: CalibrationStats;
  currentBasis: "combination-override" | "sum-of-individual" | "unavailable";
  current: { totalG: number | null } | null;
  matchStatus: MatchStatus;
}

function sameSet(a: number[], b: number[]): boolean {
  if (a.length !== b.length) return false;
  const sb = [...b].sort((x, y) => x - y);
  return [...a].sort((x, y) => x - y).every((v, i) => v === sb[i]);
}

export function buildItemRows(
  buckets: RawAloneBucket[],
  catalogs: Map<number, BrandCatalog>,
  brandCodeById: Map<number, string>,
): ItemCalibrationRow[] {
  return buckets.map((b) => {
    const stats = statsFromSamples(b.samples, false);
    const item = catalogs.get(b.brandId)?.itemsByFoodicsId.get(b.itemId) ?? null;
    const current = item ? { idealG: item.idealWeightG, minG: item.minWeightG, maxG: item.maxWeightG } : null;
    return {
      kind: "item",
      brandId: b.brandId,
      brandCode: brandCodeById.get(b.brandId) ?? "",
      itemId: b.itemId,
      itemName: item?.name ?? b.itemName,
      stats,
      current,
      matchStatus: matchStatusFor(current?.idealG ?? null, stats),
    };
  });
}

export function buildModifierRows(
  buckets: RawModifierBucket[],
  aloneBuckets: RawAloneBucket[],
  catalogs: Map<number, BrandCatalog>,
  brandCodeById: Map<number, string>,
): ModifierCalibrationRow[] {
  const aloneStatsByKey = new Map<string, CalibrationStats>();
  for (const a of aloneBuckets) {
    aloneStatsByKey.set(`${a.brandId}:${a.itemId}`, statsFromSamples(a.samples, false));
  }
  return buckets.map((b) => {
    const bundled = statsFromSamples(b.samples, false);
    const itemAlone = aloneStatsByKey.get(`${b.brandId}:${b.itemId}`) ?? null;
    const isolated = deriveInContext(bundled, itemAlone);
    const modifier = catalogs.get(b.brandId)?.modifiersByFoodicsId.get(b.modifierId) ?? null;
    const item = catalogs.get(b.brandId)?.itemsByFoodicsId.get(b.itemId) ?? null;
    const current = modifier ? { weightG: modifier.weightG, minG: modifier.minWeightG, maxG: modifier.maxWeightG } : null;
    const effectiveStats = isolated ?? bundled;
    return {
      kind: "modifier",
      brandId: b.brandId,
      brandCode: brandCodeById.get(b.brandId) ?? "",
      itemId: b.itemId,
      itemName: item?.name ?? b.itemName,
      modifierId: b.modifierId,
      modifierName: modifier?.name ?? b.modifierName,
      bundled,
      isolated,
      current,
      matchStatus: matchStatusFor(current?.weightG ?? null, effectiveStats),
    };
  });
}

export function buildComboRows(
  buckets: RawComboBucket[],
  catalogs: Map<number, BrandCatalog>,
  brandCodeById: Map<number, string>,
): ComboCalibrationRow[] {
  return buckets.map((b) => {
    const bundled = statsFromSamples(b.samples, false);
    const catalog = catalogs.get(b.brandId);
    const item = catalog?.itemsByFoodicsId.get(b.itemId) ?? null;
    const modifiers = b.modifierIds.map((id) => catalog?.modifiersByFoodicsId.get(id) ?? null);
    const modifierNames = modifiers.map((m, i) => m?.name ?? b.modifierNames[i]);

    let current: { totalG: number | null } | null = null;
    let currentBasis: ComboCalibrationRow["currentBasis"] = "unavailable";

    if (item && modifiers.every((m): m is Modifier => m != null)) {
      const internalIds = modifiers.map((m) => m.modifierId);
      const override = catalog?.combinations.find((c) => sameSet(c.modifierIds, internalIds)) ?? null;
      if (override) {
        currentBasis = "combination-override";
        current = { totalG: (item.idealWeightG ?? 0) + override.weightG };
      } else if (modifiers.every((m) => m.weightG != null) && item.idealWeightG != null) {
        currentBasis = "sum-of-individual";
        current = { totalG: item.idealWeightG + modifiers.reduce((s, m) => s + (m.weightG ?? 0), 0) };
      }
    }

    return {
      kind: "combo",
      brandId: b.brandId,
      brandCode: brandCodeById.get(b.brandId) ?? "",
      itemId: b.itemId,
      itemName: item?.name ?? b.itemName,
      modifierNames,
      bundled,
      currentBasis,
      current,
      matchStatus: matchStatusFor(current?.totalG ?? null, bundled),
    };
  });
}
