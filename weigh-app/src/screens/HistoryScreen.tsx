import { useCallback, useEffect, useState } from "react";
import { Check, Pencil, RefreshCw, Trash2, X } from "lucide-react";
import { useSession } from "../state/session";
import { useToast } from "../state/toast";
import { describeError, supabase } from "../lib/supabase";
import { businessDate, clock } from "../lib/format";
import { fmt, parseWeight } from "../lib/rules";
import type { EntryRow } from "../lib/types";
import { Button, Pill, Sheet, Spinner } from "../components/ui";

const PAGE = 500;

/** The branch's own weighings for a business day, with fixes for typos. */
export function HistoryScreen() {
  const { settings, refreshProgress } = useSession();
  const toast = useToast();
  const [dayOffset, setDayOffset] = useState(0);
  const [rows, setRows] = useState<EntryRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [editing, setEditing] = useState<{ id: string; value: string; error?: string } | null>(null);
  const [deleting, setDeleting] = useState<EntryRow | null>(null);
  const [busy, setBusy] = useState(false);

  const day = businessDate(settings.timezone, settings.business_day_cutoff_hour, new Date(), -dayOffset);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from("weigh_entries")
      .select(
        "id, foodics_order_id, order_number, aggregator_name, aggregator_ref, line_key, unit_index, product_id, product_name, size_label, modifiers_label, weight_g, note, weighed_at, created_at, business_date",
      )
      .eq("business_date", day)
      .order("weighed_at", { ascending: false })
      .limit(PAGE);
    setLoading(false);
    if (err) {
      setError(describeError(err, "Couldn't load your weighings."));
      return;
    }
    setRows((data ?? []).map((r) => ({ ...r, weight_g: Number(r.weight_g) })) as EntryRow[]);
  }, [day]);

  useEffect(() => {
    setRows(null);
    void load();
  }, [load]);

  const editable = (r: EntryRow) =>
    Date.now() - new Date(r.created_at).getTime() < settings.edit_window_hours * 3600_000;

  const saveEdit = async () => {
    if (!editing) return;
    const v = parseWeight(editing.value);
    if (v === null || v < settings.min_weight_g || v > settings.max_weight_g) {
      setEditing({ ...editing, error: `Must be ${fmt(settings.min_weight_g)}–${fmt(settings.max_weight_g)} g.` });
      return;
    }
    setBusy(true);
    const { data, error: err } = await supabase
      .from("weigh_entries")
      .update({ weight_g: v })
      .eq("id", editing.id)
      .select("id, weight_g");
    setBusy(false);
    if (err || !data?.length) {
      setEditing({ ...editing, error: err ? describeError(err) : "This entry can no longer be changed." });
      return;
    }
    setRows((rs) => rs?.map((r) => (r.id === editing.id ? { ...r, weight_g: Number(data[0].weight_g) } : r)) ?? rs);
    setEditing(null);
    toast("Weight updated", "ok");
  };

  const confirmDelete = async () => {
    if (!deleting) return;
    setBusy(true);
    const { data, error: err } = await supabase.from("weigh_entries").delete().eq("id", deleting.id).select("id");
    setBusy(false);
    if (err || !data?.length) {
      toast(err ? `Couldn't delete: ${describeError(err)}` : "This entry can no longer be deleted.", "bad");
      setDeleting(null);
      return;
    }
    setRows((rs) => rs?.filter((r) => r.id !== deleting.id) ?? rs);
    setDeleting(null);
    void refreshProgress();
    toast("Entry deleted", "ok");
  };

  const distinctItems = new Set(rows?.map((r) => `${r.product_id}|${r.size_label ?? ""}`)).size;

  return (
    <div className="mx-auto max-w-3xl px-4 pb-24 pt-2 sm:px-6">
      <div className="neo mb-5 p-4 sm:p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h1 className="font-display text-2xl">My weighings</h1>
          <div className="flex gap-2">
            {[0, 1].map((off) => (
              <button
                key={off}
                type="button"
                onClick={() => setDayOffset(off)}
                aria-pressed={dayOffset === off}
                className={`press min-h-[48px] rounded-full border-[2.5px] border-ink px-4 text-sm font-bold ${
                  dayOffset === off ? "bg-ink text-cream" : "bg-white text-ink shadow-[3px_3px_0_rgb(22_27_20/0.9)]"
                }`}
              >
                {off === 0 ? "Today" : "Yesterday"}
              </button>
            ))}
            <button
              type="button"
              onClick={() => void load()}
              aria-label="Refresh"
              className="press flex h-12 w-12 items-center justify-center rounded-full border-[2.5px] border-ink bg-white shadow-[3px_3px_0_rgb(22_27_20/0.9)]"
            >
              {loading ? <Spinner /> : <RefreshCw size={19} />}
            </button>
          </div>
        </div>
        {rows && (
          <p className="mt-3 font-mono text-sm text-muted">
            {rows.length}
            {rows.length >= PAGE ? "+" : ""} units · {distinctItems} different items · business day {day}
          </p>
        )}
      </div>

      {error && (
        <div className="neo mb-4 bg-underbg p-4 font-semibold text-undertext">
          {error}{" "}
          <button type="button" className="underline" onClick={() => void load()}>
            Try again
          </button>
        </div>
      )}

      {rows === null && !error ? (
        <div className="flex justify-center py-16 text-cream">
          <Spinner className="h-8 w-8" />
        </div>
      ) : rows && rows.length === 0 ? (
        <div className="neo p-6 text-center text-muted">Nothing weighed {dayOffset === 0 ? "yet today" : "yesterday"}.</div>
      ) : (
        <ul className="space-y-3">
          {rows?.map((r) => (
            <li key={r.id} className="neo-sm p-4">
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="font-extrabold leading-snug">{r.product_name}</div>
                  <div className="mt-1 flex flex-wrap items-center gap-1.5 font-mono text-xs text-muted">
                    {r.size_label && <Pill tone="ink">{r.size_label}</Pill>}
                    <span>{clock(r.weighed_at, settings.timezone)}</span>
                    <span>·</span>
                    <span>
                      {r.aggregator_name ? `${r.aggregator_name} #${r.aggregator_ref ?? ""}` : `Order ${r.order_number ?? ""}`}
                    </span>
                  </div>
                </div>
                {editing?.id === r.id ? null : (
                  <span className="flex-none font-mono text-2xl font-bold">{fmt(r.weight_g)} g</span>
                )}
              </div>

              {editing?.id === r.id ? (
                <form
                  className="mt-3"
                  onSubmit={(e) => {
                    e.preventDefault();
                    void saveEdit();
                  }}
                >
                  <div className="flex gap-2">
                    <input
                      autoFocus
                      value={editing.value}
                      onChange={(e) => setEditing({ id: r.id, value: e.target.value })}
                      inputMode="decimal"
                      aria-label="New weight in grams"
                      className="h-14 min-w-0 flex-1 rounded-2xl border-[2.5px] border-ink bg-white px-4 font-mono text-2xl font-bold outline-none"
                    />
                    <Button type="submit" disabled={busy} aria-label="Save">
                      {busy ? <Spinner /> : <Check size={20} />}
                    </Button>
                    <Button variant="cream" onClick={() => setEditing(null)} aria-label="Cancel">
                      <X size={20} />
                    </Button>
                  </div>
                  {editing.error && <p className="mt-2 text-sm font-bold text-undertext">{editing.error}</p>}
                </form>
              ) : editable(r) ? (
                <div className="mt-3 flex gap-2">
                  <Button variant="cream" size="sm" onClick={() => setEditing({ id: r.id, value: String(r.weight_g) })}>
                    <Pencil size={15} /> Change
                  </Button>
                  <Button variant="danger" size="sm" onClick={() => setDeleting(r)}>
                    <Trash2 size={15} /> Delete
                  </Button>
                </div>
              ) : (
                <p className="mt-2 text-xs font-semibold text-muted">Locked — older than {settings.edit_window_hours} h. Ask the admin to fix it.</p>
              )}
            </li>
          ))}
        </ul>
      )}

      <Sheet open={!!deleting} onClose={() => setDeleting(null)} title="Delete this weighing?">
        {deleting && (
          <p className="font-semibold">
            {deleting.product_name}
            {deleting.size_label ? ` (${deleting.size_label})` : ""} — {fmt(deleting.weight_g)} g
          </p>
        )}
        <p className="mt-1 text-sm text-muted">Only delete it if it was weighed by mistake. You can weigh it again from the order.</p>
        <div className="mt-5 flex flex-col gap-3 sm:flex-row-reverse">
          <Button variant="danger" size="lg" className="flex-1" disabled={busy} onClick={() => void confirmDelete()}>
            {busy ? <Spinner /> : <Trash2 size={18} />} Delete
          </Button>
          <Button variant="cream" size="lg" className="flex-1" onClick={() => setDeleting(null)}>
            Keep it
          </Button>
        </div>
      </Sheet>
    </div>
  );
}
