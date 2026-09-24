import { useEffect, useState, type ChangeEvent, type ReactNode } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Banner, Button, ButtonSpinner, Card, NumberInput, Select, TextInput } from "../../ui";
import { askConfirm } from "../../confirmDialog";
import { describeSbError, sb, type StaffBranch, type StaffFocusItem } from "../../staffSupabase";
import type { StaffData } from "../StaffWeighingPage";

const SIZE_OPTIONS = [
  { value: "", label: "Any size" },
  { value: "REGULAR", label: "REGULAR" },
  { value: "MEDIUM", label: "MEDIUM" },
  { value: "SUUUBER", label: "SUUUBER" },
];

export function SetupTab({ data }: { data: StaffData }) {
  return (
    <div className="space-y-6">
      <SettingsCard data={data} />
      <FocusCard data={data} />
      <BranchesCard data={data} />
    </div>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-xs text-muted">{hint}</span>}
    </label>
  );
}

function SettingsCard({ data }: { data: StaffData }) {
  const s = data.settings;
  const [form, setForm] = useState({
    target_samples: String(s.target_samples),
    min_weight_g: String(s.min_weight_g),
    max_weight_g: String(s.max_weight_g),
    edit_window_hours: String(s.edit_window_hours),
    business_day_cutoff_hour: String(s.business_day_cutoff_hour),
    skip_price_at_or_below: String(s.skip_price_at_or_below),
    skip_categories: s.skip_categories.join(", "),
  });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "ok" | "bad"; text: string } | null>(null);
  const set = (k: keyof typeof form) => (e: ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const save = async () => {
    setMsg(null);
    const n = (v: string) => Number(v);
    const patch = {
      target_samples: Math.trunc(n(form.target_samples)),
      min_weight_g: n(form.min_weight_g),
      max_weight_g: n(form.max_weight_g),
      edit_window_hours: Math.trunc(n(form.edit_window_hours)),
      business_day_cutoff_hour: Math.trunc(n(form.business_day_cutoff_hour)),
      skip_price_at_or_below: n(form.skip_price_at_or_below),
      skip_categories: form.skip_categories.split(",").map((c) => c.trim()).filter(Boolean),
    };
    if (!(patch.target_samples >= 1)) return setMsg({ tone: "bad", text: "Target must be at least 1." });
    if (!(patch.min_weight_g > 0 && patch.max_weight_g > patch.min_weight_g && patch.max_weight_g <= 20000))
      return setMsg({ tone: "bad", text: "Weights: 0 < min < max ≤ 20,000 g." });
    if (!(patch.business_day_cutoff_hour >= 0 && patch.business_day_cutoff_hour <= 23)) return setMsg({ tone: "bad", text: "Cutoff hour is 0–23." });
    if (!(patch.edit_window_hours >= 0 && patch.edit_window_hours <= 720)) return setMsg({ tone: "bad", text: "Edit window is 0–720 hours." });
    if (!(patch.skip_price_at_or_below >= 0)) return setMsg({ tone: "bad", text: "Skip price can't be negative." });
    setBusy(true);
    const { data: rows, error } = await sb().from("app_settings").update(patch).eq("id", true).select("id");
    setBusy(false);
    if (error) return setMsg({ tone: "bad", text: describeSbError(error) });
    if (!rows?.length) return setMsg({ tone: "bad", text: "Not saved — this login isn't allowed to change settings." });
    setMsg({ tone: "ok", text: "Saved. Staff devices pick it up on their next sign-in or refresh." });
    data.reloadReference();
  };

  return (
    <Card className="p-5">
      <h2 className="font-display text-sm text-ink">Weighing rules</h2>
      <div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Field label="Target samples" hint="per item + size, all branches">
          <NumberInput value={form.target_samples} onChange={set("target_samples")} />
        </Field>
        <Field label="Min weight (g)">
          <NumberInput value={form.min_weight_g} onChange={set("min_weight_g")} />
        </Field>
        <Field label="Max weight (g)" hint="staff can't save above this">
          <NumberInput value={form.max_weight_g} onChange={set("max_weight_g")} />
        </Field>
        <Field label="Staff edit window (h)" hint="how long staff can fix their own entries">
          <NumberInput value={form.edit_window_hours} onChange={set("edit_window_hours")} />
        </Field>
        <Field label="Business day starts at (hour)" hint={`${s.timezone} — earlier weighings count to the day before`}>
          <NumberInput value={form.business_day_cutoff_hour} onChange={set("business_day_cutoff_hour")} />
        </Field>
        <Field label="Skip add-ons priced ≤ (KD)" hint="0-priced meals are never skipped">
          <NumberInput value={form.skip_price_at_or_below} onChange={set("skip_price_at_or_below")} step="0.05" />
        </Field>
        <div className="sm:col-span-2">
          <Field label="Categories staff don't weigh" hint="comma-separated, exactly as in Foodics">
            <TextInput value={form.skip_categories} onChange={set("skip_categories")} />
          </Field>
        </div>
      </div>
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <Button onClick={() => void save()} disabled={busy}>
          {busy && <ButtonSpinner />} Save rules
        </Button>
        {msg && <Banner tone={msg.tone}>{msg.text}</Banner>}
      </div>
    </Card>
  );
}

function FocusCard({ data }: { data: StaffData }) {
  const [items, setItems] = useState<StaffFocusItem[]>(data.focus);
  const [draft, setDraft] = useState({ product_name: "", product_id: "", size_label: "", branch_id: "", priority: "5" });
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => setItems(data.focus), [data.focus]);

  // Offer product ids for names already seen in the data, so matching is by id.
  const known = new Map<string, string>();
  for (const e of data.entries) if (!known.has(e.product_name)) known.set(e.product_name, e.product_id);

  const add = async () => {
    setError(null);
    const name = draft.product_name.trim();
    if (!name) return setError("Enter the item name.");
    const priority = Math.trunc(Number(draft.priority));
    if (!(priority >= 1 && priority <= 99)) return setError("Priority is 1–99 (higher = more urgent).");
    setBusy("add");
    const { data: rows, error: err } = await sb()
      .from("focus_items")
      .insert({
        product_name: name,
        product_id: draft.product_id.trim() || known.get(name) || null,
        size_label: draft.size_label || null,
        branch_id: draft.branch_id || null,
        priority,
      })
      .select("*");
    setBusy(null);
    if (err) return setError(err.code === "23505" ? "That item/size is already on the list for that branch." : describeSbError(err));
    setItems((xs) => [...(rows as StaffFocusItem[]), ...xs]);
    setDraft({ product_name: "", product_id: "", size_label: "", branch_id: "", priority: "5" });
    data.reloadReference();
  };

  const update = async (f: StaffFocusItem, patch: Partial<StaffFocusItem>) => {
    setBusy(f.id);
    setError(null);
    const { error: err } = await sb().from("focus_items").update(patch).eq("id", f.id);
    setBusy(null);
    if (err) return setError(describeSbError(err));
    setItems((xs) => xs.map((x) => (x.id === f.id ? { ...x, ...patch } : x)));
  };

  const remove = async (f: StaffFocusItem) => {
    if (!(await askConfirm({ title: "Remove from focus list?", message: `${f.product_name}${f.size_label ? ` (${f.size_label})` : ""}`, confirmLabel: "Remove", tone: "danger" }))) return;
    setBusy(f.id);
    const { error: err } = await sb().from("focus_items").delete().eq("id", f.id);
    setBusy(null);
    if (err) return setError(describeSbError(err));
    setItems((xs) => xs.filter((x) => x.id !== f.id));
    data.reloadReference();
  };

  const branchOptions = [{ value: "", label: "All branches" }, ...data.branches.map((b) => ({ value: b.id, label: `${b.code} · ${b.name}` }))];

  return (
    <Card className="p-5">
      <h2 className="font-display text-sm text-ink">Focus items</h2>
      <p className="mt-1 text-xs text-muted">Staff see a ★ Priority tag on these until the target is reached. Higher priority = more urgent.</p>

      <datalist id="focus-known-items">
        {[...known.keys()].sort().map((n) => (
          <option key={n} value={n} />
        ))}
      </datalist>
      <div className="mt-4 grid gap-3 rounded-xl border border-line p-3 sm:grid-cols-2 lg:grid-cols-[2fr_1fr_1fr_6rem_auto]">
        <TextInput list="focus-known-items" value={draft.product_name} onChange={(e) => setDraft((d) => ({ ...d, product_name: e.target.value }))} placeholder="Item name (as in Foodics)" />
        <Select value={draft.size_label} onChange={(v) => setDraft((d) => ({ ...d, size_label: v }))} options={SIZE_OPTIONS} />
        <Select value={draft.branch_id} onChange={(v) => setDraft((d) => ({ ...d, branch_id: v }))} options={branchOptions} />
        <NumberInput value={draft.priority} onChange={(e) => setDraft((d) => ({ ...d, priority: e.target.value }))} aria-label="Priority" />
        <Button onClick={() => void add()} disabled={busy === "add"}>
          {busy === "add" ? <ButtonSpinner /> : <Plus size={15} />} Add
        </Button>
      </div>
      {error && (
        <div className="mt-3">
          <Banner tone="bad">{error}</Banner>
        </div>
      )}

      <div className="mt-4 overflow-x-auto">
        <table className="w-full min-w-[640px] text-sm">
          <thead className="border-b border-line text-left text-xs font-semibold uppercase tracking-wide text-muted">
            <tr>
              <th className="px-3 py-2">Item</th>
              <th className="px-3 py-2">Size</th>
              <th className="px-3 py-2">Branch</th>
              <th className="px-3 py-2">Priority</th>
              <th className="px-3 py-2">Active</th>
              <th className="px-3 py-2" />
            </tr>
          </thead>
          <tbody>
            {[...items]
              .sort((a, b) => b.priority - a.priority || a.product_name.localeCompare(b.product_name))
              .map((f) => (
                <tr key={f.id} className="border-b border-line/70 last:border-0">
                  <td className="px-3 py-2 font-semibold text-ink">
                    {f.product_name}
                    {!f.product_id && <span className="ml-1.5 text-xs font-normal text-muted">(matched by name)</span>}
                  </td>
                  <td className="px-3 py-2 text-xs font-bold text-muted">{f.size_label ?? "Any"}</td>
                  <td className="px-3 py-2 text-xs">{f.branch_id ? data.branchesById.get(f.branch_id)?.code ?? "?" : "All"}</td>
                  <td className="w-24 px-3 py-2">
                    <NumberInput
                      defaultValue={f.priority}
                      onBlur={(e) => {
                        const p = Math.trunc(Number(e.target.value));
                        if (p >= 1 && p <= 99 && p !== f.priority) void update(f, { priority: p });
                        else e.target.value = String(f.priority);
                      }}
                      aria-label={`Priority for ${f.product_name}`}
                    />
                  </td>
                  <td className="px-3 py-2">
                    <input
                      type="checkbox"
                      checked={f.is_active}
                      onChange={(e) => void update(f, { is_active: e.target.checked })}
                      disabled={busy === f.id}
                      aria-label={`Active: ${f.product_name}`}
                      className="h-5 w-5 accent-[#2f8f5b]"
                    />
                  </td>
                  <td className="px-3 py-2 text-right">
                    <button
                      type="button"
                      onClick={() => void remove(f)}
                      disabled={busy === f.id}
                      aria-label={`Remove ${f.product_name}`}
                      className="inline-flex h-9 w-9 items-center justify-center rounded-full text-badtext hover:bg-badbg disabled:opacity-40"
                    >
                      <Trash2 size={16} />
                    </button>
                  </td>
                </tr>
              ))}
          </tbody>
        </table>
        {items.length === 0 && <p className="py-6 text-center text-sm text-muted">No focus items yet.</p>}
      </div>
    </Card>
  );
}

function BranchesCard({ data }: { data: StaffData }) {
  const [rows, setRows] = useState<StaffBranch[]>(data.branches);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ tone: "ok" | "bad"; text: string } | null>(null);

  useEffect(() => setRows(data.branches), [data.branches]);

  const save = async (b: StaffBranch) => {
    setBusy(b.id);
    setMsg(null);
    const patch = {
      session_start: b.session_start || null,
      session_end: b.session_end || null,
      is_active: b.is_active,
    };
    if (!!patch.session_start !== !!patch.session_end) {
      setBusy(null);
      return setMsg({ tone: "bad", text: `${b.code}: set both session times, or neither.` });
    }
    const { error } = await sb().from("branches").update(patch).eq("id", b.id);
    setBusy(null);
    if (error) return setMsg({ tone: "bad", text: describeSbError(error) });
    setMsg({ tone: "ok", text: `${b.code} saved.` });
    data.reloadReference();
  };

  const edit = (id: string, patch: Partial<StaffBranch>) => setRows((rs) => rs.map((r) => (r.id === id ? { ...r, ...patch } : r)));

  return (
    <Card className="p-5">
      <h2 className="font-display text-sm text-ink">Branches</h2>
      <p className="mt-1 text-xs text-muted">
        The weighing session window is shown to staff as a reminder (a session can run past midnight, e.g. 19:00 → 01:00). An inactive branch can't sign in to weigh.
      </p>
      {msg && (
        <div className="mt-3">
          <Banner tone={msg.tone}>{msg.text}</Banner>
        </div>
      )}
      <div className="mt-4 overflow-x-auto">
        <table className="w-full min-w-[760px] text-sm">
          <thead className="border-b border-line text-left text-xs font-semibold uppercase tracking-wide text-muted">
            <tr>
              <th className="px-3 py-2">Branch</th>
              <th className="px-3 py-2">Login email</th>
              <th className="px-3 py-2">Session from</th>
              <th className="px-3 py-2">to</th>
              <th className="px-3 py-2">Active</th>
              <th className="px-3 py-2" />
            </tr>
          </thead>
          <tbody>
            {rows.map((b) => (
              <tr key={b.id} className="border-b border-line/70 last:border-0">
                <td className="whitespace-nowrap px-3 py-2 font-semibold text-ink">
                  {b.code} · {b.name}
                </td>
                <td className="px-3 py-2 font-mono text-xs text-muted">{b.email}</td>
                <td className="px-3 py-2">
                  <input
                    type="time"
                    value={b.session_start?.slice(0, 5) ?? ""}
                    onChange={(e) => edit(b.id, { session_start: e.target.value || null })}
                    className="rounded-lg border border-line px-2 py-1.5 font-mono text-sm"
                    aria-label={`${b.code} session start`}
                  />
                </td>
                <td className="px-3 py-2">
                  <input
                    type="time"
                    value={b.session_end?.slice(0, 5) ?? ""}
                    onChange={(e) => edit(b.id, { session_end: e.target.value || null })}
                    className="rounded-lg border border-line px-2 py-1.5 font-mono text-sm"
                    aria-label={`${b.code} session end`}
                  />
                </td>
                <td className="px-3 py-2">
                  <input
                    type="checkbox"
                    checked={b.is_active}
                    onChange={(e) => edit(b.id, { is_active: e.target.checked })}
                    className="h-5 w-5 accent-[#2f8f5b]"
                    aria-label={`${b.code} active`}
                  />
                </td>
                <td className="px-3 py-2 text-right">
                  <Button variant="outline" onClick={() => void save(b)} disabled={busy === b.id}>
                    {busy === b.id && <ButtonSpinner />} Save
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
