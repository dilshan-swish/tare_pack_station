import { useEffect, useState } from "react";
import {
  ResponsiveContainer,
  BarChart,
  Bar,
  LineChart,
  Line,
  AreaChart,
  Area,
  PieChart,
  Pie,
  Cell,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
} from "recharts";
import type { LucideIcon } from "lucide-react";
import type { AnalyticsResult, ChartSpec } from "./types";
import { statusColorFor, SEQUENTIAL_PRIMARY, CHART_GRID, CHART_AXIS_TEXT } from "./analyticsPalette";

export const CHART_GREEN = SEQUENTIAL_PRIMARY;

// Reveals `text` a chunk at a time to read like it's being generated live.
// `startAfter=false` holds it at empty until a prior typewriter (e.g. the
// headline) finishes, so headline and narrative type in sequence, not
// simultaneously. `instant` skips the animation entirely (used when
// replaying an already-known answer from History/Reports, where re-typing
// on every view would feel wrong, not delightful). Respects
// prefers-reduced-motion by showing the full text immediately either way.
export function useTypewriter(text: string, startAfter = true, instant = false) {
  const [shown, setShown] = useState(instant ? text.length : 0);
  const reduceMotion =
    typeof window !== "undefined" &&
    !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

  useEffect(() => {
    if (instant) {
      setShown(text.length);
      return;
    }
    if (!startAfter) return;
    if (reduceMotion || text.length === 0) {
      setShown(text.length);
      return;
    }
    setShown(0);
    const totalMs = Math.min(1400, Math.max(400, text.length * 10));
    const stepMs = 24;
    const steps = Math.max(1, Math.round(totalMs / stepMs));
    const perStep = Math.max(1, Math.ceil(text.length / steps));
    let i = 0;
    const timer = setInterval(() => {
      i += perStep;
      if (i >= text.length) {
        setShown(text.length);
        clearInterval(timer);
      } else {
        setShown(i);
      }
    }, stepMs);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text, startAfter, reduceMotion, instant]);

  return { text: text.slice(0, shown), done: shown >= text.length };
}

export function TypeCursor() {
  return <span className="ml-0.5 inline-block h-3.5 w-[2px] animate-pulse bg-ink align-middle" />;
}

export function ThinkingSkeleton() {
  return (
    <div className="space-y-2.5" aria-live="polite" aria-label="Generating answer">
      <div className="h-4 w-3/4 animate-shimmer rounded-md" />
      <div className="h-3 w-full animate-shimmer rounded-md" />
      <div className="h-3 w-5/6 animate-shimmer rounded-md" />
      <div className="mt-3 h-40 w-full animate-shimmer rounded-xl" />
    </div>
  );
}

// Picks the color for one series/slice by what it MEANS (colorFor), never by
// its position in the array — so "on weight" is always the same green
// whether it's series 1 or series 3 this time.
function seriesColor(chart: ChartSpec, key: string, index: number): string {
  if (chart.colorMode === "status") return statusColorFor(key);
  return index === 0 ? SEQUENTIAL_PRIMARY : statusColorFor(key);
}

// Value leads, name follows, and identity rides a short line-key rather than
// a filled box — a box at tooltip density is data-weight ink doing a
// label's job.
function ChartTooltip({
  active,
  label,
  payload,
}: {
  active?: boolean;
  label?: string;
  payload?: { name?: string; value?: number | string; color?: string }[];
}) {
  if (!active || !payload?.length) return null;
  return (
    <div className="rounded-lg border border-line bg-white px-3 py-2 text-xs card-shadow-hover">
      {label && <div className="mb-1 font-semibold text-ink">{label}</div>}
      <div className="space-y-1">
        {payload.map((p, i) => (
          <div key={i} className="flex items-center gap-2">
            {p.color && <span className="h-0.5 w-3 flex-none rounded-full" style={{ background: p.color }} />}
            <span className="text-muted">{p.name}</span>
            <span className="ml-auto font-mono font-bold text-ink">{p.value}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// A legend is always present for 2+ series — the dependable identity
// channel, so a reader never has to color-match unaided. A single series
// needs no legend box: the chart's own title already says what's plotted.
function ChartLegend({
  items,
  shape,
}: {
  items: { key: string; label: string; color: string }[];
  shape: "line" | "rect";
}) {
  if (items.length < 2) return null;
  return (
    <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs text-muted">
      {items.map((it) => (
        <span key={it.key} className="flex items-center gap-1.5">
          {shape === "line" ? (
            <span className="h-0.5 w-3.5 flex-none rounded-full" style={{ background: it.color }} />
          ) : (
            <span className="h-2.5 w-2.5 flex-none rounded-[3px]" style={{ background: it.color }} />
          )}
          {it.label}
        </span>
      ))}
    </div>
  );
}

const axisTick = { fontSize: 11, fill: CHART_AXIS_TEXT };

// Recharts v3's ResponsiveContainer sizes itself from its FIRST
// ResizeObserver callback, fired the instant it mounts. That's reliable when
// a chart mounts into already-settled layout (the Ask page's staged
// headline→narrative→chart reveal gives the browser several animation
// frames to lay out the card before any chart appears) — but when several
// charts mount together into DOM inserted all at once (History and Reports
// render everything instantly, with `animate=false`), the first container
// can be observed before that whole insert has finished reflowing and
// measures a too-small box it then never corrects (ResizeObserver only
// fires again on a REAL subsequent size change, and a too-small box that
// never grows on its own triggers no such change). Delaying the chart's own
// mount by two animation frames — one for layout, one for the browser to
// actually paint it — means ResponsiveContainer's first measurement always
// lands after the surrounding layout has settled, at the cost of a couple
// milliseconds nobody perceives as a delay.
function useChartMountReady(): boolean {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let raf2 = 0;
    let timer = 0;
    const raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => {
        timer = window.setTimeout(() => setReady(true), 50);
      });
    });
    return () => {
      cancelAnimationFrame(raf1);
      cancelAnimationFrame(raf2);
      clearTimeout(timer);
    };
  }, []);
  return ready;
}

export function ChartRenderer({ chart }: { chart: ChartSpec }) {
  const ready = useChartMountReady();
  const many = chart.data.length > 5;
  const legendItems = chart.series.map((s, i) => ({ key: s.key, label: s.label, color: seriesColor(chart, s.key, i) }));

  if (chart.type === "pie") {
    return <DonutChart chart={chart} />;
  }

  if (!ready) {
    return <div className="mt-4 h-64 w-full animate-shimmer rounded-xl sm:h-72" />;
  }

  return (
    <div>
      <div className="mt-4 h-64 w-full sm:h-72">
        <ResponsiveContainer width="100%" height="100%">
          {chart.type === "area" ? (
            <AreaChart data={chart.data} margin={{ top: 8, right: 12, left: 0, bottom: many ? 28 : 8 }}>
              <CartesianGrid stroke={CHART_GRID} vertical={false} />
              <XAxis
                dataKey={chart.xKey}
                tick={axisTick}
                tickLine={false}
                axisLine={{ stroke: CHART_GRID }}
                interval={0}
                angle={many ? -25 : 0}
                textAnchor={many ? "end" : "middle"}
                height={many ? 44 : 24}
                padding={{ left: 16, right: 16 }}
              />
              <YAxis tick={axisTick} tickLine={false} axisLine={false} width={38} />
              <Tooltip
                content={<ChartTooltip />}
                cursor={{ stroke: SEQUENTIAL_PRIMARY, strokeWidth: 1 }}
              />
              {chart.series.map((s, i) => {
                const color = seriesColor(chart, s.key, i);
                return (
                  <Area
                    key={s.key}
                    type="monotone"
                    dataKey={s.key}
                    name={s.label}
                    stroke={color}
                    strokeWidth={2}
                    fill={color}
                    fillOpacity={0.1}
                    dot={false}
                    activeDot={{ r: 4, fill: color, stroke: "#fff", strokeWidth: 2 }}
                  />
                );
              })}
            </AreaChart>
          ) : chart.type === "line" ? (
            <LineChart data={chart.data} margin={{ top: 8, right: 12, left: 0, bottom: many ? 28 : 8 }}>
              <CartesianGrid stroke={CHART_GRID} vertical={false} />
              <XAxis
                dataKey={chart.xKey}
                tick={axisTick}
                tickLine={false}
                axisLine={{ stroke: CHART_GRID }}
                interval={0}
                angle={many ? -25 : 0}
                textAnchor={many ? "end" : "middle"}
                height={many ? 44 : 24}
                padding={{ left: 16, right: 16 }}
              />
              <YAxis tick={axisTick} tickLine={false} axisLine={false} width={38} />
              <Tooltip content={<ChartTooltip />} cursor={{ stroke: CHART_AXIS_TEXT, strokeWidth: 1 }} />
              {chart.series.map((s, i) => {
                const color = seriesColor(chart, s.key, i);
                return (
                  <Line
                    key={s.key}
                    type="monotone"
                    dataKey={s.key}
                    name={s.label}
                    stroke={color}
                    strokeWidth={2}
                    dot={{ r: 4, fill: color, stroke: "#fff", strokeWidth: 2 }}
                    activeDot={{ r: 5, fill: color, stroke: "#fff", strokeWidth: 2 }}
                  />
                );
              })}
            </LineChart>
          ) : (
            <BarChart
              data={chart.data}
              margin={{ top: 8, right: 12, left: 0, bottom: many ? 28 : 8 }}
              barGap={2}
              barCategoryGap="24%"
            >
              <CartesianGrid stroke={CHART_GRID} vertical={false} />
              <XAxis
                dataKey={chart.xKey}
                tick={axisTick}
                tickLine={false}
                axisLine={{ stroke: CHART_GRID }}
                interval={0}
                angle={many ? -25 : 0}
                textAnchor={many ? "end" : "middle"}
                height={many ? 44 : 24}
                padding={{ left: 16, right: 16 }}
              />
              <YAxis tick={axisTick} tickLine={false} axisLine={false} width={38} />
              <Tooltip content={<ChartTooltip />} cursor={{ fill: "rgba(74,139,201,0.08)" }} />
              {chart.series.map((s, i) => (
                <Bar
                  key={s.key}
                  dataKey={s.key}
                  name={s.label}
                  radius={[4, 4, 0, 0]}
                  fill={seriesColor(chart, s.key, i)}
                  maxBarSize={24}
                />
              ))}
            </BarChart>
          )}
        </ResponsiveContainer>
      </div>
      <ChartLegend items={legendItems} shape={chart.type === "bar" ? "rect" : "line"} />
    </div>
  );
}

// Part-to-whole at a glance, capped at 4 segments (this dashboard's outcomes
// — on/under/over/unconfigured — never exceed that) with a center total, the
// closest visual match to a single ratio a bar can't express as intuitively.
function DonutChart({ chart }: { chart: ChartSpec }) {
  const ready = useChartMountReady();
  const valueKey = chart.series[0]?.key ?? "value";
  const total = chart.data.reduce((sum, row) => {
    const v = row[valueKey];
    return sum + (typeof v === "number" ? v : 0);
  }, 0);
  const legendItems = chart.data.map((row) => {
    const name = String(row[chart.xKey] ?? "");
    return { key: name, label: name, color: statusColorFor(name) };
  });

  if (!ready) {
    return <div className="mt-4 h-64 w-full animate-shimmer rounded-xl sm:h-72" />;
  }

  return (
    <div>
      <div className="relative mt-4 h-64 w-full sm:h-72">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie
              data={chart.data}
              dataKey={valueKey}
              nameKey={chart.xKey}
              innerRadius="62%"
              outerRadius="90%"
              paddingAngle={2}
              stroke="#fff"
              strokeWidth={2}
            >
              {chart.data.map((row, i) => (
                <Cell key={i} fill={statusColorFor(String(row[chart.xKey] ?? ""))} />
              ))}
            </Pie>
            <Tooltip content={<ChartTooltip />} />
          </PieChart>
        </ResponsiveContainer>
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="font-mono text-3xl font-bold text-ink">{total.toLocaleString()}</span>
          <span className="text-xs font-semibold uppercase tracking-wide text-muted">
            {chart.series[0]?.label ?? "Total"}
          </span>
        </div>
      </div>
      <ChartLegend items={legendItems} shape="rect" />
    </div>
  );
}

export function DataTable({
  columns,
  rows,
  maxRows,
}: {
  columns: string[];
  rows: Record<string, string | number | null>[];
  maxRows?: number;
}) {
  const shown = maxRows ? rows.slice(0, maxRows) : rows;
  return (
    <div className="mt-4">
      <div className="max-h-72 overflow-auto rounded-xl border border-line">
        <table className="w-full text-left text-sm">
          <thead className="sticky top-0 border-b border-line bg-cream text-xs font-semibold uppercase tracking-wide text-muted">
            <tr>
              {columns.map((c) => (
                <th key={c} className="whitespace-nowrap px-3 py-2.5">
                  {c}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-line">
            {shown.map((r, i) => (
              <tr key={i} className="transition-colors duration-150 hover:bg-black/[0.03]">
                {columns.map((c) => (
                  <td key={c} className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">
                    {r[c] ?? <span className="text-muted">—</span>}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {maxRows && rows.length > maxRows && (
        <p className="mt-1.5 text-xs text-muted">
          Showing the first {maxRows} of {rows.length} rows.
        </p>
      )}
    </div>
  );
}

// Compact icon-badge stat tile with an inline sparkline — the KPI-row
// treatment: one glanceable value, a signed delta vs the start of the range,
// and a 12-point trend line in the same hue as the tile's accent.
export function StatTile({
  icon: Icon,
  tint,
  label,
  value,
  trend,
  trendColor,
}: {
  icon: LucideIcon;
  tint: string;
  label: string;
  value: string;
  trend?: number[];
  trendColor?: string;
}) {
  return (
    <div className="rounded-2xl border border-line bg-white p-4 card-shadow">
      <div className="flex items-start justify-between gap-2">
        <span className={`flex h-9 w-9 flex-none items-center justify-center rounded-full ${tint}`}>
          <Icon size={17} strokeWidth={2} />
        </span>
        {trend && trend.length > 1 && <Sparkline points={trend} color={trendColor ?? SEQUENTIAL_PRIMARY} />}
      </div>
      <div className="mt-3 text-xs font-semibold uppercase tracking-wide text-muted">{label}</div>
      <div className="mt-0.5 font-mono text-2xl font-bold text-ink">{value}</div>
    </div>
  );
}

function Sparkline({ points, color }: { points: number[]; color: string }) {
  const w = 56;
  const h = 24;
  const min = Math.min(...points);
  const max = Math.max(...points);
  const range = max - min || 1;
  const step = w / Math.max(1, points.length - 1);
  const path = points
    .map((p, i) => {
      const x = i * step;
      const y = h - ((p - min) / range) * (h - 4) - 2;
      return `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");
  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} className="flex-none" aria-hidden="true">
      <path d={path} fill="none" stroke={color} strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

// Renders one answered question — headline, narrative, caveat, chart(s),
// table. `animate=false` (History/Reports) shows everything instantly, since
// replaying the "generating" effect on content you've already seen once
// reads as a bug, not a delight.
export function AnswerBody({
  result,
  animate = true,
  maxTableRows,
}: {
  result: AnalyticsResult;
  animate?: boolean;
  maxTableRows?: number;
}) {
  const headline = useTypewriter(result.headline, true, !animate);
  const narrative = useTypewriter(result.narrative, headline.done, !animate);

  return (
    <div>
      <p className="font-display text-base leading-snug text-ink">
        {headline.text}
        {!headline.done && <TypeCursor />}
      </p>
      <p className="mt-2 text-sm leading-relaxed text-muted">
        {narrative.text}
        {headline.done && !narrative.done && <TypeCursor />}
      </p>
      {narrative.done && (
        <div className={animate ? "animate-fade-up" : ""}>
          {result.caveat && (
            <div className="mt-3 rounded-lg border border-amber/40 bg-amber/10 px-3 py-2 text-xs text-ink">
              <span className="font-semibold">Note: </span>
              {result.caveat}
            </div>
          )}
          {result.chart && <ChartRenderer chart={result.chart} />}
          {result.secondaryChart && (
            <div className="mt-6 border-t border-line pt-4">
              {result.secondaryChartTitle && (
                <div className="text-sm font-bold text-ink">{result.secondaryChartTitle}</div>
              )}
              <ChartRenderer chart={result.secondaryChart} />
            </div>
          )}
          {result.table && result.table.length > 0 && result.tableColumns && (
            <DataTable columns={result.tableColumns} rows={result.table} maxRows={maxTableRows} />
          )}
        </div>
      )}
    </div>
  );
}
