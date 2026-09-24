import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  Search,
  X,
  Download,
  ChevronLeft,
  ChevronRight,
  ListTree,
  ScatterChart,
  ZoomIn,
  ZoomOut,
  RotateCcw,
  ArrowUp,
  ArrowDown,
  ArrowUpDown,
  FileSpreadsheet,
  FileText,
} from "lucide-react";
import { api, ApiError } from "../api";
import type {
  BrandSummary,
  WeighEventEntry,
  WeighHistoryRow,
  WeighHistoryVerdictCounts,
  WeighScatterPoint,
  WeighScatterResult,
} from "../types";
import {
  Card,
  Badge,
  Banner,
  Spinner,
  Button,
  ButtonSpinner,
  TogglePill,
  DateRangeFilter,
  resolvePresetRange,
  BrandBranchPicker,
  toggledStrSet,
  Select,
  Modal,
  OrderBreakdownModal,
  NumberInput,
  type RangePresetKey,
  type BranchLoadState,
} from "../ui";

const VERDICT_OPTIONS: { value: string; label: string }[] = [
  { value: "onweight", label: "On weight" },
  { value: "under", label: "Under" },
  { value: "over", label: "Over" },
  { value: "unconfigured", label: "Unconfigured" },
];

const PAGE_SIZE_OPTIONS = ["10", "25", "50", "100"];

/// One clickable, sortable column header. Click cycles: not sorted → this
/// column's default direction → the other direction → back to that same
/// default (never "unsorted" once picked — a table with no sort applied at
/// all is a confusing state to return a person to by accident, and the
/// column can always be abandoned by simply clicking a different one).
/// The whole header cell is one button (not just the label) so the tap
/// target is comfortably above the 44×44px minimum on a touchscreen, not a
/// few pixels of text plus a tiny separate arrow icon.
function SortableTh({
  sortKey,
  active,
  dir,
  onSort,
  align = "left",
  className = "",
}: {
  sortKey: SortKey;
  active: boolean;
  dir: SortDir;
  onSort: (key: SortKey) => void;
  align?: "left" | "right";
  className?: string;
}) {
  const { label } = SORT_COLUMNS[sortKey];
  return (
    <th className={`whitespace-nowrap p-0 ${className}`}>
      <button
        type="button"
        onClick={() => onSort(sortKey)}
        className={`flex min-h-[38px] w-full items-center gap-1 px-3 py-2.5 text-left transition-colors ${
          align === "right" ? "justify-end" : "justify-start"
        } ${active ? "text-ink" : "text-muted hover:text-ink"}`}
        aria-label={`Sort by ${label}${active ? `, currently ${dir === "asc" ? "ascending" : "descending"} — click to reverse` : ""}`}
      >
        {align === "right" && <SortIcon active={active} dir={dir} />}
        <span>{label}</span>
        {align === "left" && <SortIcon active={active} dir={dir} />}
      </button>
    </th>
  );
}

function SortIcon({ active, dir }: { active: boolean; dir: SortDir }) {
  if (!active) return <ArrowUpDown size={12} className="shrink-0 opacity-30" />;
  return dir === "asc" ? (
    <ArrowUp size={12} className="shrink-0 text-green" />
  ) : (
    <ArrowDown size={12} className="shrink-0 text-green" />
  );
}

function verdictTone(v: string): "ok" | "bad" | "warn" | "neutral" {
  const s = v.toLowerCase();
  if (s === "onweight") return "ok";
  if (s === "under") return "bad";
  if (s === "over") return "warn";
  return "neutral";
}

function verdictLabel(v: string): string {
  const s = v.toLowerCase();
  if (s === "onweight") return "On weight";
  if (s === "under") return "Under";
  if (s === "over") return "Over";
  return v || "Unknown";
}

// Text color matching the same tone the Verdict badge itself uses (see
// Badge's own tone map in ui.tsx) — so a glance at the Deviation column's
// color already agrees with the Verdict column right next to it, rather than
// inventing a second, unrelated color scheme for the same underlying fact.
const DEVIATION_TONE_CLASS: Record<"ok" | "bad" | "warn" | "neutral", string> = {
  ok: "text-oktext",
  bad: "text-badtext",
  warn: "text-[#8a5a10]",
  neutral: "text-muted",
};

/// measured − the midpoint of [expectedMin, expectedMax] — identical
/// definition to deviationOf(WeighScatterPoint) below and to the backend's
/// own DeviationOf, just null-safe for a table row where any of the three
/// inputs may be missing (most commonly an unconfigured verdict, which never
/// got a real expected range or measurement to compare).
function rowDeviation(r: WeighHistoryRow): number | null {
  if (r.expectedMinG == null || r.expectedMaxG == null || r.measuredG == null) return null;
  return r.measuredG - (r.expectedMinG + r.expectedMaxG) / 2;
}

// Every column the Weigh History table can be sorted by — kept as one source
// of truth so the header row, the sort-cycling logic, and the API params can
// never drift out of sync with each other. `numeric` picks each column's
// sensible first click direction: a number/date starts at its most useful
// extreme (newest date, biggest overshoot/shortfall) — descending — while a
// text column starts alphabetically — ascending.
const SORT_COLUMNS = {
  weighedAt: { label: "Weighed at", numeric: true },
  branch: { label: "Brand · Branch", numeric: false },
  device: { label: "Device", numeric: false },
  expected: { label: "Expected", numeric: true },
  measured: { label: "Measured", numeric: true },
  deviation: { label: "Deviation", numeric: true },
  verdict: { label: "Verdict", numeric: false },
  overrideReason: { label: "Override reason", numeric: false },
} as const;
type SortKey = keyof typeof SORT_COLUMNS;
type SortDir = "asc" | "desc";

function fmtG(g: number | null): string {
  return g == null ? "—" : `${g}g`;
}

function fmtDateTime(iso: string): string {
  const d = new Date(iso.endsWith("Z") ? iso : iso + "Z");
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

interface SelectedItem {
  menuItemId: number;
  name: string;
  brandCode: string;
}

/// Search-as-you-type item picker — orders containing ANY of the selected
/// items will match. Scoped to whichever brands currently have a branch
/// selected (all brands, if none do yet), so results never include an item
/// from a catalog the rest of the filter has already excluded.
function ItemFilterPicker({
  brands,
  activeBrandIds,
  selected,
  onAdd,
  onRemove,
}: {
  brands: BrandSummary[];
  activeBrandIds: number[];
  selected: SelectedItem[];
  onAdd: (item: SelectedItem) => void;
  onRemove: (menuItemId: number) => void;
}) {
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState<SelectedItem[] | "loading" | null>(null);
  const [searchError, setSearchError] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const reqId = useRef(0);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2) {
      setResults(null);
      setSearchError(null);
      return;
    }
    const id = ++reqId.current;
    setResults("loading");
    const targetBrandIds = activeBrandIds.length > 0 ? activeBrandIds : brands.map((b) => b.brandId);
    const timer = setTimeout(() => {
      (async () => {
        try {
          const perBrand = await Promise.all(
            targetBrandIds.map(async (brandId) => {
              const brand = brands.find((b) => b.brandId === brandId);
              try {
                const items = await api.items(brandId, q);
                return items
                  .filter((it) => !selected.some((s) => s.menuItemId === it.menuItemId))
                  .map((it) => ({ menuItemId: it.menuItemId, name: it.name, brandCode: brand?.code ?? "" }));
              } catch {
                return []; // one brand's search failing shouldn't blank out the others
              }
            }),
          );
          if (id !== reqId.current) return; // a newer keystroke already superseded this
          setResults(perBrand.flat().slice(0, 30));
          setSearchError(null);
        } catch (e) {
          if (id !== reqId.current) return;
          setResults(null);
          setSearchError(e instanceof ApiError ? e.message : "Couldn't search items.");
        }
      })();
    }, 300);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query, activeBrandIds.join(","), brands.length]);

  return (
    <div>
      <div className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted">
        Items{selected.length > 0 ? ` (${selected.length} selected)` : ""}
      </div>
      <div ref={rootRef} className="relative max-w-sm">
        <div className="relative">
          <Search size={14} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" />
          <input
            type="text"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setOpen(true);
            }}
            onFocus={() => setOpen(true)}
            placeholder="Search items — e.g. Toasts Duo Combo"
            className="w-full rounded-lg border border-line bg-white py-2 pl-8 pr-3 text-sm outline-none transition focus:border-green focus:ring-2 focus:ring-green/20"
          />
        </div>
        {open && query.trim().length >= 2 && (
          <div className="animate-pop-in absolute left-0 right-0 z-20 mt-1.5 max-h-64 overflow-y-auto rounded-xl border border-line bg-white p-1.5 card-shadow-hover">
            {results === "loading" ? (
              <div className="p-3 text-center text-xs text-muted">Searching…</div>
            ) : searchError ? (
              <div className="p-3 text-xs text-badtext">{searchError}</div>
            ) : !results || results.length === 0 ? (
              <div className="p-3 text-xs text-muted">No matching items.</div>
            ) : (
              results.map((r) => (
                <button
                  key={r.menuItemId}
                  type="button"
                  onClick={() => {
                    onAdd(r);
                    setQuery("");
                    setResults(null);
                  }}
                  className="flex w-full items-center justify-between gap-2 rounded-lg px-2.5 py-2 text-left text-sm transition-colors hover:bg-black/[0.04]"
                >
                  <span className="truncate text-ink">{r.name}</span>
                  {r.brandCode && (
                    <span className="flex-none font-mono text-[10px] text-muted">{r.brandCode}</span>
                  )}
                </button>
              ))
            )}
          </div>
        )}
      </div>
      {selected.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {selected.map((s) => (
            <span
              key={s.menuItemId}
              className="flex items-center gap-1.5 rounded-full border border-green bg-green/10 py-1 pl-2.5 pr-1.5 text-xs font-semibold text-green"
            >
              {s.name}
              {s.brandCode && <span className="font-mono text-[10px] text-green/70">{s.brandCode}</span>}
              <button
                type="button"
                onClick={() => onRemove(s.menuItemId)}
                aria-label={`Remove ${s.name} from item filter`}
                className="rounded-full p-0.5 text-green/70 transition-colors hover:bg-green/20 hover:text-green"
              >
                <X size={12} />
              </button>
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

/// Fetches one event's full detail on demand (a row here only ever carries a
/// flat item-name summary, per WeighHistoryRowDto — see the backend comment
/// on why) and shows it in the same breakdown modal the per-device dashboard
/// uses. A small loading/error state fills the gap between the click and the
/// fetch resolving, so opening this is never a silent no-op or a raw crash
/// on a flaky connection.
function BreakdownViewer({
  eventId,
  brandId,
  onClose,
}: {
  eventId: number;
  brandId: number | null;
  onClose: () => void;
}) {
  const [detail, setDetail] = useState<WeighEventEntry | "loading" | "error">("loading");

  useEffect(() => {
    let cancelled = false;
    setDetail("loading");
    api
      .weighEvent(eventId)
      .then((e) => {
        if (!cancelled) setDetail(e);
      })
      .catch(() => {
        if (!cancelled) setDetail("error");
      });
    return () => {
      cancelled = true;
    };
  }, [eventId]);

  if (detail === "loading") {
    return (
      <Modal open onClose={onClose} title="Order breakdown">
        <Spinner />
      </Modal>
    );
  }
  if (detail === "error") {
    return (
      <Modal open onClose={onClose} title="Order breakdown">
        <Banner tone="bad">Couldn't load this order's breakdown. Check your connection and try again.</Banner>
        <div className="mt-4 flex justify-end">
          <Button onClick={onClose}>Close</Button>
        </div>
      </Modal>
    );
  }
  return <OrderBreakdownModal weigh={detail} brandId={brandId} onClose={onClose} />;
}

const VERDICT_TILES: {
  key: keyof Omit<WeighHistoryVerdictCounts, "total">;
  label: string;
  barClass: string;
  tileClass: string;
  textClass: string;
}[] = [
  { key: "onWeight", label: "On weight", barClass: "bg-green", tileClass: "bg-okbg", textClass: "text-oktext" },
  { key: "under", label: "Under", barClass: "bg-coral", tileClass: "bg-badbg", textClass: "text-badtext" },
  { key: "over", label: "Over", barClass: "bg-amber", tileClass: "bg-warnbg", textClass: "text-[#8a5a10]" },
  {
    key: "unconfigured",
    label: "Unconfigured",
    barClass: "bg-muted",
    tileClass: "bg-black/[0.04]",
    textClass: "text-muted",
  },
];

/// Small, "illustrative" verdict-breakdown tiles — count + percentage + a
/// thin fill bar per verdict, matching the same tones used everywhere else
/// in the portal for these four states (see Badge/verdictTone). Tracks every
/// active filter exactly (branches, verdict, items, item count, date range —
/// see WeighHistoryVerdictCounts' own comment), so this always describes
/// precisely what's on screen: if only "Over" is ticked in Verdict, these
/// tiles correctly show 100% Over rather than some separately-scoped
/// "overall" number. Renders nothing until the first successful load, rather
/// than a misleading flash of all-zero tiles.
function VerdictSummaryTiles({ counts }: { counts: WeighHistoryVerdictCounts | null }) {
  if (!counts) return null;
  const total = counts.total;
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      {VERDICT_TILES.map((tile) => {
        const count = counts[tile.key];
        const pct = total > 0 ? Math.round((count / total) * 100) : null;
        return (
          <div key={tile.key} className={`rounded-xl p-3 ${tile.tileClass}`}>
            <div className="flex items-baseline justify-between gap-2">
              <span className={`text-xs font-semibold uppercase tracking-wide ${tile.textClass}`}>
                {tile.label}
              </span>
              <span className={`font-mono text-xs font-bold ${tile.textClass}`}>
                {pct === null ? "—" : `${pct}%`}
              </span>
            </div>
            <div className={`mt-1 font-mono text-2xl font-bold ${tile.textClass}`}>
              {count.toLocaleString()}
            </div>
            <div
              className="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-black/10"
              role="progressbar"
              aria-label={`${tile.label}: ${count.toLocaleString()} of ${total.toLocaleString()}${
                pct === null ? "" : ` (${pct}%)`
              }`}
              aria-valuenow={pct ?? 0}
              aria-valuemin={0}
              aria-valuemax={100}
            >
              <div
                className={`h-full rounded-full transition-all duration-500 ${tile.barClass}`}
                style={{ width: `${pct ?? 0}%` }}
              />
            </div>
          </div>
        );
      })}
    </div>
  );
}

// --- Expected-vs-Measured scatter chart ------------------------------------
// Verdict identity is deliberately never color-alone: green/coral/amber read
// as too close together for a protan/deutan viewer (checked against this
// app's own existing badge colors), so each verdict also gets its own marker
// SHAPE — the fix stays local to this one chart rather than touching the
// app-wide badge palette everywhere else.

type MarkerShape = "circle" | "square" | "triangle" | "diamond";

const VERDICT_MARKERS: Record<string, { shape: MarkerShape; color: string; label: string }> = {
  onweight: { shape: "circle", color: "#2f8f5b", label: "On weight" },
  under: { shape: "square", color: "#e8604c", label: "Under" },
  over: { shape: "triangle", color: "#f3a93b", label: "Over" },
  unconfigured: { shape: "diamond", color: "#5c6b62", label: "Unconfigured" },
};
const FALLBACK_MARKER = { shape: "circle" as MarkerShape, color: "#8a938d", label: "Other" };

function markerFor(verdict: string) {
  return VERDICT_MARKERS[verdict.toLowerCase()] ?? FALLBACK_MARKER;
}

function expectedMidpoint(p: WeighScatterPoint): number {
  return (p.expectedMinG + p.expectedMaxG) / 2;
}

function deviationOf(p: WeighScatterPoint): number {
  return p.measuredG - expectedMidpoint(p);
}

function fmtSignedG(n: number): string {
  const r = Math.round(n);
  return `${r >= 0 ? "+" : ""}${r.toLocaleString()}g`;
}

/// A handful of evenly-spaced, human-friendly axis ticks (1/2/5×10^n steps) —
/// never crashes on a degenerate (zero-width or non-finite) domain, which a
/// single-point or all-identical-values chart would otherwise produce.
function niceTicks(min: number, max: number, count = 5): number[] {
  if (!Number.isFinite(min) || !Number.isFinite(max) || max <= min) return [Math.round(min)];
  const rawStep = (max - min) / count;
  const mag = Math.pow(10, Math.floor(Math.log10(rawStep)));
  const norm = rawStep / mag;
  const step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
  const start = Math.ceil(min / step) * step;
  const ticks: number[] = [];
  for (let t = start; t <= max + step * 0.001; t += step) ticks.push(Math.round(t));
  return ticks.length > 0 ? ticks : [Math.round(min)];
}

interface DeviationStats {
  n: number;
  mean: number;
  meanAbs: number;
  rmse: number;
  maxAbs: number;
}

function computeDeviationStats(points: WeighScatterPoint[]): DeviationStats | null {
  const n = points.length;
  if (n === 0) return null;
  const deviations = points.map(deviationOf);
  const mean = deviations.reduce((a, b) => a + b, 0) / n;
  const meanAbs = deviations.reduce((a, b) => a + Math.abs(b), 0) / n;
  const rmse = Math.sqrt(deviations.reduce((a, b) => a + b * b, 0) / n);
  const maxAbs = deviations.reduce((a, b) => Math.max(a, Math.abs(b)), 0);
  return { n, mean, meanAbs, rmse, maxAbs };
}

function DeviationStatTiles({ stats }: { stats: DeviationStats }) {
  const tiles = [
    { label: "Points plotted", value: stats.n.toLocaleString() },
    { label: "Mean deviation", value: fmtSignedG(stats.mean) },
    { label: "Mean abs. deviation", value: `${Math.round(stats.meanAbs).toLocaleString()}g` },
    { label: "RMSE", value: `${Math.round(stats.rmse).toLocaleString()}g` },
    { label: "Max deviation", value: `${Math.round(stats.maxAbs).toLocaleString()}g` },
  ];
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
      {tiles.map((t) => (
        <div key={t.label} className="rounded-xl border border-line bg-black/[0.02] p-3">
          <div className="text-[11px] font-semibold uppercase tracking-wide text-muted">{t.label}</div>
          <div className="mt-1 font-mono text-lg font-bold text-ink">{t.value}</div>
        </div>
      ))}
    </div>
  );
}

/// One marker shape, drawn at (cx, cy). `dataIdx`, when given, tags the
/// element for the chart's single delegated mouse-move handler below — a
/// legend swatch omits it since it isn't hoverable.
function ShapeMark({
  cx,
  cy,
  r,
  shape,
  color,
  dataIdx,
}: {
  cx: number;
  cy: number;
  r: number;
  shape: MarkerShape;
  color: string;
  dataIdx?: number;
}) {
  const common: Record<string, unknown> = {
    fill: color,
    fillOpacity: 0.72,
    stroke: shape === "triangle" ? "#8a5a10" : color,
    strokeOpacity: 0.9,
    strokeWidth: 1,
  };
  if (dataIdx !== undefined) common["data-idx"] = dataIdx;
  if (shape === "circle") return <circle cx={cx} cy={cy} r={r} {...common} />;
  if (shape === "square") return <rect x={cx - r} y={cy - r} width={r * 2} height={r * 2} {...common} />;
  if (shape === "triangle")
    return (
      <polygon
        points={`${cx},${cy - r * 1.15} ${cx - r * 1.15},${cy + r} ${cx + r * 1.15},${cy + r}`}
        {...common}
      />
    );
  return (
    <polygon
      points={`${cx},${cy - r * 1.25} ${cx + r * 1.25},${cy} ${cx},${cy + r * 1.25} ${cx - r * 1.25},${cy}`}
      {...common}
    />
  );
}

function ScatterLegend() {
  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
      {Object.values(VERDICT_MARKERS).map((m) => (
        <div key={m.label} className="flex items-center gap-1.5 text-xs font-semibold text-ink">
          <svg width={12} height={12} viewBox="0 0 12 12" aria-hidden focusable="false">
            <ShapeMark cx={6} cy={6} r={4} shape={m.shape} color={m.color} />
          </svg>
          {m.label}
        </div>
      ))}
    </div>
  );
}

// --- Zoom/pan geometry ------------------------------------------------------
// X and Y each get their own independent visible range (not locked together)
// — completely normal for exploring a scatter once zoomed, and the only way
// to "zoom into" a cluster that's dense on one axis but not the other. The
// y=x guide line is still drawn correctly at any zoom level (see its own
// comment below): it marks the actual expected=measured locus, not a fixed
// 45° diagonal, so it stays meaningful regardless of aspect.

interface ScatterView {
  xMin: number;
  xMax: number;
  yMin: number;
  yMax: number;
}

// Never let a zoom shrink a span smaller than this — an arbitrarily tight
// zoom on real (integer-gram) data stops being meaningful, and this also
// keeps every scale/inverse-scale calculation safely away from dividing by
// (near) zero.
const MIN_SPAN_G = 10;

function clampSpan(span: number, fullSpan: number): number {
  const floor = Math.min(MIN_SPAN_G, fullSpan);
  return Math.min(Math.max(span, floor), fullSpan);
}

/// Slides [lo, hi] back inside [fullLo, fullHi] (preserving its span) if it
/// drifted out during a pan/zoom; snaps to the full range outright if the
/// span has grown to cover it. Never lets panning/zooming wander into empty
/// space with nothing plottable in view.
function clampRange(lo: number, hi: number, fullLo: number, fullHi: number): [number, number] {
  const span = hi - lo;
  const fullSpan = fullHi - fullLo;
  if (span >= fullSpan) return [fullLo, fullHi];
  let a = lo;
  let b = hi;
  if (a < fullLo) {
    b += fullLo - a;
    a = fullLo;
  }
  if (b > fullHi) {
    a -= b - fullHi;
    b = fullHi;
  }
  return [a, b];
}

/// Zooms `view` by `factor` (<1 zooms in, >1 zooms out) independently on
/// each axis, keeping the data-space point (anchorX, anchorY) fixed under
/// the cursor/pinch-midpoint — the standard "zoom toward where you're
/// pointing" feel. Always clamped back within `full`, so this can never
/// escape into a broken or empty-looking state.
function zoomView(view: ScatterView, full: ScatterView, anchorX: number, anchorY: number, factor: number): ScatterView {
  const newSpanX = clampSpan((view.xMax - view.xMin) * factor, full.xMax - full.xMin);
  const newSpanY = clampSpan((view.yMax - view.yMin) * factor, full.yMax - full.yMin);
  const relX = (anchorX - view.xMin) / (view.xMax - view.xMin);
  const relY = (anchorY - view.yMin) / (view.yMax - view.yMin);
  const [xMin, xMax] = clampRange(anchorX - relX * newSpanX, anchorX - relX * newSpanX + newSpanX, full.xMin, full.xMax);
  const [yMin, yMax] = clampRange(anchorY - relY * newSpanY, anchorY - relY * newSpanY + newSpanY, full.yMin, full.yMax);
  return { xMin, xMax, yMin, yMax };
}

function panView(view: ScatterView, full: ScatterView, dataDx: number, dataDy: number): ScatterView {
  const [xMin, xMax] = clampRange(view.xMin - dataDx, view.xMax - dataDx, full.xMin, full.xMax);
  const [yMin, yMax] = clampRange(view.yMin + dataDy, view.yMax + dataDy, full.yMin, full.yMax);
  return { xMin, xMax, yMin, yMax };
}

function viewsEqual(a: ScatterView, b: ScatterView): boolean {
  const eps = 1e-6;
  return (
    Math.abs(a.xMin - b.xMin) < eps &&
    Math.abs(a.xMax - b.xMax) < eps &&
    Math.abs(a.yMin - b.yMin) < eps &&
    Math.abs(a.yMax - b.yMax) < eps
  );
}

const CHART_WIDTH = 640;
const CHART_HEIGHT = 400;
const CHART_MARGIN_LEFT = 58;
const CHART_MARGIN_BOTTOM = 40;
const CHART_MARGIN_TOP = 16;
const CHART_MARGIN_RIGHT = 16;
const PLOT_WIDTH = CHART_WIDTH - CHART_MARGIN_LEFT - CHART_MARGIN_RIGHT;
const PLOT_HEIGHT = CHART_HEIGHT - CHART_MARGIN_TOP - CHART_MARGIN_BOTTOM;

/// The scatter itself. A hand-rolled inline SVG (no charting library) sized
/// by viewBox so it scales with its container; the outer wrapper adds a
/// horizontal-scroll safety net with a floor width, so on a narrow phone the
/// axis labels/legend never get squeezed down to unreadable rather than just
/// scrolling — the same pattern this page already uses for its data table.
///
/// Zoom/pan: mouse wheel and pinch zoom toward the cursor/pinch midpoint;
/// click-drag or a single touch pans; double-click/double-tap or the reset
/// button returns to the full view. Built on Pointer Events (not separate
/// mouse/touch handlers) so one code path drives mouse, touch, and pen —
/// each active pointer is tracked by id, one pointer pans, two pinch-zoom.
/// `touch-action: none` on the SVG hands touch gestures entirely to this
/// code instead of fighting the browser's own scroll/zoom over the wheel
/// listener's passive-by-default restriction, which is instead why the
/// wheel handler itself is attached natively (see the effect below) rather
/// than via onWheel — React cannot mark that one non-passive.
function ExpectedVsMeasuredChart({
  points,
  onSelectPoint,
}: {
  points: WeighScatterPoint[];
  onSelectPoint: (point: WeighScatterPoint) => void;
}) {
  const svgRef = useRef<SVGSVGElement | null>(null);

  const fullDomain = useMemo((): ScatterView => {
    const allValues = points.flatMap((p) => [p.expectedMinG, p.expectedMaxG, p.measuredG]);
    const rawMin = Math.min(...allValues);
    const rawMax = Math.max(...allValues);
    const pad = Math.max((rawMax - rawMin) * 0.08, 5);
    let lo = Math.max(0, Math.floor(rawMin - pad));
    let hi = Math.ceil(rawMax + pad);
    if (hi <= lo) {
      // A single point, or every value identical — force a small, sane span
      // rather than a degenerate zero-width domain.
      lo = Math.max(0, lo - 10);
      hi = lo + 20;
    }
    return { xMin: lo, xMax: hi, yMin: lo, yMax: hi };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [points]);

  const [view, setView] = useState<ScatterView>(fullDomain);
  const isZoomed = !viewsEqual(view, fullDomain);

  const scaleX = (v: number) => CHART_MARGIN_LEFT + ((v - view.xMin) / (view.xMax - view.xMin)) * PLOT_WIDTH;
  const scaleY = (v: number) =>
    CHART_MARGIN_TOP + PLOT_HEIGHT - ((v - view.yMin) / (view.yMax - view.yMin)) * PLOT_HEIGHT;

  const xTicks = niceTicks(view.xMin, view.xMax, 5);
  const yTicks = niceTicks(view.yMin, view.yMax, 5);

  // Only markers actually inside the current view are drawn — with up to
  // 5,000 points, rendering (and hit-testing) the ones scrolled out of view
  // after zooming in would just be wasted work. `data-idx` indexes this
  // filtered array, not the original `points`, so the hover lookup below
  // always matches what's actually on screen.
  const markers = useMemo(
    () =>
      points
        .map((p) => ({ point: p, x: expectedMidpoint(p), y: p.measuredG }))
        .filter((m) => m.x >= view.xMin && m.x <= view.xMax && m.y >= view.yMin && m.y <= view.yMax)
        .map((m) => ({ point: m.point, cx: scaleX(m.x), cy: scaleY(m.y), ...markerFor(m.point.verdict) })),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [points, view],
  );

  const [hover, setHover] = useState<{ idx: number; clientX: number; clientY: number } | null>(null);
  const pointersRef = useRef<Map<number, { x: number; y: number }>>(new Map());
  const dragRef = useRef<
    | { mode: "pan"; lastX: number; lastY: number }
    | { mode: "pinch"; startDist: number; startView: ScatterView }
    | null
  >(null);

  // A tap (pointerdown -> pointerup on a marker with barely any movement in
  // between) opens that order's breakdown — tracked separately from `hover`
  // and `dragRef` so a real pan/zoom gesture that merely starts on top of a
  // marker never accidentally opens it. `idx` is null when the gesture didn't
  // start on a marker at all, in which case it's never a click candidate.
  const tapRef = useRef<{ idx: number | null; downX: number; downY: number } | null>(null);
  const TAP_MAX_MOVEMENT_PX = 6;

  /// Real screen pixels -> this SVG's own viewBox units — needed because the
  /// element's on-screen size (phone vs. desktop, or just window width) is
  /// almost never literally 640×400; every pointer/wheel coordinate has to
  /// go through this before it means anything in chart space.
  function toViewBoxPoint(clientX: number, clientY: number): { x: number; y: number } | null {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect || rect.width === 0 || rect.height === 0) return null;
    return {
      x: (clientX - rect.left) * (CHART_WIDTH / rect.width),
      y: (clientY - rect.top) * (CHART_HEIGHT / rect.height),
    };
  }

  function dataAnchorAt(svgX: number, svgY: number, v: ScatterView) {
    return {
      x: v.xMin + ((svgX - CHART_MARGIN_LEFT) / PLOT_WIDTH) * (v.xMax - v.xMin),
      y: v.yMin + ((CHART_MARGIN_TOP + PLOT_HEIGHT - svgY) / PLOT_HEIGHT) * (v.yMax - v.yMin),
    };
  }

  function applyZoomAtClient(clientX: number, clientY: number, factor: number, base?: ScatterView) {
    const svgPt = toViewBoxPoint(clientX, clientY);
    if (!svgPt) return;
    setView((current) => {
      const from = base ?? current;
      const anchor = dataAnchorAt(svgPt.x, svgPt.y, from);
      return zoomView(from, fullDomain, anchor.x, anchor.y, factor);
    });
  }

  // Wheel needs a real (non-passive) listener to reliably preventDefault —
  // React's synthetic onWheel can silently fail to stop page scroll here.
  useEffect(() => {
    const svg = svgRef.current;
    if (!svg) return;
    function onWheel(e: WheelEvent) {
      e.preventDefault();
      const factor = e.deltaY > 0 ? 1.15 : 1 / 1.15;
      applyZoomAtClient(e.clientX, e.clientY, factor);
    }
    svg.addEventListener("wheel", onWheel, { passive: false });
    return () => svg.removeEventListener("wheel", onWheel);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fullDomain]);

  function handlePointerDown(e: React.PointerEvent<SVGSVGElement>) {
    try {
      (e.target as Element).setPointerCapture?.(e.pointerId);
    } catch {
      // A handful of browsers/input paths can reject capture for a pointer
      // id they don't (yet) recognize as active. Dragging still works fine
      // from the plain move/up events either way — capture is just extra
      // robustness against the pointer leaving the element mid-drag, not a
      // requirement — so this must never abort the gesture entirely.
    }
    pointersRef.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    setHover(null);
    if (pointersRef.current.size === 1) {
      dragRef.current = { mode: "pan", lastX: e.clientX, lastY: e.clientY };
      const idxAttr = (e.target as SVGElement).getAttribute("data-idx");
      tapRef.current = {
        idx: idxAttr == null ? null : Number(idxAttr),
        downX: e.clientX,
        downY: e.clientY,
      };
    } else if (pointersRef.current.size === 2) {
      const [a, b] = Array.from(pointersRef.current.values());
      dragRef.current = { mode: "pinch", startDist: Math.hypot(a.x - b.x, a.y - b.y), startView: view };
      // A second finger landing mid-gesture makes this a pinch, never a tap.
      tapRef.current = null;
    }
  }

  function handlePointerMove(e: React.PointerEvent<SVGSVGElement>) {
    if (pointersRef.current.has(e.pointerId)) {
      pointersRef.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    }
    const drag = dragRef.current;
    if (!drag) {
      // Plain hover (no button/finger down) — delegated via data-idx so this
      // one handler covers every marker regardless of how many are drawn.
      const idxAttr = (e.target as SVGElement).getAttribute("data-idx");
      if (idxAttr == null) {
        setHover((h) => (h ? null : h));
        return;
      }
      setHover({ idx: Number(idxAttr), clientX: e.clientX, clientY: e.clientY });
      return;
    }
    if (drag.mode === "pan") {
      if (
        tapRef.current &&
        Math.hypot(e.clientX - tapRef.current.downX, e.clientY - tapRef.current.downY) > TAP_MAX_MOVEMENT_PX
      ) {
        // Moved too far to still be a tap — this is a genuine pan, so the
        // gesture must never also open a breakdown when the pointer lifts.
        tapRef.current = null;
      }
      const rect = svgRef.current?.getBoundingClientRect();
      if (rect && rect.width > 0 && rect.height > 0) {
        const dxSvg = (e.clientX - drag.lastX) * (CHART_WIDTH / rect.width);
        const dySvg = (e.clientY - drag.lastY) * (CHART_HEIGHT / rect.height);
        setView((v) => {
          const dataDx = (dxSvg / PLOT_WIDTH) * (v.xMax - v.xMin);
          const dataDy = (dySvg / PLOT_HEIGHT) * (v.yMax - v.yMin);
          return panView(v, fullDomain, dataDx, dataDy);
        });
      }
      dragRef.current = { mode: "pan", lastX: e.clientX, lastY: e.clientY };
    } else if (drag.mode === "pinch" && pointersRef.current.size >= 2) {
      const [a, b] = Array.from(pointersRef.current.values());
      const dist = Math.hypot(a.x - b.x, a.y - b.y);
      if (dist > 0 && drag.startDist > 0) {
        applyZoomAtClient((a.x + b.x) / 2, (a.y + b.y) / 2, drag.startDist / dist, drag.startView);
      }
    }
  }

  function handlePointerUp(e: React.PointerEvent<SVGSVGElement>) {
    pointersRef.current.delete(e.pointerId);
    if (pointersRef.current.size === 0) {
      dragRef.current = null;
      // Resolve the tap (if any) only once every finger/button has lifted —
      // otherwise the first finger up during a still-active pinch would
      // wrongly fire a click.
      const tap = tapRef.current;
      tapRef.current = null;
      if (tap && tap.idx != null) {
        const marker = markers[tap.idx];
        if (marker) onSelectPoint(marker.point);
      }
    } else {
      const [[, pos]] = Array.from(pointersRef.current.entries());
      dragRef.current = { mode: "pan", lastX: pos.x, lastY: pos.y };
    }
  }

  function resetZoom() {
    setView(fullDomain);
  }

  /// The zoom buttons narrow toward whatever's currently centered in view
  /// (not a fixed point), so repeated clicks keep drilling into wherever the
  /// person has already panned/zoomed to, rather than jumping back to the
  /// middle of the full domain each time.
  function zoomByButton(factor: number) {
    setView((v) => zoomView(v, fullDomain, (v.xMin + v.xMax) / 2, (v.yMin + v.yMax) / 2, factor));
  }

  const hoveredMarker = hover ? markers[hover.idx] : null;

  // The expected=measured guide line, clipped to whatever portion of it
  // actually falls inside the current view — X and Y ranges can differ once
  // zoomed, so this is genuinely absent (not drawn at all) rather than
  // misleading whenever the visible rectangle doesn't intersect the true
  // diagonal at all.
  const diagLo = Math.max(view.xMin, view.yMin);
  const diagHi = Math.min(view.xMax, view.yMax);
  const showDiagonal = diagHi > diagLo;

  return (
    <div className="relative">
      <div className="no-scrollbar overflow-x-auto rounded-xl border border-line bg-white p-2">
        <div className="relative" style={{ minWidth: 560 }}>
          <svg
            ref={svgRef}
            viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`}
            style={{
              touchAction: "none",
              cursor: dragRef.current?.mode === "pan" ? "grabbing" : hover ? "pointer" : "grab",
            }}
            className="w-full select-none"
            role="img"
            aria-label={`Scatter chart plotting expected versus measured weight for ${points.length.toLocaleString()} orders. Click a point to view its order breakdown. Scroll, pinch, or use the zoom buttons to zoom; drag to pan.`}
            onPointerDown={handlePointerDown}
            onPointerMove={handlePointerMove}
            onPointerUp={handlePointerUp}
            onPointerCancel={handlePointerUp}
            onPointerLeave={() => {
              if (!dragRef.current) setHover(null);
            }}
            onDoubleClick={resetZoom}
          >
            {xTicks.map((t) => (
              <line
                key={`gx-${t}`}
                x1={scaleX(t)}
                y1={CHART_MARGIN_TOP}
                x2={scaleX(t)}
                y2={CHART_MARGIN_TOP + PLOT_HEIGHT}
                stroke="#e7e9e5"
                strokeWidth={1}
              />
            ))}
            {yTicks.map((t) => (
              <line
                key={`gy-${t}`}
                x1={CHART_MARGIN_LEFT}
                y1={scaleY(t)}
                x2={CHART_MARGIN_LEFT + PLOT_WIDTH}
                y2={scaleY(t)}
                stroke="#e7e9e5"
                strokeWidth={1}
              />
            ))}

            {/* y = x reference line — a guide, not data, so it stays recessive */}
            {showDiagonal && (
              <line
                x1={scaleX(diagLo)}
                y1={scaleY(diagLo)}
                x2={scaleX(diagHi)}
                y2={scaleY(diagHi)}
                stroke="#17211b"
                strokeOpacity={0.32}
                strokeWidth={1.5}
                strokeDasharray="5 4"
              />
            )}

            {xTicks.map((t) => (
              <text
                key={`xt-${t}`}
                x={scaleX(t)}
                y={CHART_MARGIN_TOP + PLOT_HEIGHT + 18}
                textAnchor="middle"
                fontSize={12}
                fill="#5c6b62"
                fontFamily="ui-monospace, monospace"
              >
                {t.toLocaleString()}
              </text>
            ))}
            {yTicks.map((t) => (
              <text
                key={`yt-${t}`}
                x={CHART_MARGIN_LEFT - 8}
                y={scaleY(t) + 4}
                textAnchor="end"
                fontSize={12}
                fill="#5c6b62"
                fontFamily="ui-monospace, monospace"
              >
                {t.toLocaleString()}
              </text>
            ))}

            <text
              x={CHART_MARGIN_LEFT + PLOT_WIDTH / 2}
              y={CHART_HEIGHT - 4}
              textAnchor="middle"
              fontSize={12}
              fontWeight={700}
              fill="#17211b"
            >
              Expected (g)
            </text>
            <text
              x={16}
              y={CHART_MARGIN_TOP + PLOT_HEIGHT / 2}
              textAnchor="middle"
              fontSize={12}
              fontWeight={700}
              fill="#17211b"
              transform={`rotate(-90, 16, ${CHART_MARGIN_TOP + PLOT_HEIGHT / 2})`}
            >
              Measured (g)
            </text>

            {markers.map((m, i) => (
              <ShapeMark key={m.point.eventId} cx={m.cx} cy={m.cy} r={4.2} shape={m.shape} color={m.color} dataIdx={i} />
            ))}
          </svg>

          {/* Zoom controls — overlaid, always available regardless of input
              device (wheel/pinch aren't discoverable or possible for every
              user/pointer type). */}
          <div className="pointer-events-none absolute right-2 top-2 flex flex-col gap-1">
            <button
              type="button"
              onClick={() => zoomByButton(1 / 1.4)}
              aria-label="Zoom in"
              title="Zoom in"
              className="pointer-events-auto flex h-7 w-7 items-center justify-center rounded-lg border border-line bg-white text-ink shadow-sm transition hover:bg-black/[0.04]"
            >
              <ZoomIn size={14} />
            </button>
            <button
              type="button"
              onClick={() => zoomByButton(1.4)}
              aria-label="Zoom out"
              title="Zoom out"
              className="pointer-events-auto flex h-7 w-7 items-center justify-center rounded-lg border border-line bg-white text-ink shadow-sm transition hover:bg-black/[0.04]"
            >
              <ZoomOut size={14} />
            </button>
            {isZoomed && (
              <button
                type="button"
                onClick={resetZoom}
                aria-label="Reset zoom"
                title="Reset zoom"
                className="pointer-events-auto flex h-7 w-7 items-center justify-center rounded-lg border border-ink bg-ink text-cream shadow-sm transition hover:bg-green-dark"
              >
                <RotateCcw size={14} />
              </button>
            )}
          </div>
        </div>
      </div>

      <p className="mt-1.5 text-center text-[11px] text-muted">
        Click a point for its order breakdown · scroll or pinch to zoom · drag to pan · double-click to reset
      </p>

      {hoveredMarker &&
        createPortal(
          <div
            className="pointer-events-none fixed z-[100] max-w-[230px] rounded-lg border-2 border-ink bg-white px-3 py-2 text-xs card-shadow"
            style={{ left: hover!.clientX + 14, top: hover!.clientY + 14 }}
          >
            <div className="font-mono font-bold text-ink">Order #{hoveredMarker.point.eventId}</div>
            <div className="mt-1 text-muted">
              Expected {Math.round(hoveredMarker.point.expectedMinG).toLocaleString()}–
              {Math.round(hoveredMarker.point.expectedMaxG).toLocaleString()}g
            </div>
            <div className="text-muted">Measured {Math.round(hoveredMarker.point.measuredG).toLocaleString()}g</div>
            <div className="text-muted">Deviation {fmtSignedG(deviationOf(hoveredMarker.point))}</div>
            <div className="mt-1 font-semibold" style={{ color: hoveredMarker.color }}>
              {markerFor(hoveredMarker.point.verdict).label}
            </div>
            <div className="mt-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted/70">
              Click for order breakdown
            </div>
          </div>,
          document.body,
        )}
    </div>
  );
}

/// Fetches the scatter data once (the filters at the moment the button was
/// clicked) and renders loading/error/empty/chart states — same "never a
/// blank screen" shape as BreakdownViewer above. Deliberately a snapshot,
/// not live: this is opened as a deliberate "show me this" action, not a
/// panel that should keep refetching while someone is busy reading a chart.
function ScatterChartModal({
  filterParams,
  onClose,
  onSelectPoint,
}: {
  filterParams: Parameters<typeof api.weighScatter>[0];
  onClose: () => void;
  onSelectPoint: (point: WeighScatterPoint) => void;
}) {
  const [result, setResult] = useState<WeighScatterResult | "loading" | "error">("loading");
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setResult("loading");
    api
      .weighScatter(filterParams)
      .then((r) => {
        if (!cancelled) setResult(r);
      })
      .catch((e) => {
        if (cancelled) return;
        setErrorMsg(
          e instanceof ApiError ? e.message : "Couldn't load chart data. Check your connection and try again.",
        );
        setResult("error");
      });
    return () => {
      cancelled = true;
    };
    // Intentionally only the params captured at open time — see the comment above.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const stats = result !== "loading" && result !== "error" ? computeDeviationStats(result.points) : null;

  return (
    <Modal open onClose={onClose} title="Expected vs Measured" entrance="turn" maxWidth="max-w-4xl">
      {result === "loading" ? (
        <div className="py-10">
          <Spinner />
        </div>
      ) : result === "error" ? (
        <>
          <Banner tone="bad">{errorMsg}</Banner>
          <div className="mt-4 flex justify-end">
            <Button onClick={onClose}>Close</Button>
          </div>
        </>
      ) : result.points.length === 0 ? (
        <>
          <p className="py-8 text-center text-sm text-muted">
            No plottable orders match these filters
            {result.excluded > 0
              ? ` — ${result.excluded.toLocaleString()} matched but had no expected range or measured weight recorded.`
              : "."}
          </p>
          <div className="flex justify-end">
            <Button onClick={onClose}>Close</Button>
          </div>
        </>
      ) : (
        <div className="space-y-4">
          <p className="text-sm text-muted">
            <span className="font-mono font-bold text-ink">{result.plotted.toLocaleString()}</span> order
            {result.plotted === 1 ? "" : "s"} plotted
            {result.excluded > 0 && (
              <>
                {" "}
                · {result.excluded.toLocaleString()} excluded (no expected range or measured weight recorded)
              </>
            )}
          </p>
          {stats && <DeviationStatTiles stats={stats} />}
          <ExpectedVsMeasuredChart points={result.points} onSelectPoint={onSelectPoint} />
          <ScatterLegend />
          <div className="flex justify-end">
            <Button onClick={onClose}>Close</Button>
          </div>
        </div>
      )}
    </Modal>
  );
}

export function WeighHistoryPage() {
  const [brands, setBrands] = useState<BrandSummary[]>([]);
  const [brandsError, setBrandsError] = useState<string | null>(null);
  const [branchesByBrand, setBranchesByBrand] = useState<Record<number, BranchLoadState>>({});
  const [selectionByBrand, setSelectionByBrand] = useState<Record<number, Set<number>>>({});
  const [openBrandId, setOpenBrandId] = useState<number | null>(null);
  const [selectedVerdicts, setSelectedVerdicts] = useState<Set<string>>(new Set());
  const [selectedItems, setSelectedItems] = useState<SelectedItem[]>([]);
  // Raw text, not a number — so an in-progress edit (a momentarily empty
  // field, a stray character) never has to round-trip through a coerced
  // numeric value. Validated below; only a clean whole number ever reaches
  // the API.
  const [itemCountInput, setItemCountInput] = useState("");
  const [rangePreset, setRangePreset] = useState<RangePresetKey>("30d");
  const [customFrom, setCustomFrom] = useState("");
  const [customTo, setCustomTo] = useState("");
  const [format, setFormat] = useState<"orders" | "items">("orders");
  const [fileType, setFileType] = useState<"csv" | "xlsx">("csv");

  const [sortBy, setSortBy] = useState<SortKey>("weighedAt");
  const [sortDir, setSortDir] = useState<SortDir>("desc");

  /// Click-to-sort: a fresh column jumps straight to its own default
  /// direction; clicking the ALREADY-active column reverses it instead.
  function toggleSort(key: SortKey) {
    if (sortBy === key) {
      setSortDir((d) => (d === "asc" ? "desc" : "asc"));
    } else {
      setSortBy(key);
      setSortDir(SORT_COLUMNS[key].numeric ? "desc" : "asc");
    }
  }

  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState("25");

  // Which event's full breakdown is currently open, if any — from either the
  // table's own row or a clicked scatter-chart point, both of which only
  // ever carry a brandCode; resolved back to a numeric brandId via the
  // already-loaded `brands` list so the breakdown modal can fetch that
  // brand's live catalog the same way the per-device dashboard does.
  const [viewingEvent, setViewingEvent] = useState<{ eventId: number; brandCode: string | null } | null>(
    null,
  );
  const viewingBrandId = viewingEvent
    ? (brands.find((b) => b.code === viewingEvent.brandCode)?.brandId ?? null)
    : null;

  const [rows, setRows] = useState<WeighHistoryRow[]>([]);
  const [totalCount, setTotalCount] = useState<number | null>(null);
  // Kept across a load error (not reset to null) so a transient failure
  // doesn't blank a summary that was showing good data a moment ago — it's
  // just hidden while loadError is set, same as the table itself.
  const [verdictCounts, setVerdictCounts] = useState<WeighHistoryVerdictCounts | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [downloading, setDownloading] = useState(false);
  const [downloadError, setDownloadError] = useState<string | null>(null);
  const [showScatter, setShowScatter] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        setBrands(await api.brands());
      } catch (e) {
        setBrandsError(e instanceof ApiError ? e.message : "Couldn't load brands. Check your connection.");
      }
    })();
  }, []);

  async function fetchBranchesFor(brandId: number) {
    setBranchesByBrand((prev) => ({ ...prev, [brandId]: "loading" }));
    try {
      const list = await api.branches(brandId);
      setBranchesByBrand((prev) => ({ ...prev, [brandId]: list }));
    } catch {
      setBranchesByBrand((prev) => ({ ...prev, [brandId]: "error" }));
    }
  }

  function toggleBranch(brandId: number, branchId: number) {
    setSelectionByBrand((prev) => {
      const current = new Set(prev[brandId] ?? []);
      if (current.has(branchId)) current.delete(branchId);
      else current.add(branchId);
      return { ...prev, [brandId]: current };
    });
  }
  function selectAllBranches(brandId: number) {
    const list = branchesByBrand[brandId];
    if (!Array.isArray(list)) return;
    setSelectionByBrand((prev) => ({ ...prev, [brandId]: new Set(list.map((b) => b.branchId)) }));
  }
  function selectNoBranches(brandId: number) {
    setSelectionByBrand((prev) => ({ ...prev, [brandId]: new Set() }));
  }

  const selectedBranchIds = Object.values(selectionByBrand).flatMap((s) => [...s]);
  // Brands with at least one branch actively selected — narrows the item
  // search to a relevant catalog; empty means "no branch filter yet", so the
  // item search falls back to every brand instead of matching nothing.
  const activeBrandIds = Object.entries(selectionByBrand)
    .filter(([, set]) => set.size > 0)
    .map(([id]) => Number(id));

  // Memoized deliberately: resolvePresetRange("30d" etc.) bakes in
  // `new Date()`, so calling it fresh on every render — as this used to —
  // produces a DIFFERENT `to`/`from` timestamp each time, which fed straight
  // into filterKey below. That made filterKey compare as "changed" on every
  // single render, including the ones caused by the fetch effect's OWN
  // setLoading/setRows calls — a self-sustaining loop that refetched the
  // whole page roughly every 250ms forever, with nobody touching a filter.
  // Keying this off the actual inputs (rangePreset/customFrom/customTo) means
  // it's only ever a new object when one of those genuinely changes.
  const range = useMemo((): { from?: string; to?: string } => {
    return rangePreset === "custom"
      ? {
          from: customFrom ? new Date(`${customFrom}T00:00:00`).toISOString() : undefined,
          to: customTo ? new Date(`${customTo}T23:59:59.999`).toISOString() : undefined,
        }
      : resolvePresetRange(rangePreset);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rangePreset, customFrom, customTo]);

  // Whole numbers only, 0 or more — anything else (blank, a decimal, a
  // stray letter from a paste) is treated as "no filter" rather than sent to
  // the API or silently coerced into something the person didn't type.
  const itemCountTrimmed = itemCountInput.trim();
  const itemCountInvalid = itemCountTrimmed !== "" && !/^\d+$/.test(itemCountTrimmed);
  const itemCountValue =
    itemCountTrimmed !== "" && !itemCountInvalid ? Number(itemCountTrimmed) : undefined;

  function currentFilterParams() {
    return {
      branchIds: selectedBranchIds,
      verdicts: [...selectedVerdicts],
      itemIds: selectedItems.map((s) => s.menuItemId),
      itemCount: itemCountValue,
      from: range.from,
      to: range.to,
      sortBy,
      sortDir,
    };
  }

  // A stable fingerprint of every filter EXCEPT page/pageSize — used to reset
  // to page 1 the moment a filter (or the sort column/direction) actually
  // changes, so "50 results" never silently shows page 6 of a now-much-
  // different order. Built from `range` (memoized above) rather than
  // recomputing it here, so this string is itself stable across renders that
  // don't actually change a filter.
  const filterKey = JSON.stringify({
    b: [...selectedBranchIds].sort((a, b) => a - b),
    v: [...selectedVerdicts].sort(),
    i: selectedItems.map((s) => s.menuItemId).sort((a, b) => a - b),
    ic: itemCountValue ?? null,
    r: range,
    sb: sortBy,
    sd: sortDir,
  });

  const reqId = useRef(0);

  useEffect(() => {
    setPage(1);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filterKey, pageSize]);

  useEffect(() => {
    const id = ++reqId.current;
    setLoading(true);
    const timer = setTimeout(() => {
      (async () => {
        try {
          const result = await api.weighHistory({
            ...currentFilterParams(),
            page,
            pageSize: Number(pageSize),
          });
          if (id !== reqId.current) return;
          setRows(result.rows);
          setTotalCount(result.totalCount);
          setVerdictCounts(result.verdictCounts);
          setLoadError(null);
        } catch (e) {
          if (id !== reqId.current) return;
          setLoadError(
            e instanceof ApiError ? e.message : "Couldn't load weigh history. Check your connection and try again.",
          );
        } finally {
          if (id === reqId.current) setLoading(false);
        }
      })();
    }, 250);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filterKey, page, pageSize]);

  async function downloadCsv() {
    setDownloading(true);
    setDownloadError(null);
    try {
      // Same sort currently applied on screen (sortBy/sortDir already ride
      // along inside currentFilterParams()) — the file always matches what's
      // actually visible, never a silently different default order.
      const blob = await api.exportWeighedOrders({ ...currentFilterParams(), format, fileType });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      const stamp = new Date().toISOString().slice(0, 10);
      a.href = url;
      a.download = `weighed-${format}-${stamp}.${fileType}`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (e) {
      setDownloadError(e instanceof ApiError ? e.message : "Download failed. Check your connection and try again.");
    } finally {
      setDownloading(false);
    }
  }

  const totalPages = totalCount != null ? Math.max(1, Math.ceil(totalCount / Number(pageSize))) : 1;
  const hasAnyFilter =
    selectedBranchIds.length > 0 ||
    selectedVerdicts.size > 0 ||
    selectedItems.length > 0 ||
    itemCountTrimmed !== "" ||
    rangePreset !== "all";

  function clearAllFilters() {
    setSelectionByBrand({});
    setSelectedVerdicts(new Set());
    setSelectedItems([]);
    setItemCountInput("");
    setRangePreset("30d");
    setCustomFrom("");
    setCustomTo("");
  }

  return (
    <div className="animate-fade-up">
      <h1 className="font-display text-2xl text-ink">Weigh History</h1>
      <p className="mb-6 mt-1 max-w-2xl text-sm text-muted">
        Every weighed order — searchable by brand, branch, verdict, date, and the items it
        actually contains — viewable here and downloadable as CSV with the exact same filters.
      </p>

      {brandsError && (
        <div className="mb-4">
          <Banner tone="bad">{brandsError}</Banner>
        </div>
      )}

      <Card className="p-5">
        <div className="flex items-center justify-between gap-2">
          <div className="font-display text-sm text-ink">Filters</div>
          {hasAnyFilter && (
            <button
              type="button"
              onClick={clearAllFilters}
              className="text-xs font-semibold text-muted transition-colors hover:text-ink"
            >
              Clear all
            </button>
          )}
        </div>

        <div className="mt-4 space-y-4">
          <div>
            <div className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted">
              Branches{selectedBranchIds.length > 0 ? ` (${selectedBranchIds.length} selected)` : " (all)"}
            </div>
            <div className="flex flex-wrap gap-1.5">
              {brands.length === 0 ? (
                <Spinner />
              ) : (
                brands.map((b) => (
                  <BrandBranchPicker
                    key={b.brandId}
                    brand={b}
                    isOpen={openBrandId === b.brandId}
                    onToggleOpen={() => setOpenBrandId((cur) => (cur === b.brandId ? null : b.brandId))}
                    onClose={() => setOpenBrandId((cur) => (cur === b.brandId ? null : cur))}
                    branchState={branchesByBrand[b.brandId]}
                    onFetch={() => void fetchBranchesFor(b.brandId)}
                    selected={selectionByBrand[b.brandId] ?? new Set<number>()}
                    onToggleBranch={(branchId) => toggleBranch(b.brandId, branchId)}
                    onSelectAll={() => selectAllBranches(b.brandId)}
                    onSelectNone={() => selectNoBranches(b.brandId)}
                  />
                ))
              )}
            </div>
          </div>

          <div>
            <div className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted">
              Verdict{selectedVerdicts.size > 0 ? ` (${selectedVerdicts.size} selected)` : " (all)"}
            </div>
            <div className="flex flex-wrap gap-1.5">
              {VERDICT_OPTIONS.map((v) => (
                <TogglePill
                  key={v.value}
                  active={selectedVerdicts.has(v.value)}
                  onClick={() => setSelectedVerdicts((prev) => toggledStrSet(prev, v.value))}
                >
                  {v.label}
                </TogglePill>
              ))}
            </div>
          </div>

          <ItemFilterPicker
            brands={brands}
            activeBrandIds={activeBrandIds}
            selected={selectedItems}
            onAdd={(item) => setSelectedItems((prev) => [...prev, item])}
            onRemove={(id) => setSelectedItems((prev) => prev.filter((s) => s.menuItemId !== id))}
          />

          <div>
            <div className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted">
              Items in order
            </div>
            <div className="max-w-[9rem]">
              <NumberInput
                inputMode="numeric"
                step={1}
                placeholder="Any"
                value={itemCountInput}
                onChange={(e) => setItemCountInput(e.target.value)}
                aria-invalid={itemCountInvalid}
                aria-describedby={itemCountInvalid ? "item-count-error" : undefined}
              />
            </div>
            {itemCountInvalid ? (
              <p id="item-count-error" className="mt-1.5 text-xs font-medium text-badtext">
                Enter a whole number, 0 or more.
              </p>
            ) : itemCountTrimmed !== "" ? (
              <p className="mt-1.5 text-xs text-muted">
                Only orders with exactly {itemCountTrimmed} item{itemCountTrimmed === "1" ? "" : "s"}.
              </p>
            ) : null}
          </div>

          <div className="flex flex-wrap items-end justify-between gap-3 border-t border-line pt-4">
            <DateRangeFilter
              preset={rangePreset}
              onPresetChange={setRangePreset}
              customFrom={customFrom}
              customTo={customTo}
              onCustomChange={(f, t) => {
                setCustomFrom(f);
                setCustomTo(t);
              }}
            />

            <div className="flex flex-wrap items-end gap-2">
              <div className="flex overflow-hidden rounded-lg border border-line">
                <button
                  type="button"
                  onClick={() => setFormat("orders")}
                  className={`px-3 py-2 text-xs font-semibold transition-colors ${format === "orders" ? "bg-green text-white" : "bg-white text-muted hover:text-ink"}`}
                >
                  Order summary
                </button>
                <button
                  type="button"
                  onClick={() => setFormat("items")}
                  className={`px-3 py-2 text-xs font-semibold transition-colors ${format === "items" ? "bg-green text-white" : "bg-white text-muted hover:text-ink"}`}
                >
                  Item-level detail
                </button>
              </div>
              <div className="flex overflow-hidden rounded-lg border border-line" role="group" aria-label="File type">
                <button
                  type="button"
                  onClick={() => setFileType("csv")}
                  title="Plain CSV — opens in any spreadsheet app or text editor"
                  className={`flex items-center gap-1.5 px-3 py-2 text-xs font-semibold transition-colors ${fileType === "csv" ? "bg-green text-white" : "bg-white text-muted hover:text-ink"}`}
                >
                  <FileText size={13} /> CSV
                </button>
                <button
                  type="button"
                  onClick={() => setFileType("xlsx")}
                  title="Excel workbook — bold header row, frozen, with filter dropdowns already on"
                  className={`flex items-center gap-1.5 px-3 py-2 text-xs font-semibold transition-colors ${fileType === "xlsx" ? "bg-green text-white" : "bg-white text-muted hover:text-ink"}`}
                >
                  <FileSpreadsheet size={13} /> Excel
                </button>
              </div>
              <Button variant="outline" onClick={() => void downloadCsv()} disabled={downloading}>
                {downloading ? (
                  <>
                    <ButtonSpinner /> Preparing…
                  </>
                ) : (
                  <>
                    <Download size={14} /> Download {fileType === "xlsx" ? "Excel" : "CSV"}
                  </>
                )}
              </Button>
              <Button variant="outline" onClick={() => setShowScatter(true)}>
                <ScatterChart size={14} /> Plot data
              </Button>
            </div>
          </div>
          <p className="text-xs text-muted">
            Downloads exactly what's filtered and sorted below
            {sortBy !== "weighedAt" || sortDir !== "desc" ? (
              <>
                {" "}
                — currently sorted by <span className="font-semibold text-ink">{SORT_COLUMNS[sortBy].label}</span>,{" "}
                {sortDir === "asc" ? "ascending" : "descending"}
              </>
            ) : null}
            .
          </p>
          {downloadError && <Banner tone="bad">{downloadError}</Banner>}
        </div>
      </Card>

      {!loadError && verdictCounts && (
        <div className="mt-4">
          <VerdictSummaryTiles counts={verdictCounts} />
        </div>
      )}

      <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
        <div className="text-sm text-muted">
          {loading && rows.length === 0 ? (
            <span className="inline-flex items-center gap-2">
              <ButtonSpinner /> Loading…
            </span>
          ) : totalCount != null ? (
            <>
              <span className="font-mono font-bold text-ink">{totalCount.toLocaleString()}</span>{" "}
              {totalCount === 1 ? "order matches" : "orders match"} these filters
              {loading && <span className="ml-2 text-xs text-muted">(updating…)</span>}
            </>
          ) : null}
        </div>
        <div className="flex items-center gap-2 text-xs font-semibold text-muted">
          <span>Rows per page</span>
          <Select value={pageSize} onChange={setPageSize} options={PAGE_SIZE_OPTIONS.map((n) => ({ value: n, label: n }))} />
        </div>
      </div>

      <div className="mt-3">
        {loadError ? (
          <Card className="p-5">
            <Banner tone="bad">{loadError}</Banner>
            <div className="mt-3">
              <Button variant="outline" onClick={() => setPage((p) => p)}>
                Retry
              </Button>
            </div>
          </Card>
        ) : !loading && rows.length === 0 ? (
          <Card className="flex flex-col items-center px-6 py-14 text-center">
            <p className="text-sm text-muted">
              No weighed orders match these filters
              {hasAnyFilter ? " — try widening the date range or clearing a filter." : " yet."}
            </p>
          </Card>
        ) : (
          <div className="no-scrollbar max-h-[65vh] overflow-auto rounded-xl border border-line bg-white">
              <table className="w-full text-left text-sm">
                <thead className="sticky top-0 z-10 border-b border-line bg-cream text-xs font-semibold uppercase tracking-wide text-muted">
                  <tr>
                    <SortableTh sortKey="weighedAt" active={sortBy === "weighedAt"} dir={sortDir} onSort={toggleSort} />
                    <SortableTh sortKey="branch" active={sortBy === "branch"} dir={sortDir} onSort={toggleSort} />
                    <SortableTh sortKey="device" active={sortBy === "device"} dir={sortDir} onSort={toggleSort} />
                    <th className="px-3 py-2.5">Items</th>
                    <SortableTh
                      sortKey="expected"
                      active={sortBy === "expected"}
                      dir={sortDir}
                      onSort={toggleSort}
                      align="right"
                    />
                    <SortableTh
                      sortKey="measured"
                      active={sortBy === "measured"}
                      dir={sortDir}
                      onSort={toggleSort}
                      align="right"
                    />
                    <SortableTh
                      sortKey="deviation"
                      active={sortBy === "deviation"}
                      dir={sortDir}
                      onSort={toggleSort}
                      align="right"
                    />
                    <SortableTh sortKey="verdict" active={sortBy === "verdict"} dir={sortDir} onSort={toggleSort} />
                    <SortableTh
                      sortKey="overrideReason"
                      active={sortBy === "overrideReason"}
                      dir={sortDir}
                      onSort={toggleSort}
                    />
                    <th className="px-3 py-2.5">
                      <span className="sr-only">Breakdown</span>
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {rows.map((r) => (
                    <tr key={r.eventId} className="transition-colors duration-150 hover:bg-black/[0.03]">
                      <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs text-ink">
                        {fmtDateTime(r.weighedAt)}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-ink">
                        {r.brandCode ?? "—"} · {r.branchName ?? "—"}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-muted">{r.deviceLabel ?? "—"}</td>
                      <td className="max-w-xs px-3 py-2.5 text-ink">
                        {r.itemNames.length === 0 ? (
                          <span className="text-muted">—</span>
                        ) : (
                          <span className="line-clamp-1" title={r.itemNames.join(", ")}>
                            {r.itemNames.join(", ")}
                          </span>
                        )}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-right font-mono text-xs text-muted">
                        {r.expectedMinG != null && r.expectedMaxG != null
                          ? `${fmtG(r.expectedMinG)}–${fmtG(r.expectedMaxG)}`
                          : "—"}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-right font-mono text-xs font-bold text-ink">
                        {fmtG(r.measuredG)}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-right font-mono text-xs font-bold">
                        {(() => {
                          const dev = rowDeviation(r);
                          if (dev == null) return <span className="font-normal text-muted">—</span>;
                          return (
                            <span className={DEVIATION_TONE_CLASS[verdictTone(r.verdict)]}>{fmtSignedG(dev)}</span>
                          );
                        })()}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5">
                        <Badge tone={verdictTone(r.verdict)}>{verdictLabel(r.verdict)}</Badge>
                      </td>
                      <td className="max-w-[16rem] truncate px-3 py-2.5 text-xs text-muted" title={r.overrideReason ?? undefined}>
                        {r.overrideReason ?? "—"}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5">
                        <button
                          type="button"
                          onClick={() => setViewingEvent({ eventId: r.eventId, brandCode: r.brandCode })}
                          aria-label="View full order breakdown"
                          title="View full order breakdown"
                          className="rounded-full p-1.5 text-muted transition-colors hover:bg-green/10 hover:text-green"
                        >
                          <ListTree size={15} />
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
          </div>
        )}
      </div>

      {viewingEvent && (
        <BreakdownViewer
          eventId={viewingEvent.eventId}
          brandId={viewingBrandId}
          onClose={() => setViewingEvent(null)}
        />
      )}

      {showScatter && (
        <ScatterChartModal
          filterParams={currentFilterParams()}
          onClose={() => setShowScatter(false)}
          onSelectPoint={(p) => setViewingEvent({ eventId: p.eventId, brandCode: p.brandCode })}
        />
      )}

      {totalCount != null && totalCount > 0 && (
        <div className="mt-4 flex items-center justify-between gap-3">
          <span className="text-xs text-muted">
            Page {page} of {totalPages}
          </span>
          <div className="flex gap-2">
            <Button
              variant="outline"
              onClick={() => setPage((p) => Math.max(1, p - 1))}
              disabled={page <= 1 || loading}
            >
              <ChevronLeft size={14} /> Prev
            </Button>
            <Button
              variant="outline"
              onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
              disabled={page >= totalPages || loading}
            >
              Next <ChevronRight size={14} />
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
