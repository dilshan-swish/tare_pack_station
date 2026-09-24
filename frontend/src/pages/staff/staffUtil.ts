import { useEffect, useState } from "react";
import { sb } from "../../staffSupabase";
import { CHART_AXIS_TEXT } from "../../analyticsPalette";

/** yyyy-mm-dd business day in the business's timezone (hours before the cutoff count toward the day before). */
export function businessDateOf(at: Date, timeZone: string, cutoffHour: number): string {
  const shifted = new Date(at.getTime() - cutoffHour * 3600_000);
  try {
    const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(shifted);
    const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
    return `${get("year")}-${get("month")}-${get("day")}`;
  } catch {
    return shifted.toISOString().slice(0, 10);
  }
}

export function fmtDateTime(iso: string | null | undefined, timeZone: string): string {
  if (!iso) return "—";
  try {
    return new Intl.DateTimeFormat(undefined, {
      timeZone,
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }).format(new Date(iso));
  } catch {
    return iso;
  }
}

export function shortDay(ymd: string): string {
  const [y, m, d] = ymd.split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export interface ProgressRow {
  product_id: string;
  product_name: string;
  size_label: string | null;
  samples: number;
}

/** Company-wide, all-time sample counts per item + size (independent of the page's filters). */
export function useAllTimeProgress(tick: number): { map: Map<string, ProgressRow>; error: string | null } {
  const [map, setMap] = useState<Map<string, ProgressRow>>(new Map());
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    sb()
      .rpc("get_item_progress")
      .then(({ data, error: err }) => {
        if (cancelled) return;
        if (err) return setError(err.message);
        const m = new Map<string, ProgressRow>();
        for (const r of (data ?? []) as ProgressRow[]) {
          m.set(`${r.product_id}|${r.size_label ?? ""}`, { ...r, samples: Number(r.samples) });
        }
        setMap(m);
        setError(null);
      });
    return () => {
      cancelled = true;
    };
  }, [tick]);
  return { map, error };
}


export const axisTick = { fill: CHART_AXIS_TEXT, fontSize: 11, fontFamily: "ui-monospace, monospace" };
