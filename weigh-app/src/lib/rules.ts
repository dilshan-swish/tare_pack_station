import type { ApiLine, ApiModifier, ApiOrder, AppSettings, FocusItem, ItemProgress, Unit } from "./types";

/** Letters only, upper-case — the same normalisation the database trigger uses. */
const lettersOnly = (s: string) => s.replace(/[^A-Za-z]/g, "").toUpperCase();
const normName = (s: string) => s.trim().replace(/\s+/g, " ").toLowerCase();

/**
 * The size of a meal/combo (REGULAR / MEDIUM / SUUUBER) from its modifiers, or
 * null for items that don't come in sizes. Display only — the stored value is
 * computed by the database from the same alias table.
 */
export function sizeLabelFor(modifiers: ApiModifier[], settings: AppSettings): string | null {
  const sorted = [...modifiers].sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  for (const m of sorted) {
    const hit = settings.size_aliases[lettersOnly(m.name)];
    if (hit) return hit;
  }
  return null;
}

/** Lines staff aren't asked to weigh: staff meals, drinks, merch and near-free add-ons. */
export function isSkippedLine(line: ApiLine, settings: AppSettings): boolean {
  const cat = line.category?.trim().toLowerCase();
  if (cat && settings.skip_categories.some((c) => c.trim().toLowerCase() === cat)) return true;
  return line.price !== null && line.price > 0 && line.price <= settings.skip_price_at_or_below;
}

export function unitKey(orderId: string, lineKey: string, unitIndex: number): string {
  return `${orderId}|${lineKey}|${unitIndex}`;
}

/** Every weighable physical unit in an order, in receipt order. */
export function unitsOf(order: ApiOrder, settings: AppSettings): Unit[] {
  const units: Unit[] = [];
  for (const line of order.lines) {
    if (isSkippedLine(line, settings)) continue;
    const sizeLabel = sizeLabelFor(line.modifiers, settings);
    for (let i = 0; i < line.quantity; i++) {
      units.push({
        key: unitKey(order.id, line.key, i),
        order,
        line,
        unitIndex: i,
        unitCount: line.quantity,
        sizeLabel,
      });
    }
  }
  return units;
}

export function skippedCount(order: ApiOrder, settings: AppSettings): number {
  return order.lines.filter((l) => isSkippedLine(l, settings)).reduce((n, l) => n + l.quantity, 0);
}

export const progressKey = (productId: string, size: string | null) => `${productId}|${size ?? ""}`;

/** The most urgent focus entry that applies to this unit at this branch, if any. */
export function focusFor(unit: Unit, focus: FocusItem[], branchId: string): FocusItem | null {
  let best: FocusItem | null = null;
  for (const f of focus) {
    if (!f.is_active) continue;
    if (f.branch_id && f.branch_id !== branchId) continue;
    const sameProduct = f.product_id
      ? f.product_id === unit.line.productId
      : normName(f.product_name) === normName(unit.line.productName);
    if (!sameProduct) continue;
    if (f.size_label && f.size_label !== unit.sizeLabel) continue;
    if (!best || f.priority > best.priority) best = f;
  }
  return best;
}

export type WeightCheck =
  | { kind: "invalid"; message: string }
  | { kind: "unusual"; message: string }
  | { kind: "ok" };

/** Parses what staff typed ("245", "245.5", "245,5", " 245 g"). */
export function parseWeight(input: string): number | null {
  const cleaned = input.trim().replace(/\s*g(rams?)?$/i, "").replace(",", ".");
  if (!/^\d+(\.\d+)?$/.test(cleaned)) return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? Math.round(n * 10) / 10 : null;
}

/**
 * Hard limits reject the entry; an "unusual" result asks staff to double-check
 * (catches 2450 typed for 245) once there are enough samples to know what's
 * normal for this item and size.
 */
export function checkWeight(
  input: string,
  settings: AppSettings,
  progress: ItemProgress | undefined,
): { value: number | null; check: WeightCheck } {
  if (!input.trim()) return { value: null, check: { kind: "invalid", message: "Enter the weight in grams." } };
  if (/^\s*-/.test(input)) return { value: null, check: { kind: "invalid", message: "A weight can't be negative." } };
  const value = parseWeight(input);
  if (value === null) return { value: null, check: { kind: "invalid", message: "Numbers only — e.g. 245 or 245.5" } };
  if (value < settings.min_weight_g || value > settings.max_weight_g) {
    return {
      value,
      check: {
        kind: "invalid",
        message: `Must be between ${fmt(settings.min_weight_g)} g and ${fmt(settings.max_weight_g)} g.`,
      },
    };
  }
  if (progress && progress.samples >= 8 && progress.median_g && progress.p10_g && progress.p90_g) {
    const low = Math.min(progress.p10_g * 0.55, progress.median_g * 0.45);
    const high = Math.max(progress.p90_g * 1.8, progress.median_g * 2.2);
    const usual = `${fmt(progress.p10_g)}–${fmt(progress.p90_g)} g`;
    if (value > high) {
      return { value, check: { kind: "unusual", message: `${fmt(value)} g is much heavier than usual for this item (${usual}).` } };
    }
    if (value < low) {
      return { value, check: { kind: "unusual", message: `${fmt(value)} g is much lighter than usual for this item (${usual}).` } };
    }
  }
  return { value, check: { kind: "ok" } };
}

export function fmt(n: number): string {
  return Number.isInteger(n) ? n.toLocaleString("en-US") : n.toLocaleString("en-US", { maximumFractionDigits: 1 });
}
