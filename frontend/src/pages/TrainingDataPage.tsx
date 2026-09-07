import { useEffect, useState } from "react";
import { api, ApiError } from "../api";
import type { Branch, BrandSummary, TrainingComponent, TrainingOrderPreview, TrainingPreviewResult } from "../types";
import {
  Card,
  Button,
  ButtonSpinner,
  Banner,
  Spinner,
  Badge,
  Select,
  TogglePill,
  DateRangeFilter,
  resolvePresetRange,
  type RangePresetKey,
} from "../ui";

type BranchLoadState = Branch[] | "loading" | "error" | undefined;

function toggledNumSet(set: Set<number>, id: number): Set<number> {
  const next = new Set(set);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

const COMPONENT_TONE: Record<TrainingComponent["type"], "neutral" | "ok" | "warn" | "bad"> = {
  item: "neutral",
  modifier: "neutral",
  combination: "ok",
  unmapped: "bad",
};

function ComponentPill({ c }: { c: TrainingComponent }) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-semibold ${
        {
          neutral: "border border-line bg-white text-ink",
          ok: "bg-okbg text-oktext",
          warn: "bg-warnbg text-[#8a5a10]",
          bad: "bg-badbg text-badtext",
        }[COMPONENT_TONE[c.type]]
      }`}
      title={`${c.type} — ${c.key}`}
    >
      {c.type === "combination" && "⚭ "}
      {c.type === "unmapped" && "⚠ "}
      {c.label}
    </span>
  );
}

function StatTile({
  label,
  value,
  tone = "ink",
}: {
  label: string;
  value: number;
  tone?: "ink" | "ok" | "amber" | "coral";
}) {
  const color = { ink: "text-ink", ok: "text-oktext", amber: "text-ink", coral: "text-badtext" }[tone];
  return (
    <Card className="p-4">
      <div className="text-xs font-semibold uppercase tracking-wide text-ink/60">{label}</div>
      <div className={`font-mono text-2xl font-bold ${color}`}>{value.toLocaleString()}</div>
    </Card>
  );
}

function OrderCard({ order }: { order: TrainingOrderPreview }) {
  return (
    <Card className={`p-4 ${order.trusted ? "" : "opacity-70"}`}>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5">
        <span className="font-mono text-xs text-muted">#{order.eventId}</span>
        <span className="text-sm font-semibold text-ink">
          {order.brandCode ?? "?"} · {order.branchName ?? "unknown branch"}
        </span>
        <span className="font-mono text-xs text-muted">
          {new Date(order.weighedAt).toLocaleString(undefined, {
            month: "short",
            day: "numeric",
            hour: "2-digit",
            minute: "2-digit",
          })}
        </span>
        <span className="ml-auto font-mono text-sm font-bold text-ink">
          {order.measuredG != null ? `${order.measuredG}g` : "not weighed"}
        </span>
        {order.trusted ? (
          <Badge tone="ok">✓ clean</Badge>
        ) : (
          <Badge tone="bad">excluded — {order.excludeReason}</Badge>
        )}
        {order.unmappedCount > 0 && <Badge tone="warn">{order.unmappedCount} unmapped</Badge>}
      </div>
      <div className="mt-2.5 space-y-2">
        {order.components.length === 0 ? (
          <span className="text-xs text-muted">No composition recorded for this order.</span>
        ) : (
          groupByLine(order.components).map(([lineIndex, comps]) => {
            const itemComp = comps[0];
            const modComps = comps.slice(1);
            return (
              <div key={lineIndex} className="rounded-lg border border-line/70 bg-page/60 p-2">
                <div className="mb-1 text-xs font-bold text-ink">
                  <ComponentPill c={itemComp} />
                </div>
                {modComps.length > 0 ? (
                  <div className="flex flex-wrap gap-1.5">
                    {modComps.map((c, i) => (
                      <ComponentPill key={`${c.key}-${i}`} c={c} />
                    ))}
                  </div>
                ) : (
                  <span className="text-xs text-muted">No modifiers on this line.</span>
                )}
              </div>
            );
          })
        )}
      </div>
    </Card>
  );
}

/// Groups a flat component list back into its order lines, in line order —
/// each line's own item/unmapped-item component always comes first (see
/// ResolveLineComponents on the backend), so callers can split "the item"
/// from "its modifiers" just by taking the first entry of each group.
function groupByLine(components: TrainingComponent[]): [number, TrainingComponent[]][] {
  const byLine = new Map<number, TrainingComponent[]>();
  for (const c of components) {
    const list = byLine.get(c.lineIndex);
    if (list) list.push(c);
    else byLine.set(c.lineIndex, [c]);
  }
  return [...byLine.entries()].sort(([a], [b]) => a - b);
}

function ComponentsTable({ orders }: { orders: TrainingOrderPreview[] }) {
  const rows = orders.flatMap((o) =>
    o.components.length > 0
      ? o.components.map((c) => ({ order: o, c }))
      : [{ order: o, c: null as TrainingComponent | null }],
  );
  if (rows.length === 0)
    return <p className="p-4 text-sm text-muted">No rows to show for the current filters.</p>;
  return (
    <div className="no-scrollbar max-h-[60vh] overflow-auto rounded-xl border border-line">
      <table className="w-full text-left text-sm">
        <thead className="sticky top-0 border-b border-line bg-cream text-xs font-semibold uppercase tracking-wide text-muted">
          <tr>
            <th className="whitespace-nowrap px-3 py-2.5">event_id</th>
            <th className="whitespace-nowrap px-3 py-2.5">weighed_at</th>
            <th className="whitespace-nowrap px-3 py-2.5">measured_g</th>
            <th className="whitespace-nowrap px-3 py-2.5">trusted</th>
            <th className="whitespace-nowrap px-3 py-2.5">line_index</th>
            <th className="whitespace-nowrap px-3 py-2.5">component_key</th>
            <th className="whitespace-nowrap px-3 py-2.5">component_label</th>
            <th className="whitespace-nowrap px-3 py-2.5">component_type</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-line">
          {rows.map(({ order, c }, i) => (
            <tr key={i} className="transition-colors duration-150 hover:bg-black/[0.03]">
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">{order.eventId}</td>
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">
                {new Date(order.weighedAt).toISOString().slice(0, 16).replace("T", " ")}
              </td>
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">
                {order.measuredG ?? <span className="text-muted">—</span>}
              </td>
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">
                {order.trusted ? "true" : "false"}
              </td>
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">
                {c?.lineIndex ?? <span className="text-muted">—</span>}
              </td>
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">
                {c?.key ?? <span className="text-muted">—</span>}
              </td>
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">{c?.label ?? "—"}</td>
              <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink">{c?.type ?? "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function TrainingDataPage() {
  const [brands, setBrands] = useState<BrandSummary[]>([]);
  const [brandsError, setBrandsError] = useState<string | null>(null);
  const [selectedBrandId, setSelectedBrandId] = useState<string>("");
  const [branchState, setBranchState] = useState<BranchLoadState>(undefined);
  const [selectedBranchIds, setSelectedBranchIds] = useState<Set<number>>(new Set());

  const [rangePreset, setRangePreset] = useState<RangePresetKey>("30d");
  const [customFrom, setCustomFrom] = useState("");
  const [customTo, setCustomTo] = useState("");

  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [preview, setPreview] = useState<TrainingPreviewResult | null>(null);

  const [showExcluded, setShowExcluded] = useState(false);
  const [viewMode, setViewMode] = useState<"orders" | "components">("orders");

  const [trustedOnly, setTrustedOnly] = useState(true);
  const [exporting, setExporting] = useState<"orders" | "components" | null>(null);
  const [exportError, setExportError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const list = await api.brands();
        setBrands(list);
        if (list.length > 0) setSelectedBrandId(String(list[0].brandId));
      } catch (e) {
        setBrandsError(e instanceof ApiError ? e.message : "Couldn't load brands. Check your connection.");
      }
    })();
  }, []);

  useEffect(() => {
    if (!selectedBrandId) return;
    setSelectedBranchIds(new Set());
    setBranchState("loading");
    (async () => {
      try {
        setBranchState(await api.branches(Number(selectedBrandId)));
      } catch {
        setBranchState("error");
      }
    })();
  }, [selectedBrandId]);

  function currentRange(): { from?: string; to?: string } {
    return rangePreset === "custom"
      ? {
          from: customFrom ? new Date(`${customFrom}T00:00:00`).toISOString() : undefined,
          to: customTo ? new Date(`${customTo}T23:59:59.999`).toISOString() : undefined,
        }
      : resolvePresetRange(rangePreset);
  }

  function currentFilterParams() {
    const range = currentRange();
    return {
      brandIds: selectedBrandId ? [Number(selectedBrandId)] : [],
      branchIds: [...selectedBranchIds],
      from: range.from,
      to: range.to,
    };
  }

  async function loadPreview() {
    setPreviewLoading(true);
    setPreviewError(null);
    try {
      setPreview(await api.trainingPreview({ ...currentFilterParams(), limit: 30 }));
      setShowExcluded(false);
    } catch (e) {
      setPreviewError(
        e instanceof ApiError ? e.message : "Couldn't load a preview. Check your connection and try again.",
      );
    } finally {
      setPreviewLoading(false);
    }
  }

  async function exportCsv(format: "orders" | "components") {
    setExporting(format);
    setExportError(null);
    try {
      const blob = await api.exportTrainingData({ ...currentFilterParams(), trustedOnly, format });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      const stamp = new Date().toISOString().slice(0, 10);
      a.href = url;
      a.download = `training-${format}-${stamp}.csv`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (e) {
      setExportError(e instanceof ApiError ? e.message : "Export failed. Check your connection and try again.");
    } finally {
      setExporting(null);
    }
  }

  const visibleOrders = preview ? preview.orders.filter((o) => showExcluded || o.trusted) : [];

  return (
    <div className="animate-fade-up">
      <h1 className="font-display text-2xl text-ink">AI Training Data</h1>
      <p className="mb-6 mt-1 max-w-2xl text-sm text-muted">
        Export weighed orders in the format the discrepancy model trains on — filtered to real,
        confirmed packs and resolved through the same combo-modifier logic the tablet uses, so a
        combo size shows up as what it actually affected, not its own unrelated weight.
      </p>

      {brandsError && (
        <div className="mb-4">
          <Banner tone="bad">{brandsError}</Banner>
        </div>
      )}

      {/* ---- Step 1: Filter ---- */}
      <Card className="p-5">
        <div className="font-display text-sm text-ink">1 · Filter</div>
        <p className="mt-0.5 text-xs text-muted">Pick the brand, branches, and date range to pull from.</p>

        <div className="mt-4 flex flex-col gap-4 sm:flex-row sm:flex-wrap">
          <div>
            <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Brand</span>
            {brands.length === 0 ? (
              <Spinner />
            ) : (
              <Select
                value={selectedBrandId}
                onChange={setSelectedBrandId}
                options={brands.map((b) => ({ value: String(b.brandId), label: b.name }))}
              />
            )}
          </div>

          <div className="min-w-0 sm:flex-1">
            <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">
              Branches{selectedBranchIds.size > 0 ? ` (${selectedBranchIds.size} selected)` : " (all)"}
            </span>
            {branchState === "loading" || branchState === undefined ? (
              <p className="text-sm text-muted">Loading branches…</p>
            ) : branchState === "error" ? (
              <p className="text-sm text-badtext">Couldn't load branches for this brand.</p>
            ) : branchState.length === 0 ? (
              <p className="text-sm text-muted">No branches synced for this brand yet.</p>
            ) : (
              <div className="flex flex-wrap gap-1.5">
                {branchState.map((b) => (
                  <TogglePill
                    key={b.branchId}
                    active={selectedBranchIds.has(b.branchId)}
                    onClick={() => setSelectedBranchIds((prev) => toggledNumSet(prev, b.branchId))}
                  >
                    {b.nameLocalized || b.name}
                  </TogglePill>
                ))}
              </div>
            )}
          </div>
        </div>

        <div className="mt-4 flex flex-col gap-4 sm:flex-row sm:flex-wrap sm:items-end sm:justify-between">
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
          <Button onClick={() => void loadPreview()} disabled={previewLoading || !selectedBrandId}>
            {previewLoading ? (
              <>
                <ButtonSpinner /> Loading…
              </>
            ) : (
              "Load preview"
            )}
          </Button>
        </div>

        {previewError && (
          <div className="mt-3">
            <Banner tone="bad">{previewError}</Banner>
          </div>
        )}
      </Card>

      {/* ---- Step 2: Clean & review ---- */}
      {preview && (
        <Card className="animate-fade-up mt-4 p-5">
          <div className="font-display text-sm text-ink">2 · Clean &amp; review</div>
          <p className="mt-0.5 text-xs text-muted">
            "Clean" means dispatched on-weight with no override — the only orders that are real
            ground truth for what a component actually weighs.
          </p>

          <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
            <StatTile label="Matched" value={preview.summary.totalMatched} />
            <StatTile label="Clean" value={preview.summary.cleanCount} tone="ok" />
            <StatTile label="Off-weight" value={preview.summary.excludedOffWeight} tone="coral" />
            <StatTile label="Overridden" value={preview.summary.excludedOverride} tone="amber" />
          </div>

          {preview.summary.sampledOrdersWithUnmapped > 0 && (
            <div className="mt-3">
              <Banner tone="warn">
                {preview.summary.sampledOrdersWithUnmapped} order{preview.summary.sampledOrdersWithUnmapped === 1 ? "" : "s"}{" "}
                in this preview sample reference an item or modifier no longer in the synced menu —
                shown as "unmapped" below. Still included in the export, so nothing is silently
                dropped, but worth a look before training on it.
              </Banner>
            </div>
          )}

          {preview.summary.totalMatched === 0 ? (
            <div className="mt-4">
              <Banner tone="warn">No weighed orders match these filters — nothing to clean or export yet.</Banner>
            </div>
          ) : (
            <>
              <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
                <TogglePill active={showExcluded} onClick={() => setShowExcluded((v) => !v)}>
                  {showExcluded ? "Showing excluded rows too" : "Show excluded rows too"}
                </TogglePill>
                <div className="flex overflow-hidden rounded-lg border border-line">
                  <button
                    type="button"
                    onClick={() => setViewMode("orders")}
                    className={`px-3 py-2 text-xs font-semibold transition-colors ${viewMode === "orders" ? "bg-green text-white" : "bg-white text-muted hover:text-ink"}`}
                  >
                    By order
                  </button>
                  <button
                    type="button"
                    onClick={() => setViewMode("components")}
                    className={`px-3 py-2 text-xs font-semibold transition-colors ${viewMode === "components" ? "bg-green text-white" : "bg-white text-muted hover:text-ink"}`}
                  >
                    By component
                  </button>
                </div>
              </div>

              <p className="mt-3 text-xs text-muted">
                Showing the {visibleOrders.length} most recent matched order{visibleOrders.length === 1 ? "" : "s"}{" "}
                {showExcluded ? "" : "that are clean"} — the export below covers the full{" "}
                {trustedOnly ? preview.summary.cleanCount.toLocaleString() : preview.summary.totalMatched.toLocaleString()}.
              </p>

              <div className="mt-3">
                {visibleOrders.length === 0 ? (
                  <p className="text-sm text-muted">
                    None of the sampled orders are clean.{" "}
                    <button type="button" onClick={() => setShowExcluded(true)} className="font-semibold text-green underline">
                      Show excluded rows
                    </button>{" "}
                    to see why.
                  </p>
                ) : viewMode === "orders" ? (
                  <div className="space-y-2.5">
                    {visibleOrders.map((o) => (
                      <OrderCard key={o.eventId} order={o} />
                    ))}
                  </div>
                ) : (
                  <ComponentsTable orders={visibleOrders} />
                )}
              </div>
            </>
          )}
        </Card>
      )}

      {/* ---- Step 3: Export ---- */}
      {preview && preview.summary.totalMatched > 0 && (
        <Card className="animate-fade-up mt-4 p-5">
          <div className="font-display text-sm text-ink">3 · Export</div>
          <p className="mt-0.5 text-xs text-muted">
            "Orders" is one row per order (components semicolon-joined) — quick to skim. "Components"
            is the tidy long format (one row per order/component) ready to one-hot encode with no
            JSON parsing.
          </p>

          <div className="mt-4 flex flex-wrap items-center gap-3">
            <TogglePill active={trustedOnly} onClick={() => setTrustedOnly((v) => !v)}>
              {trustedOnly ? "✓ Clean orders only (recommended)" : "Including excluded orders"}
            </TogglePill>
            <span className="font-mono text-xs text-muted">
              → {(trustedOnly ? preview.summary.cleanCount : preview.summary.totalMatched).toLocaleString()} order
              {(trustedOnly ? preview.summary.cleanCount : preview.summary.totalMatched) === 1 ? "" : "s"}
            </span>
          </div>

          <div className="mt-4 flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => void exportCsv("orders")} disabled={exporting !== null}>
              {exporting === "orders" ? (
                <>
                  <ButtonSpinner /> Exporting…
                </>
              ) : (
                "Export orders CSV"
              )}
            </Button>
            <Button onClick={() => void exportCsv("components")} disabled={exporting !== null}>
              {exporting === "components" ? (
                <>
                  <ButtonSpinner /> Exporting…
                </>
              ) : (
                "Export components CSV"
              )}
            </Button>
          </div>

          {exportError && (
            <div className="mt-3">
              <Banner tone="bad">{exportError}</Banner>
            </div>
          )}
        </Card>
      )}
    </div>
  );
}
