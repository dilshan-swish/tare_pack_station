import type { ApiOrder } from "./types";

/** "19:42" in the business's own time zone, whatever the device is set to. */
export function clock(iso: string | null | undefined, timeZone: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  try {
    return new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hour12: false }).format(d);
  } catch {
    return d.toTimeString().slice(0, 5);
  }
}

export function ago(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "";
  const mins = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins} min ago`;
  const h = Math.floor(mins / 60);
  return `${h}h ${mins % 60}m ago`;
}

/** yyyy-mm-dd business day, counting hours before the cutoff toward the previous day. */
export function businessDate(timeZone: string, cutoffHour: number, at = new Date(), dayOffset = 0): string {
  const shifted = new Date(at.getTime() - cutoffHour * 3600_000 + dayOffset * 86_400_000);
  try {
    const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(shifted);
    const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
    return `${get("year")}-${get("month")}-${get("day")}`;
  } catch {
    return shifted.toISOString().slice(0, 10);
  }
}

/** "18:00" from a Postgres time "18:00:00". */
export const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : "");

/** Where "now" sits relative to a daily session window (handles windows past midnight). */
export function sessionState(
  start: string | null,
  end: string | null,
  timeZone: string,
  now = new Date(),
): { label: string; live: boolean } | null {
  if (!start || !end) return null;
  const toMin = (t: string) => {
    const [h, m] = t.split(":").map(Number);
    return h * 60 + (m || 0);
  };
  const nowStr = clock(now.toISOString(), timeZone);
  const n = toMin(nowStr);
  const s = toMin(start);
  const e = toMin(end);
  const within = s <= e ? n >= s && n < e : n >= s || n < e;
  const span = `${hhmm(start)}–${hhmm(end)}`;
  if (within) return { label: `Session now · ${span}`, live: true };
  let until = s - n;
  if (until < 0) until += 24 * 60;
  const h = Math.floor(until / 60);
  const m = until % 60;
  return { label: `Session ${span} · starts in ${h ? `${h}h ` : ""}${m}m`, live: false };
}

/** The big staff-facing number: the aggregator's own number when there is one. */
export function orderHeadline(o: ApiOrder): { label: string | null; number: string } {
  if (o.aggregatorName) {
    return { label: o.aggregatorName, number: o.aggregatorRef ? `#${o.aggregatorRef}` : `Order ${o.number ?? ""}`.trim() };
  }
  if (o.number !== null) return { label: null, number: `Order ${o.number}` };
  if (o.reference) return { label: null, number: `#${o.reference}` };
  return { label: null, number: o.customerLabel ?? "Order" };
}

/** The secondary line: POS order number + check number (what's on the receipt). */
export function orderSubline(o: ApiOrder): string {
  const bits: string[] = [];
  if (o.aggregatorName && o.number !== null) bits.push(`Order ${o.number}`);
  if (!o.aggregatorName && o.customerLabel) bits.push(o.customerLabel);
  if (o.checkNumber !== null) bits.push(`Check# ${o.checkNumber}`);
  return bits.join(" · ");
}

export type AggregatorTone = { bg: string; fg: string };

export function aggregatorTone(name: string | null): AggregatorTone {
  const n = (name ?? "").toLowerCase();
  if (n.includes("keeta")) return { bg: "#FFD84D", fg: "#161B14" };
  if (n.includes("talabat")) return { bg: "#FF6A1F", fg: "#FFFFFF" };
  if (n.includes("deliveroo")) return { bg: "#00CCBC", fg: "#161B14" };
  if (n.includes("jahez")) return { bg: "#E0263D", fg: "#FFFFFF" };
  if (n.includes("careem")) return { bg: "#1FAE5B", fg: "#FFFFFF" };
  return { bg: "#161B14", fg: "#F6F1E3" };
}
