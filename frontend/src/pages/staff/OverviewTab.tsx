import { useMemo, useState } from "react";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Card } from "../../ui";
import { CHART_GRID, SEQUENTIAL_PRIMARY } from "../../analyticsPalette";
import type { StaffData } from "../StaffWeighingPage";
import { ChartTip, ProgressBar, SortTh, StatTile, type SortDir } from "./staffShared";
import { axisTick, businessDateOf, fmtDateTime, shortDay, useAllTimeProgress } from "./staffUtil";

type BranchSortKey = "branch" | "units" | "items" | "orders" | "days" | "avg" | "today" | "last";

interface BranchRow {
  id: string;
  label: string;
  active: boolean;
  units: number;
  items: number;
  orders: number;
  days: number;
  avg: number;
  today: number;
  last: string | null;
}

export function OverviewTab({ data }: { data: StaffData }) {
  const { entries, branches, branchesById, settings, focus } = data;
  const tz = settings.timezone;
  const today = businessDateOf(new Date(), tz, settings.business_day_cutoff_hour);
  const [sort, setSort] = useState<{ key: BranchSortKey; dir: SortDir }>({ key: "units", dir: "desc" });
  const { map: progress, error: progressError } = useAllTimeProgress(entries.length);

  const summary = useMemo(() => {
    const items = new Set<string>();
    const orders = new Set<string>();
    const activeBranches = new Set<string>();
    let todayUnits = 0;
    for (const e of entries) {
      items.add(`${e.product_id}|${e.size_label ?? ""}`);
      orders.add(e.foodics_order_id);
      activeBranches.add(e.branch_id);
      if (e.business_date === today) todayUnits++;
    }
    return { units: entries.length, items: items.size, orders: orders.size, branches: activeBranches.size, todayUnits };
  }, [entries, today]);

  const branchRows = useMemo<BranchRow[]>(() => {
    const acc = new Map<string, { units: number; items: Set<string>; orders: Set<string>; days: Set<string>; today: number; last: string | null }>();
    for (const b of branches) acc.set(b.id, { units: 0, items: new Set(), orders: new Set(), days: new Set(), today: 0, last: null });
    for (const e of entries) {
      let a = acc.get(e.branch_id);
      if (!a) {
        a = { units: 0, items: new Set(), orders: new Set(), days: new Set(), today: 0, last: null };
        acc.set(e.branch_id, a);
      }
      a.units++;
      a.items.add(`${e.product_id}|${e.size_label ?? ""}`);
      a.orders.add(e.foodics_order_id);
      a.days.add(e.business_date);
      if (e.business_date === today) a.today++;
      if (!a.last || e.weighed_at > a.last) a.last = e.weighed_at;
    }
    return [...acc.entries()].map(([id, a]) => {
      const b = branchesById.get(id);
      return {
        id,
        label: b ? `${b.code} · ${b.name}` : "Unknown branch",
        active: b?.is_active ?? false,
        units: a.units,
        items: a.items.size,
        orders: a.orders.size,
        days: a.days.size,
        avg: a.days.size ? a.units / a.days.size : 0,
        today: a.today,
        last: a.last,
      };
    });
  }, [entries, branches, branchesById, today]);

  const sortedBranches = useMemo(() => {
    const dir = sort.dir === "asc" ? 1 : -1;
    return [...branchRows].sort((a, b) => {
      const av = sort.key === "branch" ? a.label : sort.key === "last" ? a.last ?? "" : a[sort.key];
      const bv = sort.key === "branch" ? b.label : sort.key === "last" ? b.last ?? "" : b[sort.key];
      return (av < bv ? -1 : av > bv ? 1 : 0) * dir;
    });
  }, [branchRows, sort]);

  const days = useMemo(() => [...new Set(entries.map((e) => e.business_date))].sort(), [entries]);

  const daily = useMemo(() => {
    const m = new Map<string, number>();
    for (const e of entries) m.set(e.business_date, (m.get(e.business_date) ?? 0) + 1);
    return days.map((d) => ({ day: d, label: shortDay(d), units: m.get(d) ?? 0 }));
  }, [entries, days]);

  const heat = useMemo(() => {
    const cell = new Map<string, number>();
    let max = 0;
    for (const e of entries) {
      const k = `${e.branch_id}|${e.business_date}`;
      const v = (cell.get(k) ?? 0) + 1;
      cell.set(k, v);
      if (v > max) max = v;
    }
    return { cell, max };
  }, [entries]);

  const focusRows = useMemo(() => {
    return focus
      .filter((f) => f.is_active)
      .map((f) => {
        let samples = 0;
        for (const p of progress.values()) {
          const sameProduct = f.product_id ? p.product_id === f.product_id : p.product_name.trim().toLowerCase() === f.product_name.trim().toLowerCase();
          if (sameProduct && (!f.size_label || p.size_label === f.size_label)) samples += p.samples;
        }
        const branch = f.branch_id ? branchesById.get(f.branch_id) : null;
        return { ...f, samples, where: branch ? branch.code : "All branches" };
      })
      .sort((a, b) => a.samples / settings.target_samples - b.samples / settings.target_samples || b.priority - a.priority);
  }, [focus, progress, branchesById, settings.target_samples]);

  const reachedCount = useMemo(() => [...progress.values()].filter((p) => p.samples >= settings.target_samples).length, [progress, settings.target_samples]);

  const onSort = (k: BranchSortKey) =>
    setSort((s) => (s.key === k ? { key: k, dir: s.dir === "asc" ? "desc" : "asc" } : { key: k, dir: k === "branch" ? "asc" : "desc" }));

  const maxUnits = Math.max(1, ...branchRows.map((r) => r.units));

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <StatTile label="Units weighed" value={summary.units.toLocaleString()} sub="in the selected range" />
        <StatTile label="Today" value={summary.todayUnits.toLocaleString()} sub={`business day ${today}`} />
        <StatTile label="Items (by size)" value={summary.items.toLocaleString()} />
        <StatTile label="Orders" value={summary.orders.toLocaleString()} />
        <StatTile label="Branches active" value={`${summary.branches}/${branches.filter((b) => b.is_active).length}`} />
        <StatTile label="At target (all time)" value={reachedCount.toLocaleString()} sub={`≥ ${settings.target_samples} samples`} />
      </div>

      <Card className="p-5">
        <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="font-display text-sm text-ink">Branch contribution</h2>
          <span className="text-xs text-muted">Every branch is listed — a zero means it hasn't contributed in this range.</span>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[760px] text-sm">
            <thead className="border-b border-line">
              <tr>
                <SortTh k="branch" label="Branch" sort={sort} onSort={onSort} />
                <SortTh k="units" label="Units" sort={sort} onSort={onSort} align="right" />
                <th className="px-3 text-left text-xs font-semibold uppercase tracking-wide text-muted">Share</th>
                <SortTh k="items" label="Items" sort={sort} onSort={onSort} align="right" />
                <SortTh k="orders" label="Orders" sort={sort} onSort={onSort} align="right" />
                <SortTh k="days" label="Days active" sort={sort} onSort={onSort} align="right" />
                <SortTh k="avg" label="Avg / day" sort={sort} onSort={onSort} align="right" />
                <SortTh k="today" label="Today" sort={sort} onSort={onSort} align="right" />
                <SortTh k="last" label="Last weighing" sort={sort} onSort={onSort} align="right" />
              </tr>
            </thead>
            <tbody>
              {sortedBranches.map((r) => (
                <tr key={r.id} className="border-b border-line/70 last:border-0">
                  <td className="whitespace-nowrap px-3 py-2.5 font-semibold text-ink">
                    {r.label}
                    {!r.active && <span className="ml-2 text-xs font-normal text-muted">(inactive)</span>}
                  </td>
                  <td className="px-3 py-2.5 text-right font-mono font-bold">{r.units.toLocaleString()}</td>
                  <td className="px-3 py-2.5">
                    <div className="flex items-center gap-2">
                      <div className="h-2 w-28 overflow-hidden rounded-full bg-black/[0.06]">
                        <div className="h-full rounded-full" style={{ width: `${(r.units / maxUnits) * 100}%`, background: SEQUENTIAL_PRIMARY }} />
                      </div>
                      <span className="font-mono text-xs text-muted">{summary.units ? ((r.units / summary.units) * 100).toFixed(1) : "0.0"}%</span>
                    </div>
                  </td>
                  <td className="px-3 py-2.5 text-right font-mono">{r.items}</td>
                  <td className="px-3 py-2.5 text-right font-mono">{r.orders}</td>
                  <td className="px-3 py-2.5 text-right font-mono">{r.days}</td>
                  <td className="px-3 py-2.5 text-right font-mono">{r.avg ? r.avg.toFixed(1) : "0"}</td>
                  <td className="px-3 py-2.5 text-right font-mono">{r.today}</td>
                  <td className="whitespace-nowrap px-3 py-2.5 text-right font-mono text-xs text-muted">{fmtDateTime(r.last, tz)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <div className="grid gap-6 xl:grid-cols-2">
        <Card className="p-5">
          <h2 className="font-display text-sm text-ink">Units weighed per business day</h2>
          <p className="mb-3 mt-0.5 text-xs text-muted">All branches together. A business day runs {String(settings.business_day_cutoff_hour).padStart(2, "0")}:00 to {String(settings.business_day_cutoff_hour).padStart(2, "0")}:00.</p>
          {daily.length === 0 ? (
            <p className="py-10 text-center text-sm text-muted">No entries in this range.</p>
          ) : (
            <div className="h-64">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={daily} margin={{ top: 8, right: 8, left: -12, bottom: 0 }}>
                  <CartesianGrid vertical={false} stroke={CHART_GRID} />
                  <XAxis dataKey="label" tick={axisTick} tickLine={false} axisLine={{ stroke: CHART_GRID }} minTickGap={12} />
                  <YAxis allowDecimals={false} tick={axisTick} tickLine={false} axisLine={false} width={44} />
                  <Tooltip content={<ChartTip />} cursor={{ fill: "rgba(74,139,201,0.08)" }} />
                  <Bar dataKey="units" name="Units" fill={SEQUENTIAL_PRIMARY} radius={[4, 4, 0, 0]} maxBarSize={36} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          )}
        </Card>

        <Card className="p-5">
          <div className="flex items-baseline justify-between gap-2">
            <h2 className="font-display text-sm text-ink">Focus items — progress to target</h2>
            <span className="text-xs text-muted">all-time, all branches</span>
          </div>
          {progressError && <p className="mt-2 text-xs text-badtext">Couldn't load progress: {progressError}</p>}
          {focusRows.length === 0 ? (
            <p className="py-10 text-center text-sm text-muted">No focus items set — add them in Setup.</p>
          ) : (
            <ul className="mt-3 max-h-64 space-y-2 overflow-y-auto pr-1">
              {focusRows.map((f) => (
                <li
                  key={f.id}
                  className="grid grid-cols-[minmax(0,1fr)_4.5rem] items-center gap-x-3 gap-y-1 text-sm sm:grid-cols-[minmax(0,1fr)_7rem_4.5rem]"
                >
                  <span className="min-w-0">
                    <span className="font-semibold text-ink">{f.product_name}</span>
                    {f.size_label && <span className="ml-1.5 text-xs font-bold text-muted">{f.size_label}</span>}
                    <span className="ml-1.5 text-xs text-muted">· {f.where}</span>
                  </span>
                  <span className="order-last col-span-2 sm:order-none sm:col-span-1">
                    <ProgressBar value={f.samples} max={settings.target_samples} />
                  </span>
                  <span className="text-right font-mono text-xs text-muted">
                    {f.samples}/{settings.target_samples}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>

      <Card className="p-5">
        <h2 className="font-display text-sm text-ink">Branch × day</h2>
        <p className="mb-3 mt-0.5 text-xs text-muted">Units weighed per branch per business day — darker is more.</p>
        {days.length === 0 ? (
          <p className="py-6 text-center text-sm text-muted">No entries in this range.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="border-separate border-spacing-1 text-xs">
              <thead>
                <tr>
                  <th className="sticky left-0 z-10 bg-white px-2 text-left font-semibold text-muted">Branch</th>
                  {days.map((d) => (
                    <th key={d} className="whitespace-nowrap px-1 text-center font-mono font-normal text-muted">
                      {shortDay(d)}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {branches.map((b) => (
                  <tr key={b.id}>
                    <th className="sticky left-0 z-10 whitespace-nowrap bg-white px-2 text-left font-semibold text-ink">{b.code}</th>
                    {days.map((d) => {
                      const v = heat.cell.get(`${b.id}|${d}`) ?? 0;
                      const a = v ? 0.12 + 0.88 * (v / heat.max) : 0;
                      return (
                        <td
                          key={d}
                          title={`${b.code} · ${d}: ${v} units`}
                          className="h-8 min-w-[2.6rem] rounded-md text-center font-mono"
                          style={{
                            background: v ? `rgba(74,139,201,${a.toFixed(3)})` : "rgba(0,0,0,0.03)",
                            color: a > 0.55 ? "#fff" : "#17211b",
                          }}
                        >
                          {v || ""}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
