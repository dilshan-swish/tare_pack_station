import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { api, timeAgo, branchDisplayName } from "../api";
import type { BrandSummary, Branch, Device, DeviceCreated } from "../types";
import { Card, Button, Badge, Banner, Spinner, TextInput, Modal, StatusDot, ButtonSpinner } from "../ui";
import { askConfirm } from "../confirmDialog";

export function TabletsPage() {
  const [brands, setBrands] = useState<BrandSummary[]>([]);
  const [brandId, setBrandId] = useState<number | null>(null);
  const [branches, setBranches] = useState<Branch[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [syncing, setSyncing] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        const bs = await api.brands();
        setBrands(bs);
        if (bs.length) setBrandId(bs[0].brandId);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load brands.");
      }
    })();
  }, []);

  // Guards against a race: if the brand changes twice in quick succession
  // (or a sync races a brand switch), an OLDER request's response could
  // otherwise land after a NEWER one and overwrite it — showing a different
  // brand's branches/devices than the one currently selected. Only the
  // most-recently-*requested* brandId is ever allowed to commit its result.
  const latestBrandId = useRef<number | null>(null);

  // `silent` is used by the background status poll below: a transient
  // failure there (one missed request) shouldn't flash an error banner over
  // a page that's already showing good data — only an explicit load (initial
  // mount, brand switch, manual retry) is worth surfacing one for.
  async function loadBranches(id: number, { silent = false }: { silent?: boolean } = {}) {
    latestBrandId.current = id;
    if (!silent) setError(null);
    try {
      const bs = await api.branches(id);
      if (latestBrandId.current === id) {
        setBranches(bs);
        if (silent) setError(null);
      }
    } catch (e) {
      if (!silent && latestBrandId.current === id) {
        setError(e instanceof Error ? e.message : "Failed to load branches.");
      }
    }
  }

  useEffect(() => {
    if (brandId != null) {
      setBranches(null);
      void loadBranches(brandId);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [brandId]);

  // Live online/offline status: a scale's own status is a snapshot computed
  // from its last heartbeat (every ~60s), not pushed to the portal, so
  // without this the page only ever reflected it on the next manual reload.
  // Polling every 10s — well under the heartbeat interval — means a scale
  // coming back online shows up here within a few seconds, no reload needed.
  // Silent: `loadBranches` only replaces `branches` once the new list has
  // arrived, so this never flashes the loading spinner or resets scroll —
  // it also can't do anything ELSE (add a scale, move it, revoke a key)
  // since those are separate, independently-owned pieces of state.
  useEffect(() => {
    if (brandId == null) return;
    const timer = setInterval(() => void loadBranches(brandId, { silent: true }), 10_000);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [brandId]);

  async function syncBranches() {
    if (brandId == null) return;
    setSyncing(true);
    setNote(null);
    setError(null);
    try {
      const r = await api.syncBranches(brandId);
      setNote(`Branches synced — ${r.added} new, ${r.updated} updated, ${r.total} total.`);
      await loadBranches(brandId);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Branch sync failed.");
    } finally {
      setSyncing(false);
    }
  }

  const refresh = () => {
    if (brandId != null) void loadBranches(brandId);
  };

  const totalOnline = branches?.reduce((n, b) => n + b.onlineCount, 0) ?? 0;
  const totalDevices = branches?.reduce((n, b) => n + b.deviceCount, 0) ?? 0;

  return (
    <div className="animate-fade-up">
      <div className="flex flex-wrap items-center gap-3">
        <div>
          <h1 className="font-display text-2xl text-ink">Smart Scales</h1>
          <p className="mt-1 text-sm text-muted">
            Branches and the smart scales connected to them.
          </p>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <select
            value={brandId ?? ""}
            onChange={(e) => setBrandId(Number(e.target.value))}
            className="rounded-lg border border-line bg-white px-3 py-2 text-lg font-extrabold tracking-tight outline-none transition focus:border-green focus:ring-2 focus:ring-green/20"
          >
            {brands.map((b) => (
              <option key={b.brandId} value={b.brandId}>
                {b.name}
              </option>
            ))}
          </select>
          <Button variant="outline" onClick={() => void syncBranches()} disabled={syncing}>
            {syncing ? <ButtonSpinner /> : "⟳ Sync branches"}
          </Button>
        </div>
      </div>

      {branches && branches.length > 0 && (
        <div className="mt-4 flex gap-2">
          <Badge tone="ok">{totalOnline} online</Badge>
          <Badge tone="neutral">{totalDevices} smart scales</Badge>
          <Badge tone="neutral">{branches.length} branches</Badge>
        </div>
      )}

      {note && <div className="mt-4"><Banner tone="ok">{note}</Banner></div>}
      {error && <div className="mt-4"><Banner tone="bad">{error}</Banner></div>}

      <div className="mt-5 space-y-3">
        {branches === null ? (
          error ? null : <Spinner />
        ) : branches.length === 0 ? (
          <Banner tone="warn">
            No branches yet — click “Sync branches” to pull this brand's stores from Foodics.
          </Banner>
        ) : (
          branches.map((b, i) => (
            <BranchCard
              key={b.branchId}
              branch={b}
              onChanged={refresh}
              delayMs={Math.min(i, 8) * 40}
            />
          ))
        )}
      </div>
    </div>
  );
}

function BranchCard({
  branch,
  onChanged,
  delayMs = 0,
}: {
  branch: Branch;
  onChanged: () => void;
  delayMs?: number;
}) {
  const [open, setOpen] = useState(false);
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [label, setLabel] = useState("");
  const [adding, setAdding] = useState(false);
  const [newKey, setNewKey] = useState<DeviceCreated | null>(null);

  // `silent` is used by the background status poll below. This panel's
  // `error` is shared with the add/move/regenerate actions below, so a
  // silent poll deliberately never touches it either way — it shouldn't
  // pop up a new error over an action the admin didn't take, but it also
  // shouldn't clear a real one they're still looking at from an action they
  // just took.
  async function load({ silent = false }: { silent?: boolean } = {}) {
    if (!silent) setError(null);
    try {
      setDevices(await api.devices(branch.branchId));
    } catch (e) {
      if (!silent) {
        setError(e instanceof Error ? e.message : "Failed to load smart scales.");
      }
    }
  }

  function toggle() {
    const next = !open;
    setOpen(next);
    if (next && devices === null) void load();
  }

  // Same live-status reasoning as the branch list above, one level down: a
  // scale's online dot here is also just a snapshot, so keep it fresh while
  // this branch is actually expanded (no point polling scales nobody's
  // looking at). `load()` replaces `devices` in place once the response
  // arrives, so this never re-shows the spinner or disturbs the "add a
  // scale" input, an open Move dialog, or a just-revealed key.
  useEffect(() => {
    if (!open) return;
    const timer = setInterval(() => void load({ silent: true }), 10_000);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, branch.branchId]);

  async function add() {
    if (!label.trim()) return;
    setAdding(true);
    setError(null);
    try {
      const created = await api.createDevice(branch.branchId, label.trim());
      setNewKey(created);
      setLabel("");
      await load();
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not add smart scale.");
    } finally {
      setAdding(false);
    }
  }

  async function revoke(d: Device) {
    if (
      !(await askConfirm({
        message: `Remove “${d.label}”? Its key will stop working.`,
        confirmLabel: "Remove",
        tone: "danger",
      }))
    )
      return;
    try {
      await api.deleteDevice(d.deviceId);
      await load();
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not remove it.");
    }
  }

  const [moving, setMoving] = useState<Device | null>(null);
  const [regeneratingId, setRegeneratingId] = useState<number | null>(null);

  async function afterMove() {
    setMoving(null);
    await load();
    onChanged();
  }

  // The fix for "lost connection, had to delete and re-add it" — this keeps
  // the scale's existing DeviceId (and therefore every weigh event and
  // connection-log entry already tied to it) instead of orphaning its
  // history the way delete-and-re-add does. Also works on an already-removed
  // device, reactivating it in the same step.
  async function regenerate(d: Device) {
    const verb = d.isActive ? "Regenerate the key" : "Reconnect";
    if (
      !(await askConfirm({
        title: `${verb}?`,
        message: `${verb} for “${d.label}”? ${d.isActive ? "Its current key will stop working immediately — " : ""}you'll need to enter the new key on the scale.`,
        confirmLabel: verb,
      }))
    ) {
      return;
    }
    setRegeneratingId(d.deviceId);
    setError(null);
    try {
      const created = await api.regenerateDeviceKey(d.deviceId);
      setNewKey(created);
      await load();
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not regenerate the key.");
    } finally {
      setRegeneratingId(null);
    }
  }

  return (
    <Card className="animate-fade-up overflow-hidden" style={{ animationDelay: `${delayMs}ms` }}>
      <button
        onClick={toggle}
        className="flex w-full items-center gap-3 px-4 py-4 text-left transition-colors hover:bg-black/[0.02] sm:px-5"
      >
        <div className="min-w-0 grow">
          <div className="truncate font-semibold text-ink">{branchDisplayName(branch)}</div>
          {branch.code && <div className="truncate font-mono text-xs text-muted">{branch.code}</div>}
        </div>
        <div className="flex flex-none items-center gap-3">
          {branch.deviceCount === 0 ? (
            <Badge tone="neutral">No scales</Badge>
          ) : branch.onlineCount > 0 ? (
            <Badge tone="ok">● {branch.onlineCount}/{branch.deviceCount} online</Badge>
          ) : (
            <Badge tone="bad">○ 0/{branch.deviceCount} online</Badge>
          )}
          <span className={`text-muted transition-transform duration-200 ${open ? "rotate-180" : ""}`}>▾</span>
        </div>
      </button>

      {open && (
        <div className="animate-fade-up border-t border-line px-5 py-4">
          {newKey && (
            <div className="animate-pop-in mb-4 rounded-xl border border-green/40 bg-okbg p-4">
              <div className="text-sm font-bold text-oktext">
                Scale key for “{newKey.label}” — shown once, copy it now:
              </div>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <code className="min-w-0 grow overflow-x-auto whitespace-nowrap rounded-lg bg-white px-3 py-2 font-mono text-sm">
                  {newKey.deviceKey}
                </code>
                <div className="flex flex-none gap-2">
                  <Button
                    variant="outline"
                    onClick={() => void navigator.clipboard?.writeText(newKey.deviceKey)}
                  >
                    Copy
                  </Button>
                  <Button variant="ghost" onClick={() => setNewKey(null)}>
                    Done
                  </Button>
                </div>
              </div>
              <div className="mt-2 text-xs text-oktext/80">
                Enter this on the scale's setup screen to connect it to this branch.
              </div>
            </div>
          )}

          {error && <div className="mb-3"><Banner tone="bad">{error}</Banner></div>}

          {devices === null ? (
            <Spinner />
          ) : devices.length === 0 ? (
            <div className="mb-3 text-sm text-muted">No smart scales registered yet.</div>
          ) : (
            <div className="mb-3 divide-y divide-line">
              {devices.map((d) => (
                <div
                  key={d.deviceId}
                  className={`flex flex-col gap-2.5 rounded-lg px-2 py-2.5 transition-colors duration-150 hover:bg-black/[0.025] sm:flex-row sm:items-center sm:gap-3 ${d.isActive ? "" : "opacity-60"}`}
                >
                  <div className="flex min-w-0 items-center gap-3">
                    <StatusDot online={d.online} />
                    <Link to={`/devices/${d.deviceId}`} className="min-w-0 grow hover:underline">
                      <div className="flex items-center gap-2">
                        <span className="truncate font-semibold text-ink">{d.label}</span>
                        {!d.isActive && <Badge tone="bad">Removed</Badge>}
                      </div>
                      <div className="truncate font-mono text-xs text-muted">
                        {d.isActive
                          ? d.online
                            ? "online"
                            : `last seen ${timeAgo(d.lastSeenAt)}`
                          : "no longer connected"}
                        {d.appVersion ? ` · v${d.appVersion}` : ""}
                      </div>
                    </Link>
                  </div>
                  <div className="flex flex-wrap items-center gap-2 sm:flex-none sm:justify-end">
                    {d.isActive && (
                      <Button variant="outline" onClick={() => setMoving(d)} title="Move to another branch/brand">
                        Move…
                      </Button>
                    )}
                    <Button
                      variant="outline"
                      onClick={() => void regenerate(d)}
                      disabled={regeneratingId === d.deviceId}
                      title={
                        d.isActive
                          ? "Issue a new key — keeps this scale's history"
                          : "Bring this scale back with the same history"
                      }
                    >
                      {regeneratingId === d.deviceId ? (
                        <ButtonSpinner />
                      ) : d.isActive ? (
                        "Regenerate key"
                      ) : (
                        "Reconnect"
                      )}
                    </Button>
                    {d.isActive && (
                      <Button variant="ghost" onClick={() => void revoke(d)} title="Remove">
                        ✕
                      </Button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}

          {moving && (
            <MoveDeviceModal device={moving} onClose={() => setMoving(null)} onMoved={afterMove} />
          )}

          <div className="flex flex-wrap items-center gap-2">
            <TextInput
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              placeholder="New smart scale label — e.g. Pack station 1"
              className="min-w-52 grow max-w-sm"
              onKeyDown={(e) => e.key === "Enter" && void add()}
            />
            <Button onClick={() => void add()} disabled={adding || !label.trim()}>
              {adding ? (
                <>
                  <ButtonSpinner /> Adding…
                </>
              ) : (
                "+ Add smart scale"
              )}
            </Button>
          </div>
        </div>
      )}
    </Card>
  );
}

// Reassigns a scale to a different branch (and, transitively, a different
// brand) — the scale's own key is untouched, so it starts serving the new
// brand's menu automatically the next time it checks in (no re-registration,
// no tablet-side change needed).
function MoveDeviceModal({
  device,
  onClose,
  onMoved,
}: {
  device: Device;
  onClose: () => void;
  onMoved: () => Promise<void> | void;
}) {
  const [brands, setBrands] = useState<BrandSummary[] | null>(null);
  const [brandId, setBrandId] = useState<number | "">("");
  const [branches, setBranches] = useState<Branch[] | null>(null);
  const [branchId, setBranchId] = useState<number | "">("");
  const [error, setError] = useState<string | null>(null);
  const [moving, setMoving] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        setBrands(await api.brands());
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load brands.");
      }
    })();
  }, []);

  // Same race as the main page's brand switcher: guard so that only the
  // most-recently-picked brand's branch list can ever land, in case the
  // admin flips the Brand dropdown again before the first request resolves
  // — otherwise a stale branch list could sit under the wrong brand name,
  // risking reassigning the scale to the wrong branch.
  const latestBrandId = useRef<number | "">("");

  useEffect(() => {
    latestBrandId.current = brandId;
    if (brandId === "") {
      setBranches(null);
      return;
    }
    setBranches(null);
    setBranchId("");
    (async () => {
      try {
        const bs = await api.branches(brandId);
        if (latestBrandId.current === brandId) setBranches(bs);
      } catch (e) {
        if (latestBrandId.current === brandId) {
          setError(e instanceof Error ? e.message : "Failed to load branches.");
        }
      }
    })();
  }, [brandId]);

  async function confirm() {
    if (branchId === "") return;
    setMoving(true);
    setError(null);
    try {
      await api.reassignDevice(device.deviceId, branchId);
      await onMoved();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not move this scale.");
    } finally {
      setMoving(false);
    }
  }

  return (
    <Modal open onClose={onClose} title={`Move “${device.label}”`}>
      <p className="mb-4 text-sm text-muted">
        This scale keeps its existing key — moving it here immediately switches which
        brand's menu and weights it uses, with nothing to change on the tablet itself.
      </p>
      {error && <div className="mb-3"><Banner tone="bad">{error}</Banner></div>}

      <label className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">
        Brand
      </label>
      <select
        value={brandId}
        onChange={(e) => setBrandId(e.target.value ? Number(e.target.value) : "")}
        className="mb-3 w-full rounded-lg border border-line bg-white px-3 py-2 text-sm outline-none transition focus:border-green focus:ring-2 focus:ring-green/20"
      >
        <option value="">Choose a brand…</option>
        {(brands ?? []).map((b) => (
          <option key={b.brandId} value={b.brandId}>
            {b.name}
          </option>
        ))}
      </select>

      <label className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">
        Branch
      </label>
      <select
        value={branchId}
        disabled={brandId === "" || branches === null}
        onChange={(e) => setBranchId(e.target.value ? Number(e.target.value) : "")}
        className="mb-4 w-full rounded-lg border border-line bg-white px-3 py-2 text-sm outline-none transition focus:border-green focus:ring-2 focus:ring-green/20 disabled:opacity-50"
      >
        <option value="">
          {brandId === "" ? "Choose a brand first" : branches === null ? "Loading…" : "Choose a branch…"}
        </option>
        {(branches ?? []).map((b) => (
          <option key={b.branchId} value={b.branchId}>
            {branchDisplayName(b)}
          </option>
        ))}
      </select>

      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button onClick={() => void confirm()} disabled={branchId === "" || moving}>
          {moving ? (
            <>
              <ButtonSpinner /> Moving…
            </>
          ) : (
            "Move scale"
          )}
        </Button>
      </div>
    </Modal>
  );
}
