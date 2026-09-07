import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Link, useParams, useNavigate } from "react-router-dom";
import { api, ApiError } from "../api";
import type {
  BrandSummary,
  MenuItem,
  Modifier,
  ItemModifierGroup,
  ModifierCombination,
  MenuImportResult,
} from "../types";
import { Card, Button, Badge, Banner, Spinner, Coverage, NumberInput, Select, Modal, TogglePill } from "../ui";
import { askConfirm } from "../confirmDialog";

// Tri-state filters: "all" sends no query param (backend returns everything).
type ActiveFilter = "all" | "active" | "inactive";
type HasModsFilter = "all" | "with" | "without";
const activeParam = (f: ActiveFilter): boolean | undefined =>
  f === "all" ? undefined : f === "active";
const hasModsParam = (f: HasModsFilter): boolean | undefined =>
  f === "all" ? undefined : f === "with";

export function WeightsPage() {
  const { brandId } = useParams();
  const id = Number(brandId);
  const navigate = useNavigate();

  const [allBrands, setAllBrands] = useState<BrandSummary[]>([]);
  const [brand, setBrand] = useState<BrandSummary | null>(null);
  const [tab, setTab] = useState<"items" | "modifiers">("items");
  const [search, setSearch] = useState("");
  const [missingOnly, setMissingOnly] = useState(false);
  const [activeFilter, setActiveFilter] = useState<ActiveFilter>("all");
  const [hasModsFilter, setHasModsFilter] = useState<HasModsFilter>("all");
  const [items, setItems] = useState<MenuItem[] | null>(null);
  const [mods, setMods] = useState<Modifier[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [combinations, setCombinations] = useState<ModifierCombination[] | null>(null);
  const [combinationsOpen, setCombinationsOpen] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [importing, setImporting] = useState(false);
  const [importResult, setImportResult] = useState<MenuImportResult | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  async function loadBrand() {
    try {
      const list = await api.brands();
      setAllBrands(list);
      setBrand(list.find((b) => b.brandId === id) ?? null);
    } catch {
      /* coverage is non-critical */
    }
  }

  async function loadCombinations() {
    try {
      setCombinations(await api.modifierCombinations(id));
    } catch {
      /* combinations are a supplementary view — a load failure here shouldn't block the page */
    }
  }

  async function removeCombination(combinationId: number) {
    if (
      !(await askConfirm(
        "Remove this combined weight? These modifiers will go back to being added independently.",
      ))
    )
      return;
    try {
      await api.deleteModifierCombination(combinationId);
      setCombinations((cur) => (cur ? cur.filter((c) => c.combinationId !== combinationId) : cur));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Couldn't remove that combination.");
    }
  }

  async function exportMenu() {
    setExporting(true);
    setError(null);
    try {
      const blob = await api.exportMenu(id);
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      const stamp = new Date().toISOString().slice(0, 10);
      a.href = url;
      a.download = `${brand?.code ?? "brand"}-menu-${stamp}.xlsx`;
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

  function pickImportFile() {
    fileInputRef.current?.click();
  }

  async function onImportFileChosen(file: File) {
    setImporting(true);
    setError(null);
    setImportResult(null);
    try {
      const result = await api.importMenu(id, file);
      setImportResult(result);
      if (result.applied) {
        await loadBrand();
        await loadCombinations();
        setItems(await api.items(id, search, missingOnly, activeParam(activeFilter), hasModsParam(hasModsFilter)));
        setMods(await api.modifiers(id, search, activeParam(activeFilter)));
      }
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Import failed. Check your connection and try again.");
    } finally {
      setImporting(false);
    }
  }

  useEffect(() => {
    void loadBrand();
    void loadCombinations();
    setItems(null);
    setMods(null);
    setCombinations(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  useEffect(() => {
    let cancelled = false;
    const t = setTimeout(async () => {
      setError(null);
      try {
        if (tab === "items") {
          const r = await api.items(
            id,
            search,
            missingOnly,
            activeParam(activeFilter),
            hasModsParam(hasModsFilter),
          );
          if (!cancelled) setItems(r);
        } else {
          const r = await api.modifiers(id, search, activeParam(activeFilter));
          if (!cancelled) setMods(r);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : "Load failed.");
      }
    }, 250);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [id, tab, search, missingOnly, activeFilter, hasModsFilter]);

  async function sync() {
    setBusy(true);
    setNote(null);
    setError(null);
    try {
      const r = await api.sync(id);
      setNote(`Synced — ${r.itemsAdded} new item(s), ${r.missingWeights} still need weights.`);
      await loadBrand();
      setItems(await api.items(id, search, missingOnly, activeParam(activeFilter), hasModsParam(hasModsFilter)));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Sync failed.");
    } finally {
      setBusy(false);
    }
  }

  async function publish() {
    if (
      brand &&
      brand.missingWeights > 0 &&
      !(await askConfirm(`${brand.missingWeights} item(s) still have no weight. Publish anyway?`))
    )
      return;
    setBusy(true);
    setNote(null);
    setError(null);
    try {
      const r = await api.publish(id);
      setNote(`Published version ${r.publishedVersion}. Stores pick it up on next sync.`);
      await loadBrand();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Publish failed.");
    } finally {
      setBusy(false);
    }
  }

  function onItemSaved(updated: MenuItem) {
    setItems((cur) =>
      cur
        ? cur
            .map((i) => (i.menuItemId === updated.menuItemId ? updated : i))
            .filter((i) => !(missingOnly && i.isConfigured))
        : cur,
    );
    void loadBrand();
  }

  function onModSaved(updated: Modifier) {
    setMods((cur) =>
      cur ? cur.map((m) => (m.modifierId === updated.modifierId ? updated : m)) : cur,
    );
  }

  function onModsBulkSaved(updated: Modifier[]) {
    const byId = new Map(updated.map((m) => [m.modifierId, m]));
    setMods((cur) => (cur ? cur.map((m) => byId.get(m.modifierId) ?? m) : cur));
  }

  // Counts reflect whatever's currently loaded — i.e. after search/active/
  // has-modifiers filters have already been applied server-side — so they
  // always describe "the list you're looking at right now," not the brand total.
  const itemStats = useMemo(() => {
    if (!items) return null;
    const weighed = items.filter((i) => i.isConfigured).length;
    return { total: items.length, weighed, needsWeight: items.length - weighed };
  }, [items]);

  const modStats = useMemo(() => {
    if (!mods) return null;
    const weighed = mods.filter((m) => m.isConfigured).length;
    return { total: mods.length, weighed, needsWeight: mods.length - weighed };
  }, [mods]);

  // Foodics often splits one real physical item (e.g. a bottle of "Arwa
  // Water") into many separate catalog rows across different deals/combos —
  // grouping by exact name lets head office weigh it once instead of once per
  // row, while every row stays individually editable inside the group.
  const modGroups = useMemo(() => {
    if (!mods) return null;
    const order: string[] = [];
    const byName = new Map<string, Modifier[]>();
    for (const m of mods) {
      if (!byName.has(m.name)) {
        order.push(m.name);
        byName.set(m.name, []);
      }
      byName.get(m.name)!.push(m);
    }
    return order.map((name) => byName.get(name)!);
  }, [mods]);

  return (
    <div className="animate-fade-up">
      <Link
        to="/"
        className="mb-4 inline-flex items-center gap-1 text-sm font-semibold text-muted hover:text-ink"
      >
        ← All brands
      </Link>

      <Card className="mb-6 p-5">
        <div className="flex flex-wrap items-center gap-4">
          <select
            value={id}
            onChange={(e) => navigate(`/brands/${e.target.value}/weights`)}
            className="rounded-lg border border-line bg-white px-3 py-2 text-lg font-extrabold tracking-tight outline-none transition focus:border-green focus:ring-2 focus:ring-green/20"
          >
            {allBrands.map((b) => (
              <option key={b.brandId} value={b.brandId}>
                {b.name}
              </option>
            ))}
            {allBrands.length === 0 && <option value={id}>Brand {id}</option>}
          </select>

          {brand && (
            <div className="min-w-52 grow max-w-sm">
              <Coverage total={brand.totalItems} missing={brand.missingWeights} />
              <div className="mt-1.5 font-mono text-xs text-muted">
                published v{brand.publishedVersion}
              </div>
            </div>
          )}

          <div className="ml-auto flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => void exportMenu()} disabled={exporting}>
              {exporting ? "…" : "⇩ Export menu"}
            </Button>
            <Button variant="outline" onClick={pickImportFile} disabled={importing}>
              {importing ? "…" : "⇧ Import menu"}
            </Button>
            <input
              ref={fileInputRef}
              type="file"
              accept=".xlsx"
              className="hidden"
              onChange={(e) => {
                const file = e.target.files?.[0];
                e.target.value = ""; // lets choosing the same file again re-trigger onChange
                if (file) void onImportFileChosen(file);
              }}
            />
            <Button variant="outline" onClick={() => void sync()} disabled={busy}>
              {busy ? "…" : "⟳ Sync from Foodics"}
            </Button>
            <Button onClick={() => void publish()} disabled={busy || !brand}>
              Publish
            </Button>
          </div>
        </div>
      </Card>

      {note && <div className="mb-4"><Banner tone="ok">{note}</Banner></div>}
      {error && <div className="mb-4"><Banner tone="bad">{error}</Banner></div>}

      {combinations && combinations.length > 0 && (
        <Card className="mb-6 p-4">
          <button
            type="button"
            onClick={() => setCombinationsOpen((o) => !o)}
            className="flex w-full items-center justify-between text-left"
          >
            <div>
              <span className="font-semibold text-ink">Combined weights</span>{" "}
              <span className="text-sm text-muted">
                {combinations.length} combination{combinations.length === 1 ? "" : "s"} — 2 or more
                modifiers weighed together (e.g. a fries type + a drink type + a combo size)
              </span>
            </div>
            <span className={`transition-transform duration-200 ${combinationsOpen ? "rotate-180" : ""}`}>▾</span>
          </button>
          {combinationsOpen && (
            <div className="animate-fade-up mt-3 space-y-1.5 border-t border-line pt-3">
              {combinations.map((c) => (
                <div
                  key={c.combinationId}
                  className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-line bg-page px-3 py-2 text-sm"
                >
                  <span className="font-semibold text-ink">{c.modifierNames.join(" + ")}</span>
                  <span className="font-mono text-xs text-muted">
                    {c.weightG}g
                    {c.minWeightG != null && c.maxWeightG != null && ` (${c.minWeightG}–${c.maxWeightG}g)`}
                  </span>
                  <button
                    type="button"
                    onClick={() => void removeCombination(c.combinationId)}
                    className="ml-auto text-xs font-semibold text-muted transition-colors hover:text-badtext"
                  >
                    Remove
                  </button>
                </div>
              ))}
              <p className="pt-1 text-xs text-muted">
                To add or edit one, open the item below, expand its modifiers, and use "Set weights
                for modifiers combined" — or bulk-edit many at once via Export menu → fill in the
                ModifierCombinations sheet → Import menu.
              </p>
            </div>
          )}
        </Card>
      )}

      <Modal
        open={importResult !== null}
        onClose={() => setImportResult(null)}
        title={importResult?.applied ? "Import applied" : "Import not applied"}
      >
        {importResult && (
          <div className="space-y-3">
            {importResult.applied ? (
              <>
                <Banner tone="ok">Every row matched and was applied — no errors.</Banner>
                <ul className="space-y-1 text-sm text-ink">
                  <li>{importResult.itemsUpdated} item(s) updated</li>
                  <li>{importResult.modifiersUpdated} modifier(s) updated</li>
                  <li>{importResult.combinationsUpserted} combined weight(s) set</li>
                  <li>{importResult.combinationsRemoved} combined weight(s) removed</li>
                </ul>
              </>
            ) : (
              <>
                <Banner tone="bad">
                  Nothing was applied — every row is validated before anything is saved, and this
                  file has {importResult.errors.length} problem
                  {importResult.errors.length === 1 ? "" : "s"} to fix first.
                </Banner>
                <div className="max-h-72 space-y-1.5 overflow-y-auto">
                  {importResult.errors.map((e, i) => (
                    <div key={i} className="rounded-lg border border-line bg-page px-3 py-2 text-sm">
                      <span className="font-mono text-xs text-muted">
                        {e.sheet} · row {e.rowNumber}
                      </span>
                      <div className="text-ink">{e.error}</div>
                    </div>
                  ))}
                </div>
              </>
            )}
            <div className="flex justify-end pt-1">
              <Button onClick={() => setImportResult(null)}>Close</Button>
            </div>
          </div>
        )}
      </Modal>

      <div className="mb-5 flex flex-wrap items-center gap-3">
        <div className="flex overflow-hidden rounded-full border border-line bg-white p-0.5">
          {(["items", "modifiers"] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`rounded-full px-4 py-1.5 text-sm font-semibold capitalize transition-colors ${
                tab === t ? "bg-green text-white" : "text-muted hover:text-ink"
              }`}
            >
              {t}
            </button>
          ))}
        </div>

        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder={tab === "items" ? "Search name, SKU, category…" : "Search name, SKU, group…"}
          className="min-w-52 grow max-w-sm rounded-full border border-line bg-white px-4 py-2 text-sm outline-none transition focus:border-green focus:ring-2 focus:ring-green/20"
        />

        <Select
          value={activeFilter}
          onChange={setActiveFilter}
          options={[
            { value: "all", label: "Active + inactive" },
            { value: "active", label: "Active only" },
            { value: "inactive", label: "Inactive only" },
          ]}
        />

        {tab === "items" && (
          <>
            <Select
              value={hasModsFilter}
              onChange={setHasModsFilter}
              options={[
                { value: "all", label: "Any modifiers" },
                { value: "with", label: "Has modifiers" },
                { value: "without", label: "No modifiers" },
              ]}
            />
            <label className="flex cursor-pointer items-center gap-2 rounded-full border border-line bg-white px-3.5 py-2 text-sm font-semibold text-muted select-none">
              <input
                type="checkbox"
                checked={missingOnly}
                onChange={(e) => setMissingOnly(e.target.checked)}
                className="accent-green"
              />
              Missing only
            </label>
          </>
        )}
      </div>

      {tab === "items" && itemStats && <StatsBar stats={itemStats} noun="item" />}
      {tab === "modifiers" && modStats && <StatsBar stats={modStats} noun="modifier" />}

      {tab === "items" ? (
        items === null ? (
          <Spinner />
        ) : items.length === 0 ? (
          <Banner tone="ok">Nothing to show — every item here has a weight. 🎉</Banner>
        ) : (
          <div className="space-y-3">
            {items.map((it) => (
              <ItemRow
                key={it.menuItemId}
                item={it}
                brandId={id}
                onSaved={onItemSaved}
                combinations={combinations}
                onCombinationsChanged={loadCombinations}
              />
            ))}
          </div>
        )
      ) : modGroups === null ? (
        <Spinner />
      ) : modGroups.length === 0 ? (
        <Banner tone="warn">No modifiers found for this brand.</Banner>
      ) : (
        <div className="space-y-3">
          {modGroups.map((group) =>
            group.length === 1 ? (
              <ModifierRow key={group[0].modifierId} modifier={group[0]} onSaved={onModSaved} />
            ) : (
              <ModifierGroupCard
                key={group[0].name}
                brandId={id}
                variants={group}
                onSaved={onModSaved}
                onBulkSaved={onModsBulkSaved}
              />
            ),
          )}
        </div>
      )}
    </div>
  );
}

function StatsBar({
  stats,
  noun,
}: {
  stats: { total: number; weighed: number; needsWeight: number };
  noun: string;
}) {
  return (
    <div className="mb-4 flex flex-wrap items-center gap-2 text-sm">
      <span className="font-semibold text-ink">
        {stats.total} {noun}
        {stats.total === 1 ? "" : "s"}
      </span>
      <Badge tone="ok">✓ {stats.weighed} weighed</Badge>
      <Badge tone={stats.needsWeight === 0 ? "ok" : "bad"}>{stats.needsWeight} needs weight</Badge>
    </div>
  );
}

const toNum = (s: string): number | null => (s.trim() === "" ? null : Number(s));

// Unlike an item, a modifier's weight may be negative — e.g. "No Onion" or "No
// Cheese" represents weight REMOVED from the base item, not added. The
// shared NumberInput defaults to min=0 (right for item fields, which can
// never be negative); modifier fields override it with this permissive floor.
const MOD_MIN = -100000;

function ItemRow({
  item,
  brandId,
  onSaved,
  combinations,
  onCombinationsChanged,
}: {
  item: MenuItem;
  brandId: number;
  onSaved: (m: MenuItem) => void;
  combinations: ModifierCombination[] | null;
  onCombinationsChanged: () => void;
}) {
  const [ideal, setIdeal] = useState(item.idealWeightG?.toString() ?? "");
  const [min, setMin] = useState(item.minWeightG?.toString() ?? "");
  const [max, setMax] = useState(item.maxWeightG?.toString() ?? "");
  const [pkg, setPkg] = useState(item.packagingWeightG?.toString() ?? "");
  // `useState`'s initializer only runs once, at mount — if this item's
  // weight changes from OUTSIDE this row (e.g. a re-sync, or another tab
  // updating the same brand) after it's already mounted, these fields would
  // otherwise keep showing stale values forever. Resync whenever the
  // persisted values actually change.
  useEffect(() => {
    setIdeal(item.idealWeightG?.toString() ?? "");
    setMin(item.minWeightG?.toString() ?? "");
    setMax(item.maxWeightG?.toString() ?? "");
    setPkg(item.packagingWeightG?.toString() ?? "");
  }, [item.idealWeightG, item.minWeightG, item.maxWeightG, item.packagingWeightG]);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [modsOpen, setModsOpen] = useState(false);
  const [modGroups, setModGroups] = useState<ItemModifierGroup[] | null>(null);
  const [modsErr, setModsErr] = useState<string | null>(null);
  const [combineOpen, setCombineOpen] = useState(false);
  const [combineFocus, setCombineFocus] = useState<CombineModalFocus | null>(null);

  // Which of the brand's combinations actually belong to THIS item — every
  // member modifier has to be one of its own options, not just present
  // somewhere in the brand. Only meaningful once modGroups has loaded (needs
  // the item's own modifier ids); an empty list beforehand just means "none
  // shown yet", not "none exist".
  const itemCombinations =
    modGroups && combinations
      ? (() => {
          const ownIds = new Set(modGroups.flatMap((g) => g.options.map((o) => o.modifierId)));
          return combinations.filter((c) => c.modifierIds.every((id) => ownIds.has(id)));
        })()
      : [];

  function openCombineEditor(c?: ModifierCombination) {
    if (c && modGroups) {
      const groupIdOf = (modifierId: number) =>
        modGroups.find((g) => g.options.some((o) => o.modifierId === modifierId))?.groupId;
      // A legacy combination saved before anchoring existed has no
      // AnchorModifierId — arbitrarily treat its first member as the anchor
      // so there's still a definite grid to land on (matches how a fresh
      // pick defaults to the first two groups below).
      const anchorId = c.anchorModifierId ?? c.modifierIds[0];
      const dependentId = c.modifierIds.find((id) => id !== anchorId) ?? c.modifierIds[1];
      const anchorGroupId = groupIdOf(anchorId);
      const dependentGroupId = groupIdOf(dependentId);
      if (anchorGroupId && dependentGroupId) {
        setCombineFocus({ anchorGroupId, dependentGroupId, anchorOptionId: anchorId, dependentOptionId: dependentId });
      } else {
        setCombineFocus(null);
      }
    } else {
      setCombineFocus(null);
    }
    setCombineOpen(true);
  }

  async function removeCombinationHere(combinationId: number) {
    if (
      !(await askConfirm(
        "Remove this combined weight? These modifiers will go back to being added independently.",
      ))
    )
      return;
    try {
      await api.deleteModifierCombination(combinationId);
      onCombinationsChanged();
    } catch (e) {
      setModsErr(e instanceof Error ? e.message : "Couldn't remove that combination.");
    }
  }

  async function toggleMods() {
    if (modsOpen) {
      setModsOpen(false);
      return;
    }
    setModsOpen(true);
    if (modGroups || !item.hasModifiers) return;
    setModsErr(null);
    try {
      setModGroups(await api.itemModifierGroups(item.menuItemId));
    } catch (e) {
      setModsErr(e instanceof Error ? e.message : "Couldn't load modifiers.");
    }
  }

  function onOptionSaved(updated: Modifier) {
    setModGroups((cur) =>
      cur
        ? cur.map((g) => ({
            ...g,
            options: g.options.map((o) => (o.modifierId === updated.modifierId ? updated : o)),
          }))
        : cur,
    );
  }

  async function save() {
    const iv = toNum(ideal);
    const mn = toNum(min);
    const mx = toNum(max);
    const pk = toNum(pkg);
    for (const v of [iv, mn, mx, pk])
      if (v !== null && Number.isNaN(v)) {
        setErr("Numbers only.");
        return;
      }
    if (mn !== null && mx !== null && mx < mn) {
      setErr("Max must be ≥ Min.");
      return;
    }
    if (iv !== null && ((mn !== null && iv < mn) || (mx !== null && iv > mx))) {
      setErr("Ideal must fall between Min and Max.");
      return;
    }
    setSaving(true);
    setErr(null);
    try {
      const updated = await api.updateItem(item.menuItemId, {
        idealWeightG: iv,
        minWeightG: mn,
        maxWeightG: mx,
        packagingWeightG: pk,
      });
      setSaved(true);
      setTimeout(() => setSaved(false), 1600);
      onSaved(updated);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Save failed.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card
      hover
      className={`p-4 ${item.isConfigured ? "" : "border-l-4 border-l-coral"} ${
        item.isActive ? "" : "opacity-60"
      }`}
    >
      <div className="flex flex-wrap items-end gap-x-4 gap-y-3">
        <div className="min-w-44 grow">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-ink">{item.name}</span>
            {!item.isActive && <Badge tone="neutral">Inactive</Badge>}
            {item.isConfigured ? (
              <Badge tone="ok">✓ Set</Badge>
            ) : item.isActive ? (
              <Badge tone="bad">Needs weight</Badge>
            ) : null}
          </div>
          <div className="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-muted">
            {item.categoryName && <span>{item.categoryName}</span>}
            {item.categoryReference && (
              <span className="font-mono text-[11px]">{item.categoryReference}</span>
            )}
            {item.sku && <span className="font-mono text-[11px]">SKU {item.sku}</span>}
          </div>
          {item.hasModifiers && (
            <button
              type="button"
              onClick={() => void toggleMods()}
              className="mt-1 inline-flex items-center gap-1 text-xs font-semibold text-muted transition-colors hover:text-ink"
            >
              Modifiers — {modsOpen ? "hide" : "show"}
              <span
                className={`transition-transform duration-200 ${modsOpen ? "rotate-180" : ""}`}
              >
                ▾
              </span>
            </button>
          )}
        </div>

        <Field label="Ideal (g)">
          <NumberInput value={ideal} onChange={(e) => setIdeal(e.target.value)} />
        </Field>
        <Field label="Min (g)">
          <NumberInput value={min} onChange={(e) => setMin(e.target.value)} />
        </Field>
        <Field label="Max (g)">
          <NumberInput value={max} onChange={(e) => setMax(e.target.value)} />
        </Field>
        <Field label="Packaging (g)">
          <NumberInput value={pkg} onChange={(e) => setPkg(e.target.value)} />
        </Field>

        <Button
          onClick={() => void save()}
          disabled={saving}
          className={saved ? "animate-pop bg-oktext" : ""}
        >
          {saving ? "Saving…" : saved ? "Saved ✓" : "Save"}
        </Button>
      </div>
      {err && <div className="mt-2 text-sm font-semibold text-badtext">{err}</div>}

      {modsOpen && (
        <div className="animate-fade-up mt-4 space-y-3 border-t border-line pt-4">
          {modsErr ? (
            <div className="text-sm font-semibold text-badtext">{modsErr}</div>
          ) : modGroups === null ? (
            <Spinner />
          ) : (
            <>
              {modGroups.length >= 2 && (
                <div className="mb-2">
                  <button
                    type="button"
                    onClick={() => openCombineEditor()}
                    className="inline-flex items-center gap-1.5 rounded-full border border-line bg-page px-3 py-1.5 text-xs font-semibold text-ink transition hover:border-ink/40"
                  >
                    ⚭ Set weights for modifiers combined (e.g. a size + a fries type)
                  </button>
                  {itemCombinations.length > 0 && (
                    <div className="mt-1.5 space-y-1">
                      {itemCombinations.map((c) => (
                        <div
                          key={c.combinationId}
                          className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-line bg-page px-2.5 py-1.5 text-xs"
                        >
                          <span className="font-semibold text-ink">⚭ {c.modifierNames.join(" + ")}</span>
                          <span className="font-mono text-muted">
                            {c.weightG}g
                            {c.minWeightG != null && c.maxWeightG != null && ` (${c.minWeightG}–${c.maxWeightG}g)`}
                          </span>
                          <button
                            type="button"
                            onClick={() => openCombineEditor(c)}
                            className="ml-auto font-semibold text-muted transition-colors hover:text-ink"
                          >
                            Edit
                          </button>
                          <button
                            type="button"
                            onClick={() => void removeCombinationHere(c.combinationId)}
                            className="font-semibold text-muted transition-colors hover:text-badtext"
                          >
                            Remove
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )}
              {modGroups.map((g) => (
                <div key={g.groupId}>
                  <div className="mb-1 flex items-center gap-2 text-xs font-bold uppercase tracking-wide text-muted">
                    <span>{g.groupName ?? "Modifiers"}</span>
                    {g.groupReference && <span className="font-mono normal-case">{g.groupReference}</span>}
                  </div>
                  <div className="flex flex-wrap gap-1.5">
                    {g.options.map((o) => (
                      <ModifierOptionChip key={o.modifierId} option={o} onSaved={onOptionSaved} />
                    ))}
                  </div>
                </div>
              ))}
            </>
          )}
        </div>
      )}

      {combineOpen && modGroups && (
        <CombineGroupsModal
          brandId={brandId}
          groups={modGroups}
          initialFocus={combineFocus}
          onClose={() => setCombineOpen(false)}
          onSaved={onCombinationsChanged}
        />
      )}
    </Card>
  );
}

// Like `Field` below, but sized to fit a modifier-group name (e.g. "CHOOSE
// COMBO SIZE") instead of `Field`'s fixed 96px numeric-input width.
function GroupField({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-[11px] font-semibold uppercase tracking-wide text-muted">
        {label}
      </span>
      {children}
    </label>
  );
}

// Which specific existing combination CombineGroupsModal should land on when
// opened via "Edit" on a combination already listed for an item, instead of
// its usual first-two-groups default.
interface CombineModalFocus {
  anchorGroupId: string;
  dependentGroupId: string;
  anchorOptionId: number;
  dependentOptionId: number;
}

function toggledGroupSet(set: Set<string>, id: string): Set<string> {
  const next = new Set(set);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

// A grid cell's full draft: ideal weight plus its own optional range — same
// three fields as a single modifier's own weight (ModifierOptionChip below),
// just scoped to one specific combination instead.
interface CellDraft {
  weightG: string;
  minWeightG: string;
  maxWeightG: string;
}
const EMPTY_CELL_DRAFT: CellDraft = { weightG: "", minWeightG: "", maxWeightG: "" };

function cellDraftsEqual(a: CellDraft | undefined, b: CellDraft | undefined): boolean {
  const ad = a ?? EMPTY_CELL_DRAFT;
  const bd = b ?? EMPTY_CELL_DRAFT;
  return ad.weightG === bd.weightG && ad.minWeightG === bd.minWeightG && ad.maxWeightG === bd.maxWeightG;
}

function cellDraftIsBlank(d: CellDraft): boolean {
  return d.weightG.trim() === "" && d.minWeightG.trim() === "" && d.maxWeightG.trim() === "";
}

// Same rules as ValidateModifierWeights on the backend (kept in sync by
// hand — there's no shared code between the two runtimes here) plus one
// front-end-only check: a combination's ideal weight is never optional the
// way a single modifier's is, so Min/Max without an Ideal would fail to save
// with a confusing server error if we didn't catch it here first.
function validateCellDraft(d: CellDraft): string | null {
  const w = toNum(d.weightG);
  const mn = toNum(d.minWeightG);
  const mx = toNum(d.maxWeightG);
  for (const v of [w, mn, mx]) if (v !== null && Number.isNaN(v)) return "Numbers only.";
  if (mn !== null && mx !== null && mx < mn) return "Max must be ≥ Min.";
  if (w !== null && ((mn !== null && w < mn) || (mx !== null && w > mx)))
    return "Weight must fall between Min and Max.";
  if (w === null && (mn !== null || mx !== null))
    return "Set an ideal weight too — Min/Max need one to go with.";
  return null;
}

/// Lets an admin set combined weights for a "depends on" (anchor) group
/// against one or more OTHER groups at once — e.g. picking "CHOOSE COMBO
/// SIZE" as the anchor, then building a Size × Fries grid AND, independently,
/// a Size × Drink grid, because fries and drinks each vary with size but not
/// with each other. Each grid is its own 2-modifier override: WeightG
/// replaces only the DEPENDENT (row/column intersection's non-anchor)
/// modifier's own weight — the anchor option's own weight, and every
/// modifier's weight everywhere ELSE it's used on other items, are never
/// touched. That's what lets the same anchor value (e.g. "Medium") drive
/// several independent grids at once with no conflict — see
/// lib/logic/modifier_pairing.dart's resolveSelectedModifiers for the
/// tablet-side read of this.
///
/// A blank cell means "no override" (falls back to adding the dependent
/// modifier's own weight); typing a number there and saving creates one;
/// clearing a previously-set cell and saving removes it. Only cells that
/// actually changed are sent, so opening this and closing without editing
/// anything is a no-op.
function CombineGroupsModal({
  brandId,
  groups,
  initialFocus,
  onClose,
  onSaved,
}: {
  brandId: number;
  groups: ItemModifierGroup[];
  /// Set when opened via "Edit" on an already-listed combination, so this
  /// lands directly on the right grid (and the right cell) instead of its
  /// usual first-two-groups default.
  initialFocus?: CombineModalFocus | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [anchorGroupId, setAnchorGroupId] = useState(initialFocus?.anchorGroupId ?? groups[0]?.groupId ?? "");
  const [dependentGroupIds, setDependentGroupIds] = useState<Set<string>>(() => {
    if (initialFocus) return new Set([initialFocus.dependentGroupId]);
    return new Set(groups[1] ? [groups[1].groupId] : []);
  });
  const [existing, setExisting] = useState<ModifierCombination[] | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [values, setValues] = useState<Record<string, CellDraft>>({});
  const [original, setOriginal] = useState<Record<string, CellDraft>>({});
  const [editingCell, setEditingCell] = useState<{
    key: string;
    anchorName: string;
    dependentName: string;
  } | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveErr, setSaveErr] = useState<string | null>(null);
  const [saveOk, setSaveOk] = useState<string | null>(null);
  const lastGridKeyRef = useRef<string>("");
  const openedInitialCellRef = useRef(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const combos = await api.modifierCombinations(brandId);
        if (!cancelled) setExisting(combos);
      } catch (e) {
        if (!cancelled)
          setLoadErr(e instanceof Error ? e.message : "Couldn't load existing combined weights.");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [brandId]);

  const anchorGroup = groups.find((g) => g.groupId === anchorGroupId);
  const otherGroups = groups.filter((g) => g.groupId !== anchorGroupId);
  const dependentGroups = otherGroups.filter((g) => dependentGroupIds.has(g.groupId));

  function selectAnchor(groupId: string) {
    setAnchorGroupId(groupId);
    // The anchor and a dependent can't be the same group — drop it from the
    // dependent picks if it was one (rather than leaving an invalid,
    // invisible selection behind).
    setDependentGroupIds((prev) => {
      if (!prev.has(groupId)) return prev;
      const next = new Set(prev);
      next.delete(groupId);
      return next;
    });
  }

  // A cell's identity is just its two option ids — a modifier id only ever
  // belongs to one group, so no group id is needed to keep cells from
  // different grids apart.
  const cellKey = (anchorOptionId: number, dependentOptionId: number) =>
    `${anchorOptionId}|${dependentOptionId}`;
  const findCombo = (anchorOptionId: number, dependentOptionId: number) =>
    existing?.find(
      (c) =>
        c.modifierIds.length === 2 &&
        c.modifierIds.includes(anchorOptionId) &&
        c.modifierIds.includes(dependentOptionId),
    );

  // Repopulates every visible grid's values whenever the anchor or the set of
  // dependent groups changes, or the existing-combinations fetch lands — but
  // never while the exact same selection stays active, so it can't clobber
  // an in-progress edit out from under the admin (e.g. right after a partial
  // save).
  const gridKey = `${anchorGroupId}::${[...dependentGroupIds].sort().join(",")}`;
  useEffect(() => {
    if (!anchorGroup || existing === null || dependentGroups.length === 0) return;
    if (lastGridKeyRef.current === gridKey) return;
    const isFirstPopulation = lastGridKeyRef.current === "";
    lastGridKeyRef.current = gridKey;
    const next: Record<string, CellDraft> = {};
    for (const dep of dependentGroups) {
      for (const a of anchorGroup.options) {
        for (const d of dep.options) {
          const combo = findCombo(a.modifierId, d.modifierId);
          next[cellKey(a.modifierId, d.modifierId)] = {
            weightG: combo ? String(combo.weightG) : "",
            minWeightG: combo?.minWeightG != null ? String(combo.minWeightG) : "",
            maxWeightG: combo?.maxWeightG != null ? String(combo.maxWeightG) : "",
          };
        }
      }
    }
    setValues(next);
    setOriginal(next);

    // Landing on the right grid (via "Edit" on an already-listed combination)
    // is only half the fix if the specific cell is still buried in a table —
    // open its editor too, exactly once, so the numbers being edited are
    // immediately visible, not just somewhere on-screen.
    if (isFirstPopulation && initialFocus && !openedInitialCellRef.current) {
      openedInitialCellRef.current = true;
      const anchorOpt = anchorGroup.options.find((a) => a.modifierId === initialFocus.anchorOptionId);
      const depGroup = dependentGroups.find((d) => d.groupId === initialFocus.dependentGroupId);
      const depOpt = depGroup?.options.find((d) => d.modifierId === initialFocus.dependentOptionId);
      if (anchorOpt && depOpt) {
        setEditingCell({
          key: cellKey(anchorOpt.modifierId, depOpt.modifierId),
          anchorName: anchorOpt.name,
          dependentName: depOpt.name,
        });
      }
    } else {
      setEditingCell(null); // the cell being edited may no longer even be on-screen
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [gridKey, existing]);

  function updateCell(key: string, patch: Partial<CellDraft>) {
    setValues((v) => ({ ...v, [key]: { ...(v[key] ?? EMPTY_CELL_DRAFT), ...patch } }));
  }

  async function saveAll() {
    if (!anchorGroup || dependentGroups.length === 0) return;
    setSaving(true);
    setSaveErr(null);
    setSaveOk(null);
    let savedCount = 0;
    let removedCount = 0;
    const errors: string[] = [];

    for (const dep of dependentGroups) {
      for (const a of anchorGroup.options) {
        for (const d of dep.options) {
          const key = cellKey(a.modifierId, d.modifierId);
          const draft = values[key] ?? EMPTY_CELL_DRAFT;
          if (cellDraftsEqual(draft, original[key])) continue; // unchanged — nothing to send
          const combo = findCombo(a.modifierId, d.modifierId);
          const label = `${d.name} (${a.name})`;
          try {
            if (cellDraftIsBlank(draft)) {
              if (combo) {
                await api.deleteModifierCombination(combo.combinationId);
                removedCount++;
              }
            } else {
              const err = validateCellDraft(draft);
              if (err) {
                errors.push(`${label}: ${err}`);
                continue;
              }
              await api.upsertModifierCombination({
                modifierIds: [a.modifierId, d.modifierId],
                anchorModifierId: a.modifierId,
                weightG: Number(draft.weightG),
                minWeightG: toNum(draft.minWeightG),
                maxWeightG: toNum(draft.maxWeightG),
              });
              savedCount++;
            }
          } catch (e) {
            errors.push(`${label}: ${e instanceof Error ? e.message : "save failed"}`);
          }
        }
      }
    }

    setSaving(false);
    setSaveErr(errors.length > 0 ? errors.join("; ") : null);
    if (savedCount > 0 || removedCount > 0) {
      setSaveOk(`${savedCount} set, ${removedCount} removed.`);
      onSaved();
      try {
        setExisting(await api.modifierCombinations(brandId));
        setOriginal(values);
      } catch {
        /* keep current in-memory state if this refresh fails — not critical */
      }
    }
  }

  const anchorOptions = groups.map((g) => ({ value: g.groupId, label: g.groupName ?? "Modifiers" }));

  return (
    <Modal open onClose={onClose} title="Combine modifiers" maxWidth="max-w-4xl">
      <p className="mb-3 text-sm text-muted">
        Pick the group that changes how much OTHER modifiers weigh — e.g. "CHOOSE COMBO SIZE" — as
        the group it "depends on" below. Then pick one or more other groups (fries, drinks, ...)
        that each weigh differently depending on it, and fill in a grid for each. This never
        changes a modifier's own weight — reusing the same option on another item is unaffected —
        it only overrides what that specific pairing weighs on this item. Tap a cell to set its
        ideal weight and range; leave one blank to fall back to that modifier's own weight.
      </p>
      <div className="mb-2 flex flex-col gap-3 sm:flex-row sm:items-end sm:gap-4">
        <GroupField label="Depends on">
          <Select value={anchorGroupId} onChange={selectAnchor} options={anchorOptions} />
        </GroupField>
        <div className="min-w-0 sm:flex-1">
          <span className="mb-1 block text-[11px] font-semibold uppercase tracking-wide text-muted">
            Weighed differently by
          </span>
          {otherGroups.length === 0 ? (
            <p className="text-sm text-muted">This item has no other modifier group.</p>
          ) : (
            <div className="flex flex-wrap gap-1.5">
              {otherGroups.map((g) => (
                <TogglePill
                  key={g.groupId}
                  active={dependentGroupIds.has(g.groupId)}
                  onClick={() => setDependentGroupIds((prev) => toggledGroupSet(prev, g.groupId))}
                >
                  {g.groupName ?? "Modifiers"}
                </TogglePill>
              ))}
            </div>
          )}
        </div>
      </div>

      {loadErr && <Banner tone="bad">{loadErr}</Banner>}
      {!loadErr && otherGroups.length > 0 && dependentGroups.length === 0 && (
        <Banner tone="warn">Pick at least one group above to build its grid.</Banner>
      )}
      {!loadErr && existing === null && dependentGroups.length > 0 && <Spinner />}

      {editingCell && (
        <div className="mb-4 rounded-xl border-2 border-green bg-green/5 p-3">
          <div className="mb-2 text-sm font-semibold text-ink">
            {editingCell.dependentName}{" "}
            <span className="font-normal text-muted">when {anchorGroup?.groupName} is</span>{" "}
            {editingCell.anchorName}
          </div>
          <div className="flex flex-wrap items-end gap-3">
            <Field label="Weight (g)">
              <NumberInput
                autoFocus
                value={values[editingCell.key]?.weightG ?? ""}
                onChange={(e) => updateCell(editingCell.key, { weightG: e.target.value })}
                min={MOD_MIN}
              />
            </Field>
            <Field label="Min (g)">
              <NumberInput
                value={values[editingCell.key]?.minWeightG ?? ""}
                onChange={(e) => updateCell(editingCell.key, { minWeightG: e.target.value })}
                min={MOD_MIN}
              />
            </Field>
            <Field label="Max (g)">
              <NumberInput
                value={values[editingCell.key]?.maxWeightG ?? ""}
                onChange={(e) => updateCell(editingCell.key, { maxWeightG: e.target.value })}
                min={MOD_MIN}
              />
            </Field>
            <Button
              variant="ghost"
              onClick={() => updateCell(editingCell.key, EMPTY_CELL_DRAFT)}
            >
              Clear override
            </Button>
            <Button onClick={() => setEditingCell(null)}>Done</Button>
          </div>
          {(() => {
            const err = validateCellDraft(values[editingCell.key] ?? EMPTY_CELL_DRAFT);
            return err && <div className="mt-2 text-sm font-semibold text-badtext">{err}</div>;
          })()}
        </div>
      )}

      {anchorGroup && existing !== null && (
        <div className="max-h-[45vh] space-y-5 overflow-y-auto pr-1">
          {dependentGroups.map((dep) => (
            <div key={dep.groupId}>
              <div className="mb-1 text-xs font-bold uppercase tracking-wide text-muted">
                {anchorGroup.groupName} × {dep.groupName}
              </div>
              <div className="no-scrollbar overflow-x-auto">
                <table className="w-full border-collapse text-sm">
                  <thead>
                    <tr>
                      <th className="border border-line bg-page p-2 text-left text-xs font-bold uppercase tracking-wide text-muted">
                        {anchorGroup.groupName} \ {dep.groupName}
                      </th>
                      {dep.options.map((d) => (
                        <th
                          key={d.modifierId}
                          className="border border-line bg-page p-2 text-center text-xs font-semibold text-ink"
                        >
                          {d.name}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {anchorGroup.options.map((a) => (
                      <tr key={a.modifierId}>
                        <th className="border border-line bg-page p-2 text-left text-xs font-semibold text-ink">
                          {a.name}
                        </th>
                        {dep.options.map((d) => {
                          const key = cellKey(a.modifierId, d.modifierId);
                          const draft = values[key] ?? EMPTY_CELL_DRAFT;
                          const hasRange = draft.minWeightG.trim() !== "" || draft.maxWeightG.trim() !== "";
                          return (
                            <td key={d.modifierId} className="border border-line p-1">
                              <button
                                type="button"
                                onClick={() =>
                                  setEditingCell({ key, anchorName: a.name, dependentName: d.name })
                                }
                                className={`w-20 rounded-md border px-2 py-1 text-center font-mono text-sm transition ${
                                  editingCell?.key === key
                                    ? "border-green ring-2 ring-green/20"
                                    : "border-line bg-white hover:border-ink/30"
                                }`}
                              >
                                {draft.weightG.trim() || "—"}
                                {hasRange && <span className="ml-0.5 text-[10px] text-green-dark">±</span>}
                              </button>
                            </td>
                          );
                        })}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          ))}
        </div>
      )}

      {saveErr && <div className="mt-3 text-sm font-semibold text-badtext">{saveErr}</div>}
      {saveOk && !saveErr && <div className="mt-3 text-sm font-semibold text-oktext">{saveOk}</div>}

      <div className="mt-4 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>
          Close
        </Button>
        <Button onClick={() => void saveAll()} disabled={saving || dependentGroups.length === 0}>
          {saving ? "Saving…" : "Save changes"}
        </Button>
      </div>
    </Modal>
  );
}

/// A modifier option shown inside an item's expanded modifiers panel. Click
/// it to weigh that exact option right there, instead of hunting for it in
/// the Modifiers tab — the same validation/save flow as [ModifierRow], just
/// inline and scoped to a single option.
function ModifierOptionChip({
  option,
  onSaved,
}: {
  option: Modifier;
  onSaved: (m: Modifier) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [weight, setWeight] = useState(option.weightG?.toString() ?? "");
  const [min, setMin] = useState(option.minWeightG?.toString() ?? "");
  const [max, setMax] = useState(option.maxWeightG?.toString() ?? "");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // Same reasoning as ItemRow above: this chip stays mounted even while its
  // dialog is closed, so if the option's weight changes from elsewhere (a
  // bulk apply on the same modifier, a sync) these fields would otherwise
  // keep showing whatever was true the moment this chip first mounted.
  useEffect(() => {
    setWeight(option.weightG?.toString() ?? "");
    setMin(option.minWeightG?.toString() ?? "");
    setMax(option.maxWeightG?.toString() ?? "");
  }, [option.weightG, option.minWeightG, option.maxWeightG]);

  async function save() {
    const w = toNum(weight);
    const mn = toNum(min);
    const mx = toNum(max);
    for (const v of [w, mn, mx])
      if (v !== null && Number.isNaN(v)) {
        setErr("Numbers only.");
        return;
      }
    if (mn !== null && mx !== null && mx < mn) {
      setErr("Max must be ≥ Min.");
      return;
    }
    if (w !== null && ((mn !== null && w < mn) || (mx !== null && w > mx))) {
      setErr("Weight must fall between Min and Max.");
      return;
    }
    setSaving(true);
    setErr(null);
    try {
      const updated = await api.updateModifier(option.modifierId, {
        weightG: w,
        minWeightG: mn,
        maxWeightG: mx,
      });
      onSaved(updated);
      setEditing(false);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Save failed.");
    } finally {
      setSaving(false);
    }
  }

  function close() {
    if (saving) return; // don't let Escape/backdrop-click abandon an in-flight save
    setEditing(false);
    setErr(null);
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setEditing(true)}
        className={`inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-line px-2.5 py-1 text-xs transition hover:border-ink/40 hover:bg-black/[0.03] ${
          option.isActive ? "bg-white" : "bg-black/[0.03] opacity-60"
        }`}
      >
        {option.name}
        <span className="font-mono text-[11px] text-muted">
          {option.weightG != null ? `${option.weightG}g` : "not weighed"}
        </span>
      </button>

      <Modal open={editing} onClose={close} title={option.name}>
        <div className="flex flex-wrap items-end gap-3">
          <Field label="Weight (g)">
            <NumberInput
              value={weight}
              onChange={(e) => setWeight(e.target.value)}
              min={MOD_MIN}
              autoFocus
            />
          </Field>
          <Field label="Min (g)">
            <NumberInput value={min} onChange={(e) => setMin(e.target.value)} min={MOD_MIN} />
          </Field>
          <Field label="Max (g)">
            <NumberInput value={max} onChange={(e) => setMax(e.target.value)} min={MOD_MIN} />
          </Field>
        </div>
        {err && <div className="mt-3 text-sm font-semibold text-badtext">{err}</div>}
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="ghost" onClick={close} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={() => void save()} disabled={saving}>
            {saving ? "Saving…" : "Save"}
          </Button>
        </div>
      </Modal>
    </>
  );
}

function ModifierRow({
  modifier,
  onSaved,
}: {
  modifier: Modifier;
  onSaved: (m: Modifier) => void;
}) {
  const [weight, setWeight] = useState(modifier.weightG?.toString() ?? "");
  const [min, setMin] = useState(modifier.minWeightG?.toString() ?? "");
  const [max, setMax] = useState(modifier.maxWeightG?.toString() ?? "");
  // This is exactly the reported bug: a variant row inside an expanded
  // ModifierGroupCard is already mounted when "Apply to all" updates every
  // variant at once — without this resync, the "✓ Set" badge (which reads
  // straight from the `modifier` prop) correctly flips on, but these fields
  // keep showing blank/stale values from whatever was true at mount.
  useEffect(() => {
    setWeight(modifier.weightG?.toString() ?? "");
    setMin(modifier.minWeightG?.toString() ?? "");
    setMax(modifier.maxWeightG?.toString() ?? "");
  }, [modifier.weightG, modifier.minWeightG, modifier.maxWeightG]);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  async function save() {
    const w = toNum(weight);
    const mn = toNum(min);
    const mx = toNum(max);
    for (const v of [w, mn, mx])
      if (v !== null && Number.isNaN(v)) {
        setErr("Numbers only.");
        return;
      }
    if (mn !== null && mx !== null && mx < mn) {
      setErr("Max must be ≥ Min.");
      return;
    }
    if (w !== null && ((mn !== null && w < mn) || (mx !== null && w > mx))) {
      setErr("Weight must fall between Min and Max.");
      return;
    }
    setSaving(true);
    setErr(null);
    try {
      const updated = await api.updateModifier(modifier.modifierId, {
        weightG: w,
        minWeightG: mn,
        maxWeightG: mx,
      });
      setSaved(true);
      setTimeout(() => setSaved(false), 1600);
      onSaved(updated);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Save failed.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card
      hover
      className={`p-4 ${modifier.isConfigured ? "" : "border-l-4 border-l-coral"} ${
        modifier.isActive ? "" : "opacity-60"
      }`}
    >
      <div className="flex flex-wrap items-end gap-x-4 gap-y-3">
        <div className="min-w-44 grow">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-ink">{modifier.name}</span>
            {!modifier.isActive && <Badge tone="neutral">Inactive</Badge>}
            {modifier.isConfigured ? (
              <Badge tone="ok">✓ Set</Badge>
            ) : modifier.isActive ? (
              <Badge tone="bad">Needs weight</Badge>
            ) : null}
          </div>
          <div className="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-muted">
            {modifier.modifierGroupName && <span>{modifier.modifierGroupName}</span>}
            {modifier.modifierGroupReference && (
              <span className="font-mono text-[11px]">{modifier.modifierGroupReference}</span>
            )}
            {modifier.sku && <span className="font-mono text-[11px]">SKU {modifier.sku}</span>}
          </div>
        </div>
        <Field label="Weight (g)">
          <NumberInput value={weight} onChange={(e) => setWeight(e.target.value)} min={MOD_MIN} />
        </Field>
        <Field label="Min (g)">
          <NumberInput value={min} onChange={(e) => setMin(e.target.value)} min={MOD_MIN} />
        </Field>
        <Field label="Max (g)">
          <NumberInput value={max} onChange={(e) => setMax(e.target.value)} min={MOD_MIN} />
        </Field>
        <Button
          onClick={() => void save()}
          disabled={saving}
          className={saved ? "animate-pop bg-oktext" : ""}
        >
          {saving ? "Saving…" : saved ? "Saved ✓" : "Save"}
        </Button>
      </div>
      {err && <div className="mt-2 text-sm font-semibold text-badtext">{err}</div>}
    </Card>
  );
}

/// Same-named modifier variants (e.g. 30 separate "Arwa Water" catalog rows
/// across different deals) — a single bulk-apply action, but every variant
/// stays individually editable below via the same [ModifierRow] used
/// elsewhere. If variants already carry different weights, the bulk fields
/// are left blank rather than guessing which one is "the" value.
function ModifierGroupCard({
  brandId,
  variants,
  onSaved,
  onBulkSaved,
}: {
  brandId: number;
  variants: Modifier[];
  onSaved: (m: Modifier) => void;
  onBulkSaved: (mods: Modifier[]) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const [weight, setWeight] = useState("");
  const [min, setMin] = useState("");
  const [max, setMax] = useState("");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const configuredCount = variants.filter((v) => v.isConfigured).length;
  const allSame = (get: (m: Modifier) => number | null) =>
    variants.every((v) => get(v) === get(variants[0])) ? get(variants[0]) : undefined;
  const uniformWeight = allSame((m) => m.weightG);
  const uniformMin = allSame((m) => m.minWeightG);
  const uniformMax = allSame((m) => m.maxWeightG);
  const mixed = uniformWeight === undefined || uniformMin === undefined || uniformMax === undefined;

  // Pre-fill the bulk fields from whatever's already uniform, and keep them
  // in sync with it — but never fight the user's own in-progress typing.
  // This card stays mounted across `mods` re-fetches (keyed by name, not by
  // variant list identity), so a ONE-TIME prefill was a real data-loss bug:
  // e.g. hand-edit one variant elsewhere until the group becomes uniform —
  // `uniformWeight` flips from `undefined` to a real number, the "N/N set"
  // badge updates live (it reads `variants` directly), but the bulk field
  // stayed permanently blank from the very first render. Click "Apply to
  // all" without noticing and that blank submits `weightG: null`, wiping
  // every variant's weight. `dirty` tracks only "the user has typed
  // something since the last resync" — cleared again right after a
  // successful apply, since the field's contents are then provably exactly
  // what's now saved.
  const [dirty, setDirty] = useState(false);
  useEffect(() => {
    if (dirty) return;
    setWeight(uniformWeight != null ? String(uniformWeight) : "");
    setMin(uniformMin != null ? String(uniformMin) : "");
    setMax(uniformMax != null ? String(uniformMax) : "");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [uniformWeight, uniformMin, uniformMax, dirty]);

  async function applyToAll() {
    const w = toNum(weight);
    const mn = toNum(min);
    const mx = toNum(max);
    for (const v of [w, mn, mx])
      if (v !== null && Number.isNaN(v)) {
        setErr("Numbers only.");
        return;
      }
    if (mn !== null && mx !== null && mx < mn) {
      setErr("Max must be ≥ Min.");
      return;
    }
    if (w !== null && ((mn !== null && w < mn) || (mx !== null && w > mx))) {
      setErr("Weight must fall between Min and Max.");
      return;
    }
    if (
      mixed &&
      !(await askConfirm(
        `These ${variants.length} variants currently have different weights set. ` +
          `Overwrite all of them with this value?`,
      ))
    )
      return;

    setSaving(true);
    setErr(null);
    try {
      const r = await api.bulkUpdateModifiers(brandId, {
        name: variants[0].name,
        weightG: w,
        minWeightG: mn,
        maxWeightG: mx,
      });
      setSaved(true);
      setTimeout(() => setSaved(false), 1600);
      setDirty(false); // the fields now exactly match what's just been saved
      onBulkSaved(r.modifiers);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Save failed.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card className={`p-4 ${configuredCount === variants.length ? "" : "border-l-4 border-l-coral"}`}>
      <div className="flex flex-wrap items-end gap-x-4 gap-y-3">
        <div className="min-w-44 grow">
          <div className="flex items-center gap-2">
            <span className="font-semibold text-ink">{variants[0].name}</span>
            <Badge tone={configuredCount === variants.length ? "ok" : "bad"}>
              {configuredCount}/{variants.length} set
            </Badge>
          </div>
          <button
            type="button"
            onClick={() => setExpanded((e) => !e)}
            className="inline-flex items-center gap-1 text-xs font-semibold text-muted transition-colors hover:text-ink"
          >
            {variants.length} variants (same item, different Foodics catalog rows) —{" "}
            {expanded ? "hide" : "show"}
            <span className={`transition-transform duration-200 ${expanded ? "rotate-180" : ""}`}>
              ▾
            </span>
          </button>
        </div>

        <Field label="Weight (g)">
          <NumberInput
            value={weight}
            onChange={(e) => {
              setWeight(e.target.value);
              setDirty(true);
            }}
            min={MOD_MIN}
          />
        </Field>
        <Field label="Min (g)">
          <NumberInput
            value={min}
            onChange={(e) => {
              setMin(e.target.value);
              setDirty(true);
            }}
            min={MOD_MIN}
          />
        </Field>
        <Field label="Max (g)">
          <NumberInput
            value={max}
            onChange={(e) => {
              setMax(e.target.value);
              setDirty(true);
            }}
            min={MOD_MIN}
          />
        </Field>
        <Button
          onClick={() => void applyToAll()}
          disabled={saving}
          className={saved ? "animate-pop bg-oktext" : ""}
        >
          {saving ? "Applying…" : saved ? "Applied ✓" : `Apply to all ${variants.length}`}
        </Button>
      </div>
      {mixed && !err && (
        <div className="mt-2 text-xs font-semibold text-muted">
          These variants currently have different weights set — applying will overwrite all of them.
        </div>
      )}
      {err && <div className="mt-2 text-sm font-semibold text-badtext">{err}</div>}

      {expanded && (
        <div className="animate-fade-up mt-4 space-y-2 border-t border-line pt-4">
          {variants.map((v) => (
            <ModifierRow key={v.modifierId} modifier={v} onSaved={onSaved} />
          ))}
        </div>
      )}
    </Card>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block w-24">
      <span className="mb-1 block text-[11px] font-semibold uppercase tracking-wide text-muted">
        {label}
      </span>
      {children}
    </label>
  );
}
