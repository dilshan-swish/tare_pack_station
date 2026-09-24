import { useMemo, useState } from "react";
import { Download, EyeOff, Eye, Trash2 } from "lucide-react";
import { Badge, Banner, Button, ButtonSpinner, Card, Select } from "../../ui";
import { askConfirm } from "../../confirmDialog";
import { describeSbError, sb, type StaffEntry } from "../../staffSupabase";
import { g1 } from "../../staffStats";
import type { StaffData } from "../StaffWeighingPage";
import { SortTh, type SortDir } from "./staffShared";
import { fmtDateTime } from "./staffUtil";
import { exportRows } from "./staffExport";

type SortKey = "weighed_at" | "branch" | "product" | "size" | "mods" | "weight" | "order" | "by";

const PAGE_SIZES = ["50", "100", "250"] as const;

export function EntriesTab({ data }: { data: StaffData }) {
  const { entries, branchesById, settings, patchEntries } = data;
  const tz = settings.timezone;
  const [sort, setSort] = useState<{ key: SortKey; dir: SortDir }>({ key: "weighed_at", dir: "desc" });
  const [pageSize, setPageSize] = useState<(typeof PAGE_SIZES)[number]>("50");
  const [page, setPage] = useState(0);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const branchLabel = (e: StaffEntry) => branchesById.get(e.branch_id)?.code ?? "?";
  const orderLabel = (e: StaffEntry) =>
    e.aggregator_name ? `${e.aggregator_name} #${e.aggregator_ref ?? ""}` : e.order_number !== null ? `Order ${e.order_number}` : e.foodics_order_id.slice(0, 8);

  const sorted = useMemo(() => {
    const dir = sort.dir === "asc" ? 1 : -1;
    const val = (e: StaffEntry): string | number => {
      switch (sort.key) {
        case "weighed_at":
          return e.weighed_at;
        case "branch":
          return branchesById.get(e.branch_id)?.code ?? "";
        case "product":
          return e.product_name.toLowerCase();
        case "size":
          return e.size_label ?? "";
        case "mods":
          return e.modifiers_label.toLowerCase();
        case "weight":
          return e.weight_g;
        case "order":
          return e.aggregator_ref ?? String(e.order_number ?? "");
        case "by":
          return e.entered_email ?? "";
      }
    };
    return [...entries].sort((a, b) => {
      const av = val(a);
      const bv = val(b);
      return (av < bv ? -1 : av > bv ? 1 : 0) * dir || (a.weighed_at < b.weighed_at ? 1 : -1);
    });
  }, [entries, sort, branchesById]);

  const size = Number(pageSize);
  const pages = Math.max(1, Math.ceil(sorted.length / size));
  const current = Math.min(page, pages - 1);
  const slice = sorted.slice(current * size, current * size + size);

  const onSort = (k: SortKey) => {
    setPage(0);
    setSort((s) => (s.key === k ? { key: k, dir: s.dir === "asc" ? "desc" : "asc" } : { key: k, dir: k === "weighed_at" || k === "weight" ? "desc" : "asc" }));
  };

  const toggleExclude = async (e: StaffEntry) => {
    setBusyId(e.id);
    setError(null);
    const patch = e.is_excluded ? { is_excluded: false, exclude_reason: null } : { is_excluded: true, exclude_reason: "Excluded by admin" };
    const { error: err } = await sb().from("weigh_entries").update(patch).eq("id", e.id);
    setBusyId(null);
    if (err) return setError(describeSbError(err));
    patchEntries([e.id], patch);
  };

  const remove = async (e: StaffEntry) => {
    const ok = await askConfirm({
      title: "Delete this entry permanently?",
      message: `${e.product_name}${e.size_label ? ` (${e.size_label})` : ""} — ${g1(e.weight_g)} g at ${branchLabel(e)}. Excluding keeps it for the record; deleting can't be undone.`,
      confirmLabel: "Delete",
      tone: "danger",
    });
    if (!ok) return;
    setBusyId(e.id);
    setError(null);
    const { error: err } = await sb().from("weigh_entries").delete().eq("id", e.id);
    setBusyId(null);
    if (err) return setError(describeSbError(err));
    patchEntries([e.id], null);
  };

  const exportAll = (kind: "csv" | "xlsx") =>
    exportRows(
      kind,
      "weigh-entries",
      ["Weighed at", "Business day", "Branch", "Item", "SKU", "Category", "Size", "Modifiers", "Weight g", "Aggregator", "Aggregator #", "Order #", "Check #", "Foodics order id", "Unit", "Entered by", "Excluded", "Exclude reason", "Note"],
      sorted.map((e) => [
        fmtDateTime(e.weighed_at, tz),
        e.business_date,
        branchLabel(e),
        e.product_name,
        e.product_sku ?? "",
        e.product_category ?? "",
        e.size_label ?? "",
        e.modifiers_label,
        e.weight_g,
        e.aggregator_name ?? "",
        e.aggregator_ref ?? "",
        e.order_number ?? "",
        e.check_number ?? "",
        e.foodics_order_id,
        e.unit_index + 1,
        e.entered_email ?? "",
        e.is_excluded ? "yes" : "no",
        e.exclude_reason ?? "",
        e.note ?? "",
      ]),
    );

  return (
    <Card className="p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-muted">
          <span className="font-mono font-bold text-ink">{sorted.length.toLocaleString()}</span> entries match the filters. Exports include all of them, in this order.
          <span className="block text-xs">Excluded entries stay hidden unless “Include excluded” is on above.</span>
        </p>
        <div className="flex gap-2">
          <Button variant="outline" onClick={() => void exportAll("csv")} disabled={!sorted.length}>
            <Download size={14} /> CSV
          </Button>
          <Button variant="outline" onClick={() => void exportAll("xlsx")} disabled={!sorted.length}>
            <Download size={14} /> Excel
          </Button>
        </div>
      </div>

      {error && (
        <div className="mt-3">
          <Banner tone="bad">{error}</Banner>
        </div>
      )}

      <div className="mt-4 overflow-x-auto">
        <table className="w-full min-w-[1000px] text-sm">
          <thead className="border-b border-line">
            <tr>
              <SortTh k="weighed_at" label="Weighed" sort={sort} onSort={onSort} />
              <SortTh k="branch" label="Branch" sort={sort} onSort={onSort} />
              <SortTh k="product" label="Item" sort={sort} onSort={onSort} />
              <SortTh k="size" label="Size" sort={sort} onSort={onSort} />
              <SortTh k="mods" label="Modifiers" sort={sort} onSort={onSort} />
              <SortTh k="weight" label="Weight" sort={sort} onSort={onSort} align="right" />
              <SortTh k="order" label="Order" sort={sort} onSort={onSort} />
              <SortTh k="by" label="Entered by" sort={sort} onSort={onSort} />
              <th className="px-3 text-right text-xs font-semibold uppercase tracking-wide text-muted">Actions</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((e) => (
              <tr key={e.id} className={`border-b border-line/70 last:border-0 ${e.is_excluded ? "opacity-55" : ""}`}>
                <td className="whitespace-nowrap px-3 py-2 font-mono text-xs text-muted">{fmtDateTime(e.weighed_at, tz)}</td>
                <td className="px-3 py-2 font-semibold">{branchLabel(e)}</td>
                <td className="max-w-[14rem] px-3 py-2">
                  <div className="truncate font-semibold text-ink">{e.product_name}</div>
                  {e.is_excluded && <Badge tone="warn">{e.exclude_reason ?? "Excluded"}</Badge>}
                </td>
                <td className="px-3 py-2 text-xs font-bold text-muted">{e.size_label ?? "—"}</td>
                <td className="max-w-[16rem] px-3 py-2 text-xs text-muted" title={e.modifiers_label}>
                  <div className="line-clamp-2">{e.modifiers_label || "—"}</div>
                </td>
                <td className="px-3 py-2 text-right font-mono font-bold">{g1(e.weight_g)} g</td>
                <td className="whitespace-nowrap px-3 py-2 font-mono text-xs">{orderLabel(e)}</td>
                <td className="max-w-[12rem] truncate px-3 py-2 text-xs text-muted">{e.entered_email ?? "—"}</td>
                <td className="whitespace-nowrap px-3 py-2 text-right">
                  <div className="inline-flex gap-1">
                    <button
                      type="button"
                      onClick={() => void toggleExclude(e)}
                      disabled={busyId === e.id}
                      title={e.is_excluded ? "Include in stats again" : "Exclude from stats"}
                      aria-label={e.is_excluded ? "Include in stats again" : "Exclude from stats"}
                      className="flex h-9 w-9 items-center justify-center rounded-full text-muted transition hover:bg-black/[0.05] hover:text-ink disabled:opacity-40"
                    >
                      {busyId === e.id ? <ButtonSpinner /> : e.is_excluded ? <Eye size={16} /> : <EyeOff size={16} />}
                    </button>
                    <button
                      type="button"
                      onClick={() => void remove(e)}
                      disabled={busyId === e.id}
                      title="Delete permanently"
                      aria-label="Delete permanently"
                      className="flex h-9 w-9 items-center justify-center rounded-full text-badtext transition hover:bg-badbg disabled:opacity-40"
                    >
                      <Trash2 size={16} />
                    </button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {sorted.length === 0 && <p className="py-10 text-center text-sm text-muted">No entries match the filters.</p>}
      </div>

      {sorted.length > 0 && (
        <div className="mt-4 flex flex-wrap items-center justify-between gap-3 text-sm">
          <div className="flex items-center gap-2 text-muted">
            Rows per page
            <Select value={pageSize} onChange={(v) => { setPageSize(v); setPage(0); }} options={PAGE_SIZES.map((p) => ({ value: p, label: p }))} />
          </div>
          <div className="flex items-center gap-2">
            <Button variant="outline" onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={current === 0}>
              Previous
            </Button>
            <span className="font-mono text-xs text-muted">
              {current + 1} / {pages}
            </span>
            <Button variant="outline" onClick={() => setPage((p) => Math.min(pages - 1, p + 1))} disabled={current >= pages - 1}>
              Next
            </Button>
          </div>
        </div>
      )}
    </Card>
  );
}
