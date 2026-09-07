import { useEffect, useRef, useState } from "react";
import { api, ApiError } from "../api";
import type { BrandSummary, Branch, WeighSummary } from "../types";
import {
  Card,
  Banner,
  Spinner,
  Button,
  ButtonSpinner,
  TogglePill,
  DateRangeFilter,
  resolvePresetRange,
  Modal,
  type RangePresetKey,
} from "../ui";

// Minimal RFC 4180 CSV parser — the export endpoint quotes any field
// containing a comma, quote, or newline (e.g. an override reason with a
// comma in it, or the raw items_json blob), so a naive `line.split(",")`
// would misalign columns on exactly the rows worth previewing.
function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else if (c === "\r") {
      // skip — the following \n closes the row
    } else {
      field += c;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  // A trailing blank line after the final \n parses as one empty field —
  // drop it so it doesn't show as a phantom last row.
  return rows.filter((r) => !(r.length === 1 && r[0] === ""));
}

const PREVIEW_ROW_CAP = 25;

function truncateCell(value: string, max = 80): { text: string; full?: string } {
  if (value.length <= max) return { text: value };
  return { text: value.slice(0, max) + "…", full: value };
}

function PreviewModal({
  loading,
  error,
  data,
  onClose,
}: {
  loading: boolean;
  error: string | null;
  data: { header: string[]; rows: string[][]; totalDataRows: number } | null;
  onClose: () => void;
}) {
  return (
    <Modal open onClose={onClose} title="Export preview" maxWidth="max-w-4xl">
      {loading ? (
        <div className="p-8">
          <Spinner />
        </div>
      ) : error ? (
        <Banner tone="bad">{error}</Banner>
      ) : data && data.rows.length === 0 ? (
        <div className="p-2 text-sm text-muted">
          No weighed orders match these filters yet — nothing would be in this export.
        </div>
      ) : data ? (
        <>
          <p className="mb-3 text-xs text-muted">
            {data.totalDataRows > data.rows.length
              ? `Showing the first ${data.rows.length} of ${data.totalDataRows.toLocaleString()} rows this export would contain.`
              : `This export contains ${data.totalDataRows.toLocaleString()} row${data.totalDataRows === 1 ? "" : "s"}.`}
          </p>
          <div className="max-h-[60vh] overflow-auto rounded-xl border border-line">
            <table className="w-full text-left text-sm">
              <thead className="sticky top-0 border-b border-line bg-cream text-xs font-semibold uppercase tracking-wide text-muted">
                <tr>
                  {data.header.map((h, i) => (
                    <th key={i} className="whitespace-nowrap px-3 py-2.5">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {data.rows.map((r, ri) => (
                  <tr key={ri} className="transition-colors duration-150 hover:bg-black/[0.03]">
                    {data.header.map((_, ci) => {
                      const cell = truncateCell(r[ci] ?? "");
                      return (
                        <td
                          key={ci}
                          className="whitespace-nowrap px-3 py-2 font-mono text-xs text-ink"
                          title={cell.full}
                        >
                          {cell.text || <span className="text-muted">—</span>}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      ) : null}
    </Modal>
  );
}

function Tile({
  label,
  value,
  tone = "ink",
  delayMs = 0,
}: {
  label: string;
  value: number;
  tone?: "ink" | "ok" | "amber" | "coral";
  delayMs?: number;
}) {
  const color = {
    ink: "text-ink",
    ok: "text-oktext",
    amber: "text-ink",
    coral: "text-badtext",
  }[tone];
  return (
    <Card hover className="animate-fade-up p-5" style={{ animationDelay: `${delayMs}ms` }}>
      <div className="text-xs font-semibold uppercase tracking-wide text-ink/60">
        {label}
      </div>
      <div className={`font-mono text-4xl font-bold ${color}`}>{value}</div>
    </Card>
  );
}

const VERDICT_OPTIONS: { value: string; label: string }[] = [
  { value: "onweight", label: "On weight" },
  { value: "under", label: "Under" },
  { value: "over", label: "Over" },
  { value: "unconfigured", label: "Unconfigured" },
];

function toggledStrSet(set: Set<string>, id: string): Set<string> {
  const next = new Set(set);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

type BranchLoadState = Branch[] | "loading" | "error";

/// One brand's filter pill — clicking it opens a dropdown of that brand's own
/// branches to multi-select from, with a "Select all" shortcut. The pill
/// itself shows a count badge for a partial selection, or a ✓ once every one
/// of the brand's branches is selected (the same as filtering by the whole
/// brand, without needing a separate "select this whole brand" affordance).
function BrandBranchPicker({
  brand,
  isOpen,
  onToggleOpen,
  onClose,
  branchState,
  onFetch,
  selected,
  onToggleBranch,
  onSelectAll,
  onSelectNone,
}: {
  brand: BrandSummary;
  isOpen: boolean;
  onToggleOpen: () => void;
  onClose: () => void;
  branchState: BranchLoadState | undefined;
  onFetch: () => void;
  selected: Set<number>;
  onToggleBranch: (branchId: number) => void;
  onSelectAll: () => void;
  onSelectNone: () => void;
}) {
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!isOpen) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) onClose();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [isOpen, onClose]);

  function handleToggle() {
    onToggleOpen();
    if (!isOpen && branchState === undefined) onFetch();
  }

  const total = Array.isArray(branchState) ? branchState.length : 0;
  const count = selected.size;
  const allSelected = total > 0 && count === total;

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        onClick={handleToggle}
        aria-haspopup="dialog"
        aria-expanded={isOpen}
        className={`flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-xs font-semibold transition-all duration-150 ease-out active:scale-[0.96] ${
          count > 0
            ? "border-green bg-green text-white card-shadow"
            : "border-line bg-white text-muted hover:-translate-y-px hover:border-ink/30 hover:text-ink"
        }`}
      >
        {brand.name}
        {count > 0 && (
          <span className="flex h-4 min-w-4 items-center justify-center rounded-full bg-white/25 px-1 text-[10px] font-bold">
            {allSelected ? "✓" : count}
          </span>
        )}
        <svg
          width="10"
          height="6"
          viewBox="0 0 10 6"
          fill="none"
          className={`shrink-0 transition-transform duration-150 ${isOpen ? "-rotate-180" : ""}`}
        >
          <path d="M1 1l4 4 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>

      {isOpen && (
        <div className="animate-pop-in absolute left-0 z-30 mt-1.5 w-64 rounded-2xl border border-line bg-white p-2 card-shadow-hover">
          {branchState === undefined || branchState === "loading" ? (
            <div className="p-3 text-center text-xs text-muted">Loading branches…</div>
          ) : branchState === "error" ? (
            <div className="p-3 text-xs text-badtext">Failed to load branches.</div>
          ) : branchState.length === 0 ? (
            <div className="p-3 text-xs text-muted">
              No branches synced for this brand yet — sync branches on the Smart Scales page
              first.
            </div>
          ) : (
            <>
              <button
                type="button"
                onClick={allSelected ? onSelectNone : onSelectAll}
                className="mb-1 block w-full rounded-lg px-2 py-1.5 text-left text-xs font-bold text-green transition-colors hover:bg-green/10"
              >
                {allSelected ? "Clear all" : `Select all (${branchState.length})`}
              </button>
              <div className="max-h-56 space-y-0.5 overflow-y-auto">
                {branchState.map((b) => (
                  <label
                    key={b.branchId}
                    className="flex cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-sm transition-colors hover:bg-black/[0.04]"
                  >
                    <input
                      type="checkbox"
                      checked={selected.has(b.branchId)}
                      onChange={() => onToggleBranch(b.branchId)}
                      className="accent-green"
                    />
                    <span className="truncate text-ink">{b.nameLocalized || b.name}</span>
                  </label>
                ))}
              </div>
            </>
          )}
        </div>
      )}
    </div>
  );
}

/// Every weighed order — item/modifier composition included — as a
/// downloadable CSV, filterable by brand(s), branch(es), verdict(s), and a
/// custom date range. "Weighed orders only" is automatic: the backend only
/// ever has a row here for an order that actually went through Confirm &
/// Dispatch. Two formats: "Order summary" (one row per order, quick to skim)
/// and "Item-level detail" (one row per order/item/modifier line — the tidy,
/// JSON-free shape suited to training a model or pivoting in a spreadsheet).
function ExportSection() {
  const [brands, setBrands] = useState<BrandSummary[]>([]);
  const [branchesByBrand, setBranchesByBrand] = useState<Record<number, BranchLoadState>>({});
  const [selectionByBrand, setSelectionByBrand] = useState<Record<number, Set<number>>>({});
  const [openBrandId, setOpenBrandId] = useState<number | null>(null);
  const [selectedVerdicts, setSelectedVerdicts] = useState<Set<string>>(new Set());
  const [rangePreset, setRangePreset] = useState<RangePresetKey>("all");
  const [customFrom, setCustomFrom] = useState("");
  const [customTo, setCustomTo] = useState("");
  const [format, setFormat] = useState<"orders" | "items">("orders");
  const [exporting, setExporting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        setBrands(await api.brands());
      } catch (e) {
        setError(e instanceof ApiError ? e.message : "Failed to load brands.");
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

  // A flat list of every selected branch across every brand — "all branches
  // of brand X" and "just these two of brand Y" both collapse into the same
  // shape the export endpoint takes, so no separate brandId filter is needed
  // (and thus no risk of the two being AND-ed together server-side).
  const selectedBranchIds = Object.values(selectionByBrand).flatMap((s) => [...s]);

  // Shared by the actual download and the preview below — both must reflect
  // the exact same filters, or "preview" would be a lie about what "Export
  // CSV" actually produces.
  function currentExportParams() {
    const range = rangePreset === "custom"
      ? {
          from: customFrom ? new Date(`${customFrom}T00:00:00`).toISOString() : undefined,
          to: customTo ? new Date(`${customTo}T23:59:59.999`).toISOString() : undefined,
        }
      : resolvePresetRange(rangePreset);
    return {
      branchIds: selectedBranchIds,
      verdicts: [...selectedVerdicts],
      from: range.from,
      to: range.to,
      format,
    };
  }

  async function exportCsv() {
    setExporting(true);
    setError(null);
    try {
      const blob = await api.exportWeighedOrders(currentExportParams());
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      const stamp = new Date().toISOString().slice(0, 10);
      a.href = url;
      a.download = `weighed-${format}-${stamp}.csv`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Export failed. Check your connection and try again.");
    } finally {
      setExporting(false);
    }
  }

  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [previewData, setPreviewData] = useState<{
    header: string[];
    rows: string[][];
    totalDataRows: number;
  } | null>(null);

  async function openPreview() {
    setPreviewOpen(true);
    setPreviewLoading(true);
    setPreviewError(null);
    setPreviewData(null);
    try {
      const text = await api.previewWeighedOrders(currentExportParams());
      const parsed = parseCsv(text);
      const [header, ...dataRows] = parsed;
      setPreviewData({
        header: header ?? [],
        rows: dataRows.slice(0, PREVIEW_ROW_CAP),
        totalDataRows: dataRows.length,
      });
    } catch (e) {
      setPreviewError(
        e instanceof ApiError ? e.message : "Couldn't load a preview. Check your connection and try again.",
      );
    } finally {
      setPreviewLoading(false);
    }
  }

  return (
    <Card className="animate-fade-up mt-4 p-5" style={{ animationDelay: "300ms" }}>
      <div className="font-display text-sm text-ink">Export weighed orders</div>
      <p className="mt-0.5 text-xs text-muted">
        A CSV of weighed orders — items, modifiers, expected/measured weight, and verdict — for
        training a weight-prediction model or item-level analytics.
      </p>

      <div className="mt-4 space-y-3">
        <div>
          <div className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted">
            Branches{selectedBranchIds.length > 0 ? ` (${selectedBranchIds.length} selected)` : " (all)"}
          </div>
          <div className="flex flex-wrap gap-1.5">
            {brands.map((b) => (
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
            ))}
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

        <div className="flex flex-wrap items-end gap-3">
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

          <div className="ml-auto flex flex-wrap items-end gap-2">
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
            <Button variant="outline" onClick={() => void openPreview()} disabled={previewLoading}>
              {previewLoading ? (
                <>
                  <ButtonSpinner /> Loading…
                </>
              ) : (
                "View"
              )}
            </Button>
            <Button variant="outline" onClick={() => void exportCsv()} disabled={exporting}>
              {exporting ? (
                <>
                  <ButtonSpinner /> Exporting…
                </>
              ) : (
                "Export CSV"
              )}
            </Button>
          </div>
        </div>
      </div>

      {error && (
        <div className="mt-3">
          <Banner tone="bad">{error}</Banner>
        </div>
      )}

      {previewOpen && (
        <PreviewModal
          loading={previewLoading}
          error={previewError}
          data={previewData}
          onClose={() => setPreviewOpen(false)}
        />
      )}
    </Card>
  );
}

export function DashboardPage() {
  const [data, setData] = useState<WeighSummary | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        setData(await api.summary(undefined, 30));
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load.");
      }
    })();
  }, []);

  if (error) return <Banner tone="bad">{error}</Banner>;
  if (!data) return <Spinner />;

  const accuracy = data.total > 0 ? Math.round((data.onWeight / data.total) * 100) : 0;
  const okPct = data.total > 0 ? (data.onWeight / data.total) * 100 : 0;
  const offPct = data.total > 0 ? (data.offWeight / data.total) * 100 : 0;
  // Not every weighed order resolves to on/under/over — one reported before
  // an expected range was configured, say, lands as neither. The bar and its
  // legend must agree on what that remainder actually is, rather than
  // silently lumping it into "off weight" (which specifically means a
  // measured packing miss, not a data-completeness gap).
  const unresolved = Math.max(0, data.total - data.onWeight - data.offWeight);
  const unresolvedPct = data.total > 0 ? (unresolved / data.total) * 100 : 0;

  return (
    <div className="animate-fade-up">
      <h1 className="font-display text-2xl text-ink">Dashboard</h1>
      <p className="mb-6 mt-1 text-sm text-muted">Weigh activity, last 30 days.</p>

      {data.total === 0 && (
        <div className="mb-5">
          <Banner tone="warn">
            No weigh events yet — figures appear here once the store tablets start
            sending data.
          </Banner>
        </div>
      )}

      <div className="mb-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Tile label="Weighed" value={data.total} delayMs={0} />
        <Tile label="On weight" value={data.onWeight} tone="ok" delayMs={60} />
        <Tile label="Underweight" value={data.under} tone="coral" delayMs={120} />
        <Tile label="Overweight" value={data.over} tone="amber" delayMs={180} />
      </div>

      <Card className="animate-fade-up p-5" style={{ animationDelay: "240ms" }}>
        <div className="mb-2 flex items-center justify-between">
          <span className="font-display text-lg">Accuracy</span>
          <span className="font-mono text-lg font-bold">{accuracy}%</span>
        </div>
        <div className="flex h-5 w-full overflow-hidden rounded-full border-2 border-ink bg-white">
          <div
            className="h-full bg-oktext transition-[width] duration-700 ease-out"
            style={{ width: `${okPct}%` }}
          />
          <div
            className="h-full bg-amber transition-[width] duration-700 ease-out"
            style={{ width: `${offPct}%` }}
          />
          {unresolved > 0 && (
            <div
              className="h-full bg-line transition-[width] duration-700 ease-out"
              style={{ width: `${unresolvedPct}%` }}
            />
          )}
        </div>
        <div className="mt-2 flex flex-wrap gap-4 text-xs font-semibold text-ink/70">
          <span>
            <span className="text-oktext">■</span> On weight ({data.onWeight})
          </span>
          <span>
            <span className="text-amber">■</span> Off weight ({data.offWeight})
          </span>
          {unresolved > 0 && (
            <span>
              <span className="text-muted">■</span> Unconfigured ({unresolved})
            </span>
          )}
        </div>
      </Card>

      <ExportSection />
    </div>
  );
}
