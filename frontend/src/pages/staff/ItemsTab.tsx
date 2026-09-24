import { useMemo, useState } from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  ReferenceLine,
  ResponsiveContainer,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
  ZAxis,
} from "recharts";
import { Download } from "lucide-react";
import { Banner, Button, ButtonSpinner, Card, Modal, TextInput } from "../../ui";
import { askConfirm } from "../../confirmDialog";
import { CHART_GRID, SEQUENTIAL_PRIMARY, STATUS_COLORS } from "../../analyticsPalette";
import { describeSbError, sb, type StaffEntry } from "../../staffSupabase";
import { GROUP_MODE_LABELS, g1, groupDetail, groupKey, histogram, outlierIds, summarize, type GroupMode, type Summary } from "../../staffStats";
import type { StaffData } from "../StaffWeighingPage";
import { ChartTip, ProgressBar, SortTh, StatTile, type SortDir } from "./staffShared";
import { axisTick, fmtDateTime, useAllTimeProgress } from "./staffUtil";
import { exportRows } from "./staffExport";

type SortKey = "name" | "detail" | "n" | "target" | "min" | "max" | "mean" | "median" | "sd" | "cv" | "p10" | "p90" | "iqr" | "branches" | "last";

interface GroupRow {
  key: string;
  productId: string;
  name: string;
  category: string | null;
  detail: string;
  sizeLabel: string | null;
  entries: StaffEntry[];
  s: Summary;
  branches: number;
  last: string;
  target: number | null;
}

export function ItemsTab({ data }: { data: StaffData }) {
  const { entries, settings } = data;
  const [mode, setMode] = useState<GroupMode>("size");
  const [q, setQ] = useState("");
  const [sort, setSort] = useState<{ key: SortKey; dir: SortDir }>({ key: "n", dir: "desc" });
  const [open, setOpen] = useState<GroupRow | null>(null);
  const { map: progress } = useAllTimeProgress(entries.length);

  const rows = useMemo<GroupRow[]>(() => {
    const groups = new Map<string, StaffEntry[]>();
    for (const e of entries) {
      const k = groupKey(e, mode);
      const g = groups.get(k);
      if (g) g.push(e);
      else groups.set(k, [e]);
    }
    return [...groups.entries()].map(([key, g]) => {
      const first = g[0];
      let target: number | null = null;
      if (mode === "size") target = progress.get(`${first.product_id}|${first.size_label ?? ""}`)?.samples ?? 0;
      else if (mode === "item") {
        target = 0;
        for (const p of progress.values()) if (p.product_id === first.product_id) target += p.samples;
      }
      return {
        key,
        productId: first.product_id,
        name: first.product_name,
        category: first.product_category,
        detail: groupDetail(first, mode),
        sizeLabel: mode === "size" ? first.size_label : null,
        entries: g,
        s: summarize(g.map((e) => e.weight_g))!,
        branches: new Set(g.map((e) => e.branch_id)).size,
        last: g.reduce((m, e) => (e.weighed_at > m ? e.weighed_at : m), ""),
        target,
      };
    });
  }, [entries, mode, progress]);

  const visible = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const list = needle ? rows.filter((r) => `${r.name} ${r.detail} ${r.category ?? ""}`.toLowerCase().includes(needle)) : rows;
    const dir = sort.dir === "asc" ? 1 : -1;
    const val = (r: GroupRow): string | number => {
      switch (sort.key) {
        case "name":
          return r.name.toLowerCase();
        case "detail":
          return r.detail.toLowerCase();
        case "n":
          return r.s.n;
        case "target":
          return r.target ?? -1;
        case "branches":
          return r.branches;
        case "last":
          return r.last;
        default:
          return r.s[sort.key];
      }
    };
    return [...list].sort((a, b) => {
      const av = val(a);
      const bv = val(b);
      return (av < bv ? -1 : av > bv ? 1 : 0) * dir || a.name.localeCompare(b.name);
    });
  }, [rows, q, sort]);

  const onSort = (k: SortKey) =>
    setSort((s) => (s.key === k ? { key: k, dir: s.dir === "asc" ? "desc" : "asc" } : { key: k, dir: k === "name" || k === "detail" ? "asc" : "desc" }));

  const exportStats = (kind: "csv" | "xlsx") =>
    exportRows(
      kind,
      `item-stats-${mode}`,
      [
        "Item",
        ...(mode === "item" ? [] : [mode === "size" ? "Size" : "Modifiers"]),
        "Category",
        "Samples (range)",
        "Samples (all time)",
        "Min g",
        "Max g",
        "Mean g",
        "Median g",
        "SD g",
        "CV %",
        "P10 g",
        "P90 g",
        "IQR g",
        "Branches",
        "Last weighed",
      ],
      visible.map((r) =>
        [
          r.name,
          ...(mode === "item" ? [] : [r.detail]),
          r.category ?? "",
          r.s.n,
          r.target ?? "",
          r.s.min,
          r.s.max,
          round1(r.s.mean),
          round1(r.s.median),
          round1(r.s.sd),
          round1(r.s.cv),
          round1(r.s.p10),
          round1(r.s.p90),
          round1(r.s.iqr),
          r.branches,
          fmtDateTime(r.last, settings.timezone),
        ],
      ),
    );

  return (
    <Card className="p-5">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Group by</span>
          <div className="flex flex-wrap gap-1.5">
            {(Object.keys(GROUP_MODE_LABELS) as GroupMode[]).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => setMode(m)}
                aria-pressed={mode === m}
                className={`min-h-[36px] rounded-full border px-3 text-xs font-semibold transition-all ${
                  mode === m ? "border-green bg-green text-white card-shadow" : "border-line bg-white text-muted hover:text-ink"
                }`}
              >
                {GROUP_MODE_LABELS[m]}
              </button>
            ))}
          </div>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <div className="w-64 max-w-full">
            <TextInput value={q} onChange={(e) => setQ(e.target.value)} placeholder="Filter this table…" />
          </div>
          <Button variant="outline" onClick={() => exportStats("csv")} disabled={!visible.length}>
            <Download size={14} /> CSV
          </Button>
          <Button variant="outline" onClick={() => exportStats("xlsx")} disabled={!visible.length}>
            <Download size={14} /> Excel
          </Button>
        </div>
      </div>

      <p className="mt-3 text-xs text-muted">
        {visible.length.toLocaleString()} {mode === "item" ? "items" : "groups"} · click a row for its distribution, branches and modifiers.
        {mode !== "mods" && ` Target = ${settings.target_samples} samples per item + size, counted all-time across every branch.`}
      </p>

      <div className="mt-3 overflow-x-auto">
        <table className="w-full min-w-[1080px] text-sm">
          <thead className="border-b border-line">
            <tr>
              <SortTh k="name" label="Item" sort={sort} onSort={onSort} />
              {mode !== "item" && <SortTh k="detail" label={mode === "size" ? "Size" : "Modifiers"} sort={sort} onSort={onSort} />}
              <SortTh k="n" label="n" sort={sort} onSort={onSort} align="right" />
              {mode !== "mods" && <SortTh k="target" label="Target" sort={sort} onSort={onSort} />}
              <SortTh k="min" label="Min" sort={sort} onSort={onSort} align="right" />
              <SortTh k="max" label="Max" sort={sort} onSort={onSort} align="right" />
              <SortTh k="mean" label="Mean" sort={sort} onSort={onSort} align="right" />
              <SortTh k="median" label="Median" sort={sort} onSort={onSort} align="right" />
              <SortTh k="sd" label="SD" sort={sort} onSort={onSort} align="right" />
              <SortTh k="cv" label="CV %" sort={sort} onSort={onSort} align="right" />
              <SortTh k="p10" label="P10" sort={sort} onSort={onSort} align="right" />
              <SortTh k="p90" label="P90" sort={sort} onSort={onSort} align="right" />
              <SortTh k="iqr" label="IQR" sort={sort} onSort={onSort} align="right" />
              <SortTh k="branches" label="Branches" sort={sort} onSort={onSort} align="right" />
              <SortTh k="last" label="Last" sort={sort} onSort={onSort} align="right" />
            </tr>
          </thead>
          <tbody>
            {visible.map((r) => (
              <tr
                key={r.key}
                onClick={() => setOpen(r)}
                onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), setOpen(r))}
                tabIndex={0}
                className="cursor-pointer border-b border-line/70 transition-colors last:border-0 hover:bg-black/[0.025] focus:bg-black/[0.035] focus:outline-none"
              >
                <td className="max-w-[16rem] px-3 py-2.5">
                  <div className="truncate font-semibold text-ink">{r.name}</div>
                  {r.category && <div className="truncate text-xs text-muted">{r.category}</div>}
                </td>
                {mode !== "item" && <td className="max-w-[18rem] truncate px-3 py-2.5 text-xs font-semibold text-muted">{r.detail}</td>}
                <td className="px-3 py-2.5 text-right font-mono font-bold">{r.s.n}</td>
                {mode !== "mods" && (
                  <td className="px-3 py-2.5">
                    <div className="flex items-center gap-2">
                      <ProgressBar value={r.target ?? 0} max={settings.target_samples} />
                      <span className="whitespace-nowrap font-mono text-xs text-muted">{r.target ?? 0}</span>
                    </div>
                  </td>
                )}
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.min)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.max)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.mean)}</td>
                <td className="px-3 py-2.5 text-right font-mono font-bold">{g1(r.s.median)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.sd)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.cv)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.p10)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.p90)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{g1(r.s.iqr)}</td>
                <td className="px-3 py-2.5 text-right font-mono">{r.branches}</td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right font-mono text-xs text-muted">{fmtDateTime(r.last, settings.timezone)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {visible.length === 0 && <p className="py-10 text-center text-sm text-muted">No weighed items match the filters.</p>}
      </div>

      {open && <ItemDetail row={open} mode={mode} data={data} onClose={() => setOpen(null)} />}
    </Card>
  );
}

const round1 = (n: number) => Math.round(n * 10) / 10;

function ItemDetail({ row, mode, data, onClose }: { row: GroupRow; mode: GroupMode; data: StaffData; onClose: () => void }) {
  const { branchesById, settings, patchEntries } = data;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const s = row.s;
  const outliers = useMemo(() => outlierIds(row.entries, mode === "mods" ? "mods" : "size"), [row.entries, mode]);

  const bins = useMemo(
    () => histogram(row.entries.map((e) => e.weight_g)).map((b) => ({ ...b, label: `${g1(b.from)}–${g1(b.to)} g`, mid: (b.from + b.to) / 2 })),
    [row.entries],
  );
  const points = useMemo(
    () =>
      row.entries.map((e) => ({
        t: new Date(e.weighed_at).getTime(),
        w: e.weight_g,
        branch: branchesById.get(e.branch_id)?.code ?? "?",
        mods: e.modifiers_label,
        outlier: outliers.has(e.id),
      })),
    [row.entries, branchesById, outliers],
  );

  const byBranch = useMemo(() => {
    const m = new Map<string, number[]>();
    for (const e of row.entries) {
      const arr = m.get(e.branch_id);
      if (arr) arr.push(e.weight_g);
      else m.set(e.branch_id, [e.weight_g]);
    }
    return [...m.entries()]
      .map(([id, vals]) => ({ id, label: branchesById.get(id) ? `${branchesById.get(id)!.code} · ${branchesById.get(id)!.name}` : "Unknown", s: summarize(vals)! }))
      .sort((a, b) => b.s.n - a.s.n);
  }, [row.entries, branchesById]);

  const byMods = useMemo(() => {
    const m = new Map<string, number[]>();
    for (const e of row.entries) {
      const k = e.modifiers_label || "No modifiers";
      const arr = m.get(k);
      if (arr) arr.push(e.weight_g);
      else m.set(k, [e.weight_g]);
    }
    return [...m.entries()].map(([label, vals]) => ({ label, s: summarize(vals)! })).sort((a, b) => b.s.n - a.s.n);
  }, [row.entries]);

  const excludeOutliers = async () => {
    const ids = [...outliers];
    if (!ids.length) return;
    const ok = await askConfirm({
      title: `Exclude ${ids.length} outlier${ids.length === 1 ? "" : "s"}?`,
      message: "They stay in the database (and can be included again from the Entries tab) but drop out of every statistic.",
      confirmLabel: "Exclude",
      tone: "danger",
    });
    if (!ok) return;
    setBusy(true);
    setError(null);
    const { error: err } = await sb().from("weigh_entries").update({ is_excluded: true, exclude_reason: "Outlier (Tukey)" }).in("id", ids);
    setBusy(false);
    if (err) return setError(describeSbError(err));
    patchEntries(ids, { is_excluded: true, exclude_reason: "Outlier (Tukey)" });
    onClose();
  };

  const tz = settings.timezone;
  return (
    <Modal open onClose={onClose} title={`${row.name}${row.detail && row.detail !== "—" ? ` · ${row.detail}` : ""}`} maxWidth="max-w-5xl">
      <div className="space-y-5">
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-5 lg:grid-cols-9">
          <StatTile label="n" value={s.n} />
          <StatTile label="Min" value={g1(s.min)} />
          <StatTile label="Max" value={g1(s.max)} />
          <StatTile label="Mean" value={g1(s.mean)} />
          <StatTile label="Median" value={g1(s.median)} />
          <StatTile label="SD" value={g1(s.sd)} />
          <StatTile label="CV %" value={g1(s.cv)} />
          <StatTile label="P10" value={g1(s.p10)} />
          <StatTile label="P90" value={g1(s.p90)} />
        </div>

        {error && <Banner tone="bad">{error}</Banner>}

        <div className="grid gap-5 lg:grid-cols-2">
          <div>
            <h3 className="text-sm font-bold text-ink">Distribution</h3>
            <p className="text-xs text-muted">How many units fell in each weight band. Dashed line = median.</p>
            <div className="mt-2 h-60">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={bins} margin={{ top: 8, right: 8, left: -12, bottom: 0 }} barCategoryGap={2}>
                  <CartesianGrid vertical={false} stroke={CHART_GRID} />
                  <XAxis dataKey="mid" type="number" domain={["dataMin", "dataMax"]} tickFormatter={(v: number) => g1(v)} tick={axisTick} tickLine={false} axisLine={{ stroke: CHART_GRID }} />
                  <YAxis allowDecimals={false} tick={axisTick} tickLine={false} axisLine={false} width={40} />
                  <Tooltip content={<ChartTip formatLabel={(_, p) => String(p?.label ?? "")} />} cursor={{ fill: "rgba(74,139,201,0.08)" }} />
                  <ReferenceLine x={s.median} stroke="#17211b" strokeOpacity={0.5} strokeDasharray="4 4" />
                  <Bar dataKey="count" name="Units" fill={SEQUENTIAL_PRIMARY} radius={[4, 4, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </div>
          <div>
            <h3 className="text-sm font-bold text-ink">Over time</h3>
            <p className="flex flex-wrap items-center gap-3 text-xs text-muted">
              <span className="flex items-center gap-1"><span className="inline-block h-2.5 w-2.5 rounded-full" style={{ background: SEQUENTIAL_PRIMARY }} /> weighing</span>
              <span className="flex items-center gap-1"><span className="inline-block h-2.5 w-2.5 rounded-full" style={{ background: STATUS_COLORS.under }} /> outlier ({outliers.size})</span>
            </p>
            <div className="mt-2 h-60">
              <ResponsiveContainer width="100%" height="100%">
                <ScatterChart margin={{ top: 8, right: 8, left: -12, bottom: 0 }}>
                  <CartesianGrid stroke={CHART_GRID} />
                  <XAxis
                    dataKey="t"
                    type="number"
                    domain={["dataMin", "dataMax"]}
                    tickFormatter={(v: number) => new Date(v).toLocaleDateString(undefined, { month: "short", day: "numeric" })}
                    tick={axisTick}
                    tickLine={false}
                    axisLine={{ stroke: CHART_GRID }}
                  />
                  <YAxis dataKey="w" type="number" domain={["auto", "auto"]} tick={axisTick} tickLine={false} axisLine={false} width={44} />
                  <ZAxis range={[36, 36]} />
                  <Tooltip
                    cursor={{ strokeDasharray: "3 3" }}
                    content={({ active, payload }) => {
                      const p = payload?.[0]?.payload as (typeof points)[number] | undefined;
                      if (!active || !p) return null;
                      return (
                        <div className="rounded-lg border border-line bg-white px-3 py-2 text-xs card-shadow-hover">
                          <div className="font-mono font-bold text-ink">{g1(p.w)} g{p.outlier ? " · outlier" : ""}</div>
                          <div className="text-muted">{p.branch} · {fmtDateTime(new Date(p.t).toISOString(), tz)}</div>
                          {p.mods && <div className="mt-0.5 max-w-[16rem] text-muted">{p.mods}</div>}
                        </div>
                      );
                    }}
                  />
                  <ReferenceLine y={s.median} stroke="#17211b" strokeOpacity={0.5} strokeDasharray="4 4" />
                  <Scatter data={points.filter((p) => !p.outlier)} fill={SEQUENTIAL_PRIMARY} fillOpacity={0.75} name="Weighing" />
                  <Scatter data={points.filter((p) => p.outlier)} fill={STATUS_COLORS.under} name="Outlier" />
                </ScatterChart>
              </ResponsiveContainer>
            </div>
          </div>
        </div>

        <div className="grid gap-5 lg:grid-cols-2">
          <BreakdownTable title="By branch" rows={byBranch.map((b) => ({ label: b.label, s: b.s }))} />
          <BreakdownTable title="By modifier combination" rows={byMods} />
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
          <p className="text-xs text-muted">
            Outliers use Tukey's fences (outside Q1 − 1.5·IQR … Q3 + 1.5·IQR){row.entries.length < 8 ? " — needs 8+ samples, so none are flagged yet." : "."}
          </p>
          <Button variant="danger" onClick={() => void excludeOutliers()} disabled={busy || outliers.size === 0}>
            {busy && <ButtonSpinner />} Exclude {outliers.size} outlier{outliers.size === 1 ? "" : "s"}
          </Button>
        </div>
      </div>
    </Modal>
  );
}

function BreakdownTable({ title, rows }: { title: string; rows: { label: string; s: Summary }[] }) {
  return (
    <div>
      <h3 className="text-sm font-bold text-ink">{title}</h3>
      <div className="mt-2 max-h-64 overflow-auto rounded-xl border border-line">
        <table className="w-full text-xs">
          <thead className="sticky top-0 bg-page">
            <tr className="text-left font-semibold uppercase tracking-wide text-muted">
              <th className="px-3 py-2">{title.replace("By ", "")}</th>
              <th className="px-3 py-2 text-right">n</th>
              <th className="px-3 py-2 text-right">Median</th>
              <th className="px-3 py-2 text-right">Mean</th>
              <th className="px-3 py-2 text-right">SD</th>
              <th className="px-3 py-2 text-right">Min–Max</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.label} className="border-t border-line/70">
                <td className="max-w-[14rem] px-3 py-2 text-ink">{r.label}</td>
                <td className="px-3 py-2 text-right font-mono font-bold">{r.s.n}</td>
                <td className="px-3 py-2 text-right font-mono">{g1(r.s.median)}</td>
                <td className="px-3 py-2 text-right font-mono">{g1(r.s.mean)}</td>
                <td className="px-3 py-2 text-right font-mono">{g1(r.s.sd)}</td>
                <td className="whitespace-nowrap px-3 py-2 text-right font-mono">
                  {g1(r.s.min)}–{g1(r.s.max)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
