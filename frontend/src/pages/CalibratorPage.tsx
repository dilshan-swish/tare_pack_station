import { useMemo, useRef, useState, type ReactNode } from "react";
import {
  UploadCloud,
  FileText,
  X,
  CheckCircle2,
  AlertTriangle,
  AlertCircle,
  HelpCircle,
  Search,
} from "lucide-react";
import { api, ApiError } from "../api";
import type { MenuItem, Modifier, ModifierCombination } from "../types";
import { Card, Badge, Banner, ButtonSpinner, TogglePill } from "../ui";
import {
  parseWeighHistoryCsv,
  buildItemRows,
  buildModifierRows,
  buildComboRows,
  type ParseSummary,
  type BrandCatalog,
  type ItemCalibrationRow,
  type ModifierCalibrationRow,
  type ComboCalibrationRow,
  type CalibrationStats,
  type Confidence,
  type MatchStatus,
} from "../calibration";

// --- Small presentational bits ----------------------------------------------

const CONFIDENCE_META: Record<Confidence, { label: string; tone: "neutral" | "ok" | "warn" | "bad" }> = {
  insufficient: { label: "Not enough data", tone: "neutral" },
  low: { label: "Low confidence", tone: "warn" },
  medium: { label: "Medium confidence", tone: "warn" },
  high: { label: "High confidence", tone: "ok" },
};

function ConfidenceBadge({ confidence, n }: { confidence: Confidence; n: number }) {
  const meta = CONFIDENCE_META[confidence];
  return (
    <Badge tone={meta.tone}>
      {meta.label} · n={n}
    </Badge>
  );
}

const MATCH_META: Record<MatchStatus, { label: string; tone: "neutral" | "ok" | "warn" | "bad"; icon: typeof CheckCircle2 }> = {
  good: { label: "Matches", tone: "ok", icon: CheckCircle2 },
  review: { label: "Worth a look", tone: "warn", icon: AlertTriangle },
  recalibrate: { label: "Recalibrate", tone: "bad", icon: AlertCircle },
  unconfigured: { label: "Not set yet", tone: "neutral", icon: HelpCircle },
  unknown: { label: "Can't judge yet", tone: "neutral", icon: HelpCircle },
};

function MatchBadge({ status }: { status: MatchStatus }) {
  const meta = MATCH_META[status];
  const Icon = meta.icon;
  return (
    <Badge tone={meta.tone}>
      <Icon size={12} /> {meta.label}
    </Badge>
  );
}

function fmt(n: number | null | undefined): string {
  return n == null ? "—" : `${n % 1 === 0 ? n : n.toFixed(1)}g`;
}

/// One side of the comparison — "Calibrated from your data" or "Currently in
/// the database" — as its own labeled panel so the two can sit side by side
/// on desktop and stack on narrow screens.
function StatsPanel({
  heading,
  ideal,
  min,
  max,
  tone,
  footnote,
}: {
  heading: string;
  ideal: number | null;
  min: number | null;
  max: number | null;
  tone: "green" | "neutral";
  footnote?: ReactNode;
}) {
  return (
    <div
      className={`rounded-xl border p-3 ${tone === "green" ? "border-green/30 bg-green/5" : "border-line bg-cream-2/60"}`}
    >
      <div
        className={`mb-2 text-[10px] font-bold uppercase tracking-wide ${tone === "green" ? "text-green" : "text-muted"}`}
      >
        {heading}
      </div>
      <div className="grid grid-cols-3 gap-2 text-center">
        <div>
          <div className="text-[10px] uppercase text-muted">Ideal</div>
          <div className="font-mono text-sm font-bold text-ink">{fmt(ideal)}</div>
        </div>
        <div>
          <div className="text-[10px] uppercase text-muted">Min</div>
          <div className="font-mono text-sm text-ink">{fmt(min)}</div>
        </div>
        <div>
          <div className="text-[10px] uppercase text-muted">Max</div>
          <div className="font-mono text-sm text-ink">{fmt(max)}</div>
        </div>
      </div>
      {footnote && <div className="mt-2 text-[11px] leading-snug text-muted">{footnote}</div>}
    </div>
  );
}

function ComparisonRow({
  title,
  subtitle,
  calibrated,
  current,
  matchStatus,
  calibratedFootnote,
  currentFootnote,
}: {
  title: string;
  subtitle?: string;
  calibrated: CalibrationStats;
  current: { ideal: number | null; min: number | null; max: number | null } | null;
  matchStatus: MatchStatus;
  calibratedFootnote?: ReactNode;
  currentFootnote?: ReactNode;
}) {
  return (
    <Card className="p-4">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="truncate font-semibold text-ink">{title}</div>
          {subtitle && <div className="mt-0.5 text-xs text-muted">{subtitle}</div>}
        </div>
        <div className="flex flex-none flex-wrap items-center gap-1.5">
          <ConfidenceBadge confidence={calibrated.confidence} n={calibrated.n} />
          <MatchBadge status={matchStatus} />
        </div>
      </div>
      <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
        <StatsPanel
          heading="Calibrated from your data"
          ideal={calibrated.confidence === "insufficient" ? null : calibrated.suggestedIdeal}
          min={calibrated.confidence === "insufficient" ? null : calibrated.suggestedMin}
          max={calibrated.confidence === "insufficient" ? null : calibrated.suggestedMax}
          tone="green"
          footnote={calibratedFootnote}
        />
        <StatsPanel
          heading="Currently in database"
          ideal={current?.ideal ?? null}
          min={current?.min ?? null}
          max={current?.max ?? null}
          tone="neutral"
          footnote={currentFootnote}
        />
      </div>
    </Card>
  );
}

// --- Upload zone -------------------------------------------------------------

function UploadZone({ onFile, busy }: { onFile: (file: File) => void; busy: boolean }) {
  const [dragOver, setDragOver] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  return (
    <div
      onDragOver={(e) => {
        e.preventDefault();
        setDragOver(true);
      }}
      onDragLeave={() => setDragOver(false)}
      onDrop={(e) => {
        e.preventDefault();
        setDragOver(false);
        const file = e.dataTransfer.files?.[0];
        if (file) onFile(file);
      }}
      onClick={() => inputRef.current?.click()}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") inputRef.current?.click();
      }}
      className={`flex cursor-pointer flex-col items-center justify-center rounded-2xl border-2 border-dashed px-6 py-14 text-center transition-colors ${
        dragOver ? "border-green bg-green/5" : "border-line bg-white hover:border-green/50"
      }`}
    >
      <span className="flex h-12 w-12 items-center justify-center rounded-full bg-green/10 text-green">
        {busy ? <ButtonSpinner /> : <UploadCloud size={22} />}
      </span>
      <p className="mt-3 text-sm font-semibold text-ink">
        {busy ? "Reading file…" : "Drop your Weigh History CSV here, or click to browse"}
      </p>
      <p className="mt-1 max-w-sm text-xs text-muted">
        Download it from Weigh History with <b>"Item-level detail"</b> selected — that's the format
        this reads.
      </p>
      <input
        ref={inputRef}
        type="file"
        accept=".csv,text/csv"
        className="hidden"
        onChange={(e) => {
          const file = e.target.files?.[0];
          e.target.value = "";
          if (file) onFile(file);
        }}
      />
    </div>
  );
}

// --- Summary panel -------------------------------------------------------------

function SummaryPanel({ summary }: { summary: ParseSummary }) {
  const excludedTotal =
    summary.excludedOffWeight +
    summary.excludedOverride +
    summary.excludedNoComposition +
    summary.excludedMultiItem +
    summary.excludedUnmeasured;
  return (
    <Card className="p-5">
      <div className="font-display text-sm text-ink">What was used</div>
      <p className="mt-0.5 text-xs text-muted">
        Only clean orders (on weight, no override) with exactly one item are used, so every
        number below is a direct measurement — never a guess split across multiple items.
      </p>
      <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div>
          <div className="text-[10px] font-semibold uppercase tracking-wide text-muted">Rows read</div>
          <div className="font-mono text-xl font-bold text-ink">{summary.totalRows.toLocaleString()}</div>
        </div>
        <div>
          <div className="text-[10px] font-semibold uppercase tracking-wide text-muted">Orders</div>
          <div className="font-mono text-xl font-bold text-ink">{summary.totalOrders.toLocaleString()}</div>
        </div>
        <div>
          <div className="text-[10px] font-semibold uppercase tracking-wide text-muted">Used for calibration</div>
          <div className="font-mono text-xl font-bold text-green">{summary.usableSamples.toLocaleString()}</div>
        </div>
        <div>
          <div className="text-[10px] font-semibold uppercase tracking-wide text-muted">Excluded</div>
          <div className="font-mono text-xl font-bold text-muted">{excludedTotal.toLocaleString()}</div>
        </div>
      </div>
      {excludedTotal > 0 && (
        <div className="mt-3 flex flex-wrap gap-1.5 text-xs text-muted">
          {summary.excludedOffWeight > 0 && <Badge tone="neutral">{summary.excludedOffWeight} off-weight</Badge>}
          {summary.excludedOverride > 0 && <Badge tone="neutral">{summary.excludedOverride} overridden</Badge>}
          {summary.excludedMultiItem > 0 && (
            <Badge tone="neutral">{summary.excludedMultiItem} had more than one item</Badge>
          )}
          {summary.excludedNoComposition > 0 && (
            <Badge tone="neutral">{summary.excludedNoComposition} no composition recorded</Badge>
          )}
          {summary.excludedUnmeasured > 0 && (
            <Badge tone="neutral">{summary.excludedUnmeasured} missing a measured weight</Badge>
          )}
        </div>
      )}
    </Card>
  );
}

// --- Main page ---------------------------------------------------------------

type SectionFilter = "all" | "needsReview";
type SectionTab = "items" | "modifiers" | "combos";

export function CalibratorPage() {
  const [fileName, setFileName] = useState<string | null>(null);
  const [parsing, setParsing] = useState(false);
  const [parseError, setParseError] = useState<string | null>(null);
  const [summary, setSummary] = useState<ParseSummary | null>(null);

  const [itemRows, setItemRows] = useState<ItemCalibrationRow[]>([]);
  const [modifierRows, setModifierRows] = useState<ModifierCalibrationRow[]>([]);
  const [comboRows, setComboRows] = useState<ComboCalibrationRow[]>([]);

  const [catalogsLoading, setCatalogsLoading] = useState(false);
  const [catalogError, setCatalogError] = useState<string | null>(null);

  const [tab, setTab] = useState<SectionTab>("items");
  const [filter, setFilter] = useState<SectionFilter>("all");
  const [search, setSearch] = useState("");

  async function handleFile(file: File) {
    setFileName(file.name);
    setParsing(true);
    setParseError(null);
    setSummary(null);
    setItemRows([]);
    setModifierRows([]);
    setComboRows([]);
    setCatalogError(null);

    try {
      const text = await file.text();
      const parsed = parseWeighHistoryCsv(text);
      if ("error" in parsed) {
        setParseError(parsed.error);
        return;
      }
      setSummary(parsed.summary);

      if (parsed.summary.brands.length === 0) {
        setItemRows(buildItemRows(parsed.aloneBuckets, new Map(), new Map()));
        setModifierRows(buildModifierRows(parsed.modifierBuckets, parsed.aloneBuckets, new Map(), new Map()));
        setComboRows(buildComboRows(parsed.comboBuckets, new Map(), new Map()));
        return;
      }

      setCatalogsLoading(true);
      const brandCodeById = new Map(parsed.summary.brands.map((b) => [b.brandId, b.brandCode]));
      const catalogs = new Map<number, BrandCatalog>();
      const failedBrands: string[] = [];

      await Promise.all(
        parsed.summary.brands.map(async ({ brandId, brandCode }) => {
          try {
            const [items, mods, combos]: [MenuItem[], Modifier[], ModifierCombination[]] = await Promise.all([
              api.items(brandId),
              api.modifiers(brandId),
              api.modifierCombinations(brandId),
            ]);
            catalogs.set(brandId, {
              itemsByFoodicsId: new Map(items.map((i) => [i.foodicsProductId, i])),
              modifiersByFoodicsId: new Map(mods.map((m) => [m.foodicsModifierId, m])),
              combinations: combos,
            });
          } catch {
            failedBrands.push(brandCode || String(brandId));
            catalogs.set(brandId, { itemsByFoodicsId: new Map(), modifiersByFoodicsId: new Map(), combinations: [] });
          }
        }),
      );
      setCatalogsLoading(false);
      if (failedBrands.length > 0) {
        setCatalogError(
          `Couldn't load the current configuration for ${failedBrands.join(", ")} — calibrated numbers below are still accurate, but there's nothing to compare them against for that brand.`,
        );
      }

      setItemRows(buildItemRows(parsed.aloneBuckets, catalogs, brandCodeById));
      setModifierRows(buildModifierRows(parsed.modifierBuckets, parsed.aloneBuckets, catalogs, brandCodeById));
      setComboRows(buildComboRows(parsed.comboBuckets, catalogs, brandCodeById));
    } catch (e) {
      setParseError(
        e instanceof ApiError
          ? e.message
          : "Couldn't read that file — make sure it's a CSV downloaded from Weigh History.",
      );
    } finally {
      setParsing(false);
    }
  }

  function reset() {
    setFileName(null);
    setSummary(null);
    setParseError(null);
    setItemRows([]);
    setModifierRows([]);
    setComboRows([]);
    setCatalogError(null);
  }

  const filteredItems = useMemo(() => filterRows(itemRows, filter, search, (r) => `${r.itemName} ${r.brandCode}`), [itemRows, filter, search]);
  const filteredModifiers = useMemo(
    () => filterRows(modifierRows, filter, search, (r) => `${r.itemName} ${r.modifierName} ${r.brandCode}`),
    [modifierRows, filter, search],
  );
  const filteredCombos = useMemo(
    () => filterRows(comboRows, filter, search, (r) => `${r.itemName} ${r.modifierNames.join(" ")} ${r.brandCode}`),
    [comboRows, filter, search],
  );

  const needsReviewCount =
    itemRows.filter((r) => r.matchStatus === "review" || r.matchStatus === "recalibrate").length +
    modifierRows.filter((r) => r.matchStatus === "review" || r.matchStatus === "recalibrate").length +
    comboRows.filter((r) => r.matchStatus === "review" || r.matchStatus === "recalibrate").length;

  return (
    <div className="animate-fade-up">
      <h1 className="font-display text-2xl text-ink">Weight Calibrator</h1>
      <p className="mb-6 mt-1 max-w-2xl text-sm text-muted">
        Upload a Weigh History export and get a measured ideal/min/max for every item and modifier
        it covers, next to what's currently configured — nothing here is saved automatically, this
        is purely for you to review.
      </p>

      {!summary && (
        <>
          <UploadZone onFile={(f) => void handleFile(f)} busy={parsing} />
          {parseError && (
            <div className="mt-4">
              <Banner tone="bad">{parseError}</Banner>
            </div>
          )}
        </>
      )}

      {summary && (
        <>
          <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
            <div className="flex items-center gap-2 text-sm text-ink">
              <FileText size={16} className="text-muted" />
              <span className="font-semibold">{fileName}</span>
            </div>
            <button
              type="button"
              onClick={reset}
              className="flex items-center gap-1 text-xs font-semibold text-muted transition-colors hover:text-ink"
            >
              <X size={13} /> Upload a different file
            </button>
          </div>

          <SummaryPanel summary={summary} />

          {catalogsLoading && (
            <div className="mt-4">
              <Card className="flex items-center gap-2 p-4 text-sm text-muted">
                <ButtonSpinner /> Loading current weights for comparison…
              </Card>
            </div>
          )}
          {catalogError && (
            <div className="mt-4">
              <Banner tone="warn">{catalogError}</Banner>
            </div>
          )}

          {summary.usableSamples === 0 ? (
            <div className="mt-4">
              <Banner tone="warn">
                No single-item, on-weight orders were usable in this file — nothing to calibrate.
                Try a wider date range, or a brand/branch with more clean weigh-ins.
              </Banner>
            </div>
          ) : (
            <>
              <div className="mt-6 flex flex-wrap items-center justify-between gap-3">
                <div className="flex gap-1.5">
                  <TogglePill active={tab === "items"} onClick={() => setTab("items")}>
                    Items ({itemRows.length})
                  </TogglePill>
                  <TogglePill active={tab === "modifiers"} onClick={() => setTab("modifiers")}>
                    Modifiers ({modifierRows.length})
                  </TogglePill>
                  <TogglePill active={tab === "combos"} onClick={() => setTab("combos")}>
                    Combos ({comboRows.length})
                  </TogglePill>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <div className="relative">
                    <Search size={13} className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-muted" />
                    <input
                      type="text"
                      value={search}
                      onChange={(e) => setSearch(e.target.value)}
                      placeholder="Search…"
                      className="w-44 rounded-lg border border-line bg-white py-1.5 pl-7 pr-2.5 text-xs outline-none transition focus:border-green focus:ring-2 focus:ring-green/20"
                    />
                  </div>
                  <TogglePill active={filter === "needsReview"} onClick={() => setFilter((f) => (f === "needsReview" ? "all" : "needsReview"))}>
                    Needs review ({needsReviewCount})
                  </TogglePill>
                </div>
              </div>

              <div className="mt-4 space-y-3">
                {tab === "items" &&
                  (filteredItems.length === 0 ? (
                    <EmptyRowState />
                  ) : (
                    filteredItems.map((r) => (
                      <ComparisonRow
                        key={`${r.brandId}:${r.itemId}`}
                        title={r.itemName}
                        subtitle={r.brandCode ? `${r.brandCode} · item, weighed alone` : "weighed alone"}
                        calibrated={r.stats}
                        current={r.current ? { ideal: r.current.idealG, min: r.current.minG, max: r.current.maxG } : null}
                        matchStatus={r.matchStatus}
                        calibratedFootnote={
                          r.stats.confidence === "insufficient"
                            ? `Only ${r.stats.n} sample${r.stats.n === 1 ? "" : "s"} — need at least 3 to suggest a range.`
                            : undefined
                        }
                        currentFootnote={!r.current ? "Not found in the current catalog." : undefined}
                      />
                    ))
                  ))}

                {tab === "modifiers" &&
                  (filteredModifiers.length === 0 ? (
                    <EmptyRowState />
                  ) : (
                    filteredModifiers.map((r) => (
                      <ComparisonRow
                        key={`${r.brandId}:${r.itemId}:${r.modifierId}`}
                        title={r.modifierName}
                        subtitle={`${r.brandCode ? `${r.brandCode} · ` : ""}under ${r.itemName}`}
                        calibrated={r.isolated ?? r.bundled}
                        current={r.current ? { ideal: r.current.weightG, min: r.current.minG, max: r.current.maxG } : null}
                        matchStatus={r.matchStatus}
                        calibratedFootnote={
                          r.isolated
                            ? `Isolated from ${r.itemName}'s own weight — the bundled figure was ${fmt(r.bundled.suggestedIdeal)}.`
                            : `${r.itemName} was never weighed alone in this file, so this is the bundled item+modifier weight, not the modifier alone.`
                        }
                        currentFootnote={
                          !r.current
                            ? "Not found in the current catalog."
                            : "This modifier's global weight — the database doesn't store a separate value per item yet."
                        }
                      />
                    ))
                  ))}

                {tab === "combos" &&
                  (filteredCombos.length === 0 ? (
                    <EmptyRowState />
                  ) : (
                    filteredCombos.map((r) => (
                      <ComparisonRow
                        key={`${r.brandId}:${r.itemId}:${r.modifierNames.join(",")}`}
                        title={`${r.itemName} + ${r.modifierNames.join(" + ")}`}
                        subtitle={`${r.brandCode ? `${r.brandCode} · ` : ""}${r.modifierNames.length} modifiers together — not decomposed`}
                        calibrated={r.bundled}
                        current={r.current ? { ideal: r.current.totalG, min: null, max: null } : null}
                        matchStatus={r.matchStatus}
                        calibratedFootnote="Two or more modifiers were selected together, so this is the whole item+modifiers total — isolating one modifier's own share isn't possible without guessing."
                        currentFootnote={
                          r.currentBasis === "combination-override"
                            ? "Based on a configured combination override."
                            : r.currentBasis === "sum-of-individual"
                              ? "Based on the item's weight plus each modifier's own weight — no combination override is configured for this exact set."
                              : "Not enough of this combination's parts are configured yet to compute a current total."
                        }
                      />
                    ))
                  ))}
              </div>
            </>
          )}
        </>
      )}
    </div>
  );
}

function EmptyRowState() {
  return (
    <Card className="flex flex-col items-center px-6 py-12 text-center">
      <p className="text-sm text-muted">Nothing matches the current search/filter.</p>
    </Card>
  );
}

function filterRows<T extends { matchStatus: MatchStatus }>(
  rows: T[],
  filter: SectionFilter,
  search: string,
  textOf: (r: T) => string,
): T[] {
  const q = search.trim().toLowerCase();
  return rows
    .filter((r) => (filter === "needsReview" ? r.matchStatus === "review" || r.matchStatus === "recalibrate" : true))
    .filter((r) => (q ? textOf(r).toLowerCase().includes(q) : true))
    .sort((a, b) => {
      const rank: Record<MatchStatus, number> = { recalibrate: 0, review: 1, unconfigured: 2, unknown: 3, good: 4 };
      return rank[a.matchStatus] - rank[b.matchStatus];
    });
}
