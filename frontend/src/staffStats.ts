// Descriptive stats for weighed-item samples. Quantiles use the same linear
// interpolation as Postgres percentile_cont, so the portal and the SQL views in
// Supabase report identical medians/percentiles for the same rows.

import type { StaffEntry } from "./staffSupabase";

export interface Summary {
  n: number;
  min: number;
  max: number;
  mean: number;
  median: number;
  sd: number;
  cv: number;
  p10: number;
  p90: number;
  q1: number;
  q3: number;
  iqr: number;
}

export function quantile(sorted: number[], p: number): number {
  if (!sorted.length) return NaN;
  const pos = (sorted.length - 1) * p;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

export function summarize(values: number[]): Summary | null {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const n = s.length;
  const mean = s.reduce((a, b) => a + b, 0) / n;
  const sd = n > 1 ? Math.sqrt(s.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1)) : 0;
  const q1 = quantile(s, 0.25);
  const q3 = quantile(s, 0.75);
  return {
    n,
    min: s[0],
    max: s[n - 1],
    mean,
    median: quantile(s, 0.5),
    sd,
    cv: mean ? (sd / mean) * 100 : 0,
    p10: quantile(s, 0.1),
    p90: quantile(s, 0.9),
    q1,
    q3,
    iqr: q3 - q1,
  };
}

export type GroupMode = "item" | "size" | "mods";

export const GROUP_MODE_LABELS: Record<GroupMode, string> = {
  item: "Item",
  size: "Item + size",
  mods: "Item + modifiers",
};

export function groupKey(e: StaffEntry, mode: GroupMode): string {
  if (mode === "item") return e.product_id;
  if (mode === "size") return `${e.product_id}|${e.size_label ?? ""}`;
  return `${e.product_id}|${e.modifiers_label}`;
}

export function groupDetail(e: StaffEntry, mode: GroupMode): string {
  if (mode === "item") return "";
  if (mode === "size") return e.size_label ?? "—";
  return e.modifiers_label || "No modifiers";
}

/** Target progress is always counted per item + size — the unit a weight target is set for. */
export const targetKey = (e: Pick<StaffEntry, "product_id" | "size_label">) => `${e.product_id}|${e.size_label ?? ""}`;

/**
 * Ids of entries outside Tukey's fences (Q1 − 1.5·IQR, Q3 + 1.5·IQR) within
 * their own group. Groups under 8 samples are left alone — too few to judge.
 */
export function outlierIds(entries: StaffEntry[], mode: GroupMode): Set<string> {
  const groups = new Map<string, StaffEntry[]>();
  for (const e of entries) {
    const k = groupKey(e, mode);
    const g = groups.get(k);
    if (g) g.push(e);
    else groups.set(k, [e]);
  }
  const out = new Set<string>();
  for (const g of groups.values()) {
    if (g.length < 8) continue;
    const s = summarize(g.map((e) => e.weight_g))!;
    const lo = s.q1 - 1.5 * s.iqr;
    const hi = s.q3 + 1.5 * s.iqr;
    for (const e of g) if (e.weight_g < lo || e.weight_g > hi) out.add(e.id);
  }
  return out;
}

/** Freedman–Diaconis bins (falls back to √n), capped to keep the chart readable. */
export function histogram(values: number[], maxBins = 30): { from: number; to: number; count: number }[] {
  if (!values.length) return [];
  const s = [...values].sort((a, b) => a - b);
  const min = s[0];
  const max = s[s.length - 1];
  if (min === max) return [{ from: min, to: max, count: s.length }];
  const iqr = quantile(s, 0.75) - quantile(s, 0.25);
  let width = iqr > 0 ? (2 * iqr) / Math.cbrt(s.length) : (max - min) / Math.sqrt(s.length);
  let bins = Math.ceil((max - min) / width);
  if (!Number.isFinite(bins) || bins < 1) bins = 1;
  if (bins > maxBins) {
    bins = maxBins;
    width = (max - min) / bins;
  }
  const out = Array.from({ length: bins }, (_, i) => ({ from: min + i * width, to: min + (i + 1) * width, count: 0 }));
  for (const v of s) out[Math.min(bins - 1, Math.floor((v - min) / width))].count++;
  return out;
}

export const g1 = (n: number) => (Number.isFinite(n) ? (Math.round(n * 10) / 10).toLocaleString(undefined, { maximumFractionDigits: 1 }) : "—");
