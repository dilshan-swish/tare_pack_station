import { useCallback, useEffect, useMemo, useState } from "react";
import { RefreshCw } from "lucide-react";
import {
  Banner,
  Button,
  ButtonSpinner,
  Card,
  DateRangeFilter,
  Select,
  Spinner,
  TextInput,
  TogglePill,
  resolvePresetRange,
  toggledStrSet,
  type RangePresetKey,
} from "../ui";
import {
  describeSbError,
  loadEntries,
  sb,
  type StaffBranch,
  type StaffEntry,
  type StaffFocusItem,
  type StaffSettings,
} from "../staffSupabase";
import { outlierIds } from "../staffStats";
import { OverviewTab } from "./staff/OverviewTab";
import { ItemsTab } from "./staff/ItemsTab";
import { EntriesTab } from "./staff/EntriesTab";
import { SetupTab } from "./staff/SetupTab";

const ROW_CAP = 100_000;

type Tab = "overview" | "items" | "entries" | "setup";
const TABS: { key: Tab; label: string }[] = [
  { key: "overview", label: "Overview" },
  { key: "items", label: "Items" },
  { key: "entries", label: "Entries" },
  { key: "setup", label: "Setup" },
];

export interface StaffData {
  entries: StaffEntry[];
  branches: StaffBranch[];
  branchesById: Map<string, StaffBranch>;
  settings: StaffSettings;
  focus: StaffFocusItem[];
  reloadEntries: () => void;
  reloadReference: () => void;
  patchEntries: (ids: string[], patch: Partial<StaffEntry> | null) => void;
}

export function StaffWeighingPage() {
  return <StaffDashboard />;
}

function PageHeader() {
  return (
    <div className="mb-6">
      <h1 className="font-display text-2xl text-ink">Staff Weighing</h1>
      <p className="mt-1 max-w-2xl text-sm text-muted">
        Item weights entered by branch staff in the weigh app — per item, size and modifier, with every branch's
        contribution.
      </p>
    </div>
  );
}

function toRange(preset: RangePresetKey, from: string, to: string): { from?: string; to?: string } {
  if (preset !== "custom") return resolvePresetRange(preset);
  const parse = (s: string, end: boolean) => {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    if (!m) return undefined;
    const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
    if (end) d.setHours(23, 59, 59, 999);
    return d.toISOString();
  };
  return { from: parse(from, false), to: parse(to, true) };
}

function StaffDashboard() {
  const [tab, setTab] = useState<Tab>("overview");
  const [branches, setBranches] = useState<StaffBranch[]>([]);
  const [settings, setSettings] = useState<StaffSettings | null>(null);
  const [focus, setFocus] = useState<StaffFocusItem[]>([]);
  const [refError, setRefError] = useState<string | null>(null);
  const [refTick, setRefTick] = useState(0);

  const [preset, setPreset] = useState<RangePresetKey>("30d");
  const [customFrom, setCustomFrom] = useState("");
  const [customTo, setCustomTo] = useState("");
  const [entries, setEntries] = useState<StaffEntry[] | null>(null);
  const [truncated, setTruncated] = useState(false);
  const [loadingCount, setLoadingCount] = useState<number | null>(null);
  const [entriesError, setEntriesError] = useState<string | null>(null);
  const [entriesTick, setEntriesTick] = useState(0);
  const [autoRefresh, setAutoRefresh] = useState(false);

  const [branchSel, setBranchSel] = useState<Set<string>>(new Set());
  const [itemQuery, setItemQuery] = useState("");
  const [category, setCategory] = useState("__all");
  const [size, setSize] = useState("__all");
  const [modQuery, setModQuery] = useState("");
  const [includeExcluded, setIncludeExcluded] = useState(false);
  const [hideOutliers, setHideOutliers] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [b, s, f] = await Promise.all([
          sb().from("branches").select("*").order("code"),
          sb().from("app_settings").select("*").maybeSingle(),
          sb().from("focus_items").select("*").order("priority", { ascending: false }),
        ]);
        if (b.error) throw b.error;
        if (s.error) throw s.error;
        if (f.error) throw f.error;
        if (cancelled) return;
        setBranches((b.data ?? []) as StaffBranch[]);
        const row = (s.data ?? {}) as Record<string, unknown>;
        setSettings({
          target_samples: Number(row.target_samples ?? 200),
          min_weight_g: Number(row.min_weight_g ?? 1),
          max_weight_g: Number(row.max_weight_g ?? 5000),
          business_day_cutoff_hour: Number(row.business_day_cutoff_hour ?? 6),
          timezone: String(row.timezone ?? "Asia/Kuwait"),
          edit_window_hours: Number(row.edit_window_hours ?? 48),
          skip_categories: Array.isArray(row.skip_categories) ? (row.skip_categories as string[]) : [],
          skip_price_at_or_below: Number(row.skip_price_at_or_below ?? 0.7),
        });
        setFocus(((f.data ?? []) as StaffFocusItem[]).map((x) => ({ ...x, priority: Number(x.priority) })));
        setRefError(null);
      } catch (e) {
        if (!cancelled) setRefError(describeSbError(e, "Couldn't load branches/settings."));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [refTick]);

  useEffect(() => {
    if (preset === "custom" && (!customFrom || !customTo)) return;
    let cancelled = false;
    setEntriesError(null);
    setLoadingCount(0);
    // Resolved at fetch time, so "Today"/"Last 7 days" keep meaning what they
    // say on every refresh of a page left open all day.
    loadEntries(toRange(preset, customFrom, customTo), ROW_CAP, (n) => !cancelled && setLoadingCount(n))
      .then(({ rows, truncated: t }) => {
        if (cancelled) return;
        setEntries(rows);
        setTruncated(t);
      })
      .catch((e) => !cancelled && setEntriesError(describeSbError(e, "Couldn't load entries.")))
      .finally(() => !cancelled && setLoadingCount(null));
    return () => {
      cancelled = true;
    };
  }, [preset, customFrom, customTo, entriesTick]);

  useEffect(() => {
    if (!autoRefresh) return;
    const t = window.setInterval(() => setEntriesTick((x) => x + 1), 60_000);
    return () => window.clearInterval(t);
  }, [autoRefresh]);

  const branchesById = useMemo(() => new Map(branches.map((b) => [b.id, b])), [branches]);

  const categories = useMemo(
    () => [...new Set((entries ?? []).map((e) => e.product_category).filter((c): c is string => !!c))].sort(),
    [entries],
  );
  const sizes = useMemo(
    () => [...new Set((entries ?? []).map((e) => e.size_label).filter((c): c is string => !!c))].sort(),
    [entries],
  );

  const filtered = useMemo(() => {
    if (!entries) return [];
    const iq = itemQuery.trim().toLowerCase();
    const mq = modQuery.trim().toLowerCase();
    const base = entries.filter(
      (e) =>
        (includeExcluded || !e.is_excluded) &&
        (branchSel.size === 0 || branchSel.has(e.branch_id)) &&
        (!iq || e.product_name.toLowerCase().includes(iq) || (e.product_sku ?? "").toLowerCase().includes(iq)) &&
        (category === "__all" || e.product_category === category) &&
        (size === "__all" || (size === "__none" ? !e.size_label : e.size_label === size)) &&
        (!mq || e.modifiers_label.toLowerCase().includes(mq)),
    );
    if (!hideOutliers) return base;
    const out = outlierIds(base, "size");
    return base.filter((e) => !out.has(e.id));
  }, [entries, includeExcluded, branchSel, itemQuery, category, size, modQuery, hideOutliers]);

  const patchEntries = useCallback((ids: string[], patch: Partial<StaffEntry> | null) => {
    const set = new Set(ids);
    setEntries((rows) =>
      rows ? (patch === null ? rows.filter((r) => !set.has(r.id)) : rows.map((r) => (set.has(r.id) ? { ...r, ...patch } : r))) : rows,
    );
  }, []);

  const anyFilter =
    branchSel.size > 0 || !!itemQuery || category !== "__all" || size !== "__all" || !!modQuery || includeExcluded || hideOutliers;

  const data: StaffData | null = settings
    ? {
        entries: filtered,
        branches,
        branchesById,
        settings,
        focus,
        reloadEntries: () => setEntriesTick((x) => x + 1),
        reloadReference: () => setRefTick((x) => x + 1),
        patchEntries,
      }
    : null;

  return (
    <div className="animate-fade-up">
      <PageHeader />

      {refError && (
        <div className="mb-4">
          <Banner tone="bad">
            {refError}{" "}
            <button type="button" className="underline" onClick={() => setRefTick((x) => x + 1)}>
              Retry
            </button>
          </Banner>
        </div>
      )}

      <Card className="p-5">
        <div className="flex items-center justify-between gap-2">
          <div className="font-display text-sm text-ink">Filters</div>
          <div className="flex items-center gap-2">
            {anyFilter && (
              <Button
                variant="ghost"
                onClick={() => {
                  setBranchSel(new Set());
                  setItemQuery("");
                  setCategory("__all");
                  setSize("__all");
                  setModQuery("");
                  setIncludeExcluded(false);
                  setHideOutliers(false);
                }}
              >
                Clear filters
              </Button>
            )}
            <TogglePill active={autoRefresh} onClick={() => setAutoRefresh((a) => !a)}>
              Auto-refresh
            </TogglePill>
            <Button variant="outline" onClick={() => setEntriesTick((x) => x + 1)} disabled={loadingCount !== null}>
              {loadingCount !== null ? <ButtonSpinner /> : <RefreshCw size={14} />} Refresh
            </Button>
          </div>
        </div>

        <div className="mt-4">
          <span className="mb-1.5 block text-xs font-semibold uppercase tracking-wide text-muted">
            Branches{branchSel.size ? ` (${branchSel.size})` : " (all)"}
          </span>
          <div className="flex flex-wrap gap-1.5">
            {branches.map((b) => (
              <TogglePill key={b.id} active={branchSel.has(b.id)} onClick={() => setBranchSel((s) => toggledStrSet(s, b.id))}>
                {b.code} · {b.name}
              </TogglePill>
            ))}
          </div>
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label className="block">
            <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Item or SKU</span>
            <TextInput value={itemQuery} onChange={(e) => setItemQuery(e.target.value)} placeholder="e.g. Toasts Duo Combo" />
          </label>
          <label className="block">
            <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Modifier contains</span>
            <TextInput value={modQuery} onChange={(e) => setModQuery(e.target.value)} placeholder="e.g. Curly Fries" />
          </label>
          <div>
            <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Category</span>
            <Select
              value={category}
              onChange={setCategory}
              options={[{ value: "__all", label: "All categories" }, ...categories.map((c) => ({ value: c, label: c }))]}
            />
          </div>
          <div>
            <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Size</span>
            <Select
              value={size}
              onChange={setSize}
              options={[
                { value: "__all", label: "All sizes" },
                ...sizes.map((s) => ({ value: s, label: s })),
                { value: "__none", label: "No size (standalone)" },
              ]}
            />
          </div>
        </div>

        <div className="mt-4 flex flex-wrap items-end justify-between gap-3 border-t border-line pt-4">
          <DateRangeFilter
            preset={preset}
            onPresetChange={setPreset}
            customFrom={customFrom}
            customTo={customTo}
            onCustomChange={(f, t) => {
              setCustomFrom(f);
              setCustomTo(t);
            }}
          />
          <div className="flex flex-wrap gap-2">
            <TogglePill active={hideOutliers} onClick={() => setHideOutliers((v) => !v)}>
              Hide outliers (Tukey)
            </TogglePill>
            <TogglePill active={includeExcluded} onClick={() => setIncludeExcluded((v) => !v)}>
              Include excluded
            </TogglePill>
          </div>
        </div>
      </Card>

      {truncated && (
        <div className="mt-4">
          <Banner tone="warn">Showing the newest {ROW_CAP.toLocaleString()} entries only — narrow the date range to see everything.</Banner>
        </div>
      )}
      {entriesError && (
        <div className="mt-4">
          <Banner tone="bad">
            {entriesError}{" "}
            <button type="button" className="underline" onClick={() => setEntriesTick((x) => x + 1)}>
              Retry
            </button>
          </Banner>
        </div>
      )}

      <div className="mt-6 flex flex-wrap gap-1.5" role="tablist">
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            role="tab"
            aria-selected={tab === t.key}
            onClick={() => setTab(t.key)}
            className={`min-h-[40px] rounded-full px-4 text-sm font-semibold transition-all ${
              tab === t.key ? "bg-green text-white card-shadow" : "bg-white text-muted hover:text-ink"
            }`}
          >
            {t.label}
          </button>
        ))}
        {entries && (
          <span className="ml-auto self-center font-mono text-xs text-muted">
            {filtered.length.toLocaleString()} of {entries.length.toLocaleString()} entries
          </span>
        )}
      </div>

      <div className="mt-4">
        {!data || entries === null ? (
          loadingCount !== null ? (
            <div className="flex flex-col items-center gap-2 py-16 text-sm text-muted">
              <Spinner />
              {loadingCount > 0 && <span>Loaded {loadingCount.toLocaleString()} entries…</span>}
            </div>
          ) : preset === "custom" && (!customFrom || !customTo) ? (
            <Card className="p-6 text-center text-sm text-muted">Pick both dates for the custom range.</Card>
          ) : (
            <Spinner />
          )
        ) : tab === "overview" ? (
          <OverviewTab data={data} />
        ) : tab === "items" ? (
          <ItemsTab data={data} />
        ) : tab === "entries" ? (
          <EntriesTab data={data} />
        ) : (
          <SetupTab data={data} />
        )}
      </div>
    </div>
  );
}
