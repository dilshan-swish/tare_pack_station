import type { ReactNode } from "react";

export function StatTile({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div className="rounded-2xl border border-line bg-white p-4 card-shadow">
      <div className="text-xs font-semibold uppercase tracking-wide text-muted">{label}</div>
      <div className="mt-1 font-mono text-2xl font-bold text-ink">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-muted">{sub}</div>}
    </div>
  );
}

export function ProgressBar({ value, max }: { value: number; max: number }) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  const done = value >= max;
  return (
    <div className="h-2 w-full min-w-[4rem] overflow-hidden rounded-full bg-black/[0.06]" role="progressbar" aria-valuenow={value} aria-valuemax={max}>
      <div className={`h-full rounded-full ${done ? "bg-green" : "bg-[#4a8bc9]"}`} style={{ width: `${pct}%` }} />
    </div>
  );
}

export type SortDir = "asc" | "desc";

export function SortTh<K extends string>({
  k,
  label,
  sort,
  onSort,
  align = "left",
}: {
  k: K;
  label: string;
  sort: { key: K; dir: SortDir };
  onSort: (k: K) => void;
  align?: "left" | "right";
}) {
  const active = sort.key === k;
  return (
    <th className={`whitespace-nowrap p-0 ${align === "right" ? "text-right" : "text-left"}`} aria-sort={active ? (sort.dir === "asc" ? "ascending" : "descending") : "none"}>
      <button
        type="button"
        onClick={() => onSort(k)}
        className={`flex min-h-[40px] w-full items-center gap-1 px-3 py-2 text-xs font-semibold uppercase tracking-wide ${
          align === "right" ? "justify-end" : ""
        } ${active ? "text-ink" : "text-muted hover:text-ink"}`}
      >
        {label}
        <span aria-hidden className={active ? "text-green" : "opacity-30"}>
          {active ? (sort.dir === "asc" ? "↑" : "↓") : "↕"}
        </span>
      </button>
    </th>
  );
}


export function ChartTip({
  active,
  label,
  payload,
  formatLabel,
}: {
  active?: boolean;
  label?: string | number;
  payload?: { name?: string; value?: number | string; color?: string; payload?: Record<string, unknown> }[];
  formatLabel?: (l: string | number | undefined, p?: Record<string, unknown>) => string;
}) {
  if (!active || !payload?.length) return null;
  const head = formatLabel ? formatLabel(label, payload[0]?.payload) : label;
  return (
    <div className="rounded-lg border border-line bg-white px-3 py-2 text-xs card-shadow-hover">
      {head !== undefined && head !== "" && <div className="mb-1 font-semibold text-ink">{head}</div>}
      {payload.map((p, i) => (
        <div key={i} className="flex items-center gap-2">
          {p.color && <span className="h-0.5 w-3 flex-none rounded-full" style={{ background: p.color }} />}
          <span className="text-muted">{p.name}</span>
          <span className="ml-auto font-mono font-bold text-ink">{p.value}</span>
        </div>
      ))}
    </div>
  );
}
