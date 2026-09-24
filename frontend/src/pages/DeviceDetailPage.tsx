import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { api, reasonLabel, timeAgo, branchDisplayName } from "../api";
import type { DeviceCreated, DeviceDetail, DeviceEventLogEntry, WeighEventEntry } from "../types";
import {
  Card,
  Badge,
  Banner,
  Spinner,
  Select,
  Button,
  StatusDot,
  ButtonSpinner,
  DateRangeFilter,
  resolvePresetRange,
  OrderBreakdownModal,
  type RangePresetKey,
} from "../ui";
import { askConfirm } from "../confirmDialog";

type VerdictFilter = "all" | "onweight" | "under" | "over";
const VERDICT_OPTIONS: { value: VerdictFilter; label: string }[] = [
  { value: "all", label: "All verdicts" },
  { value: "onweight", label: "On weight" },
  { value: "under", label: "Under" },
  { value: "over", label: "Over" },
];

function verdictBadge(v: string) {
  const tone = v === "onweight" ? "ok" : v === "under" ? "bad" : v === "over" ? "warn" : "neutral";
  const label = v === "onweight" ? "On weight" : v === "under" ? "Under" : v === "over" ? "Over" : v;
  return <Badge tone={tone}>{label}</Badge>;
}

function g(n: number | null): string {
  if (n == null) return "—";
  return `${Math.round(n).toLocaleString()}g`;
}

function formatTime(iso: string): string {
  const d = new Date(iso.endsWith("Z") ? iso : iso + "Z");
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export function DeviceDetailPage() {
  const { deviceId } = useParams();
  const id = Number(deviceId);

  const [device, setDevice] = useState<DeviceDetail | null>(null);
  const [events, setEvents] = useState<DeviceEventLogEntry[] | null>(null);
  const [weighs, setWeighs] = useState<WeighEventEntry[] | null>(null);
  // Split by concern rather than one shared `error` — a page-wide gate
  // (`if (error) return <Banner>`) meant ANY failure, including a transient
  // weigh-history reload or a failed "Regenerate key" click, replaced the
  // ENTIRE page (device header, connection key, everything already loaded
  // fine) with a bare error banner, with no way to clear it short of
  // navigating away and back. Only a failure to load the device itself is
  // actually a reason to blank the whole page — the other two now show
  // inline, next to whatever action they belong to, and clear on retry.
  const [deviceError, setDeviceError] = useState<string | null>(null);
  const [weighsError, setWeighsError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [rangePreset, setRangePreset] = useState<RangePresetKey>("7d");
  const [customFrom, setCustomFrom] = useState(""); // yyyy-mm-dd
  const [customTo, setCustomTo] = useState("");
  const [verdictFilter, setVerdictFilter] = useState<VerdictFilter>("all");
  const [selectedWeigh, setSelectedWeigh] = useState<WeighEventEntry | null>(null);
  const [regenerating, setRegenerating] = useState(false);
  const [newKey, setNewKey] = useState<DeviceCreated | null>(null);

  const { from, to } = useMemo(() => {
    if (rangePreset === "custom") {
      return {
        from: customFrom ? new Date(`${customFrom}T00:00:00`).toISOString() : undefined,
        to: customTo ? new Date(`${customTo}T23:59:59.999`).toISOString() : undefined,
      };
    }
    return resolvePresetRange(rangePreset);
  }, [rangePreset, customFrom, customTo]);

  // `silent` is used by the background status poll below: a transient
  // failure there (one missed request) must never blank a page that's
  // already showing good data — only the very first load, with nothing on
  // screen yet, is worth replacing the whole page for.
  async function loadDevice({ silent = false }: { silent?: boolean } = {}) {
    if (!silent) setDeviceError(null);
    try {
      setDevice(await api.deviceDetail(id));
      if (silent) setDeviceError(null);
    } catch (e) {
      if (!silent) {
        setDeviceError(e instanceof Error ? e.message : "Failed to load this scale.");
      }
    }
  }

  async function loadEvents() {
    try {
      setEvents(await api.deviceEvents(id, 20));
    } catch {
      /* non-critical — the page still works without the log */
    }
  }

  // Guards against a race: switching the date-range filter quickly (e.g.
  // 90d then 7d) fires a new request before the previous one resolves — an
  // older, slower response landing after a newer one would otherwise show
  // weigh events for a different range than the one currently selected.
  const latestRange = useRef({ from, to });

  // `silent` mirrors the `loadDevice` pattern above: a periodic background
  // refresh must never blank a table the pack-station admin is actively
  // reading (loses scroll position, flashes the spinner) or surface a
  // transient network hiccup as an error banner — only the first, explicit
  // load is worth showing loading/error state for.
  async function loadWeighs({ silent = false }: { silent?: boolean } = {}) {
    const thisRange = { from, to };
    latestRange.current = thisRange;
    if (!silent) {
      setWeighs(null);
      setWeighsError(null);
    }
    try {
      const rows = await api.weighEvents({ deviceId: id, from, to, limit: 500 });
      if (latestRange.current === thisRange) {
        setWeighs(rows);
        if (silent) setWeighsError(null);
      }
    } catch (e) {
      if (latestRange.current === thisRange && !silent) {
        setWeighsError(e instanceof Error ? e.message : "Failed to load weigh events.");
      }
    }
  }

  useEffect(() => {
    if (!Number.isFinite(id)) return;
    void loadDevice();
    void loadEvents();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  // New weighs land continuously as staff work the pack station — without a
  // background refresh, this table only ever showed what existed at the
  // moment the page (or a filter change) loaded, same gap the online-status
  // poll above already solves for the device header.
  useEffect(() => {
    if (!Number.isFinite(id)) return;
    const timer = setInterval(() => void loadWeighs({ silent: true }), 10_000);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, from, to]);

  // Live online/offline status: this scale's status is a snapshot computed
  // from its last heartbeat (every ~60s), not pushed to the portal — without
  // this, the page only reflected a reconnect on the next manual reload.
  // Polling every 10s, well under the heartbeat interval, means it shows up
  // here within a few seconds. `loadDevice()` replaces `device` in place
  // once the response arrives, so this never re-shows the page spinner or
  // disturbs an open "Regenerate key" confirmation or a just-revealed key.
  useEffect(() => {
    if (!Number.isFinite(id)) return;
    const timer = setInterval(() => void loadDevice({ silent: true }), 10_000);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  // The original key can never be shown again — only its one-way hash is
  // ever stored, same principle as a password — so this is the actual
  // answer to "let me see the key again": issue a fresh one for this same
  // scale (same DeviceId, history untouched), which also reactivates it if
  // it had been removed.
  async function regenerate() {
    const verb = device?.isActive ? "Regenerate the key" : "Reconnect";
    if (
      !(await askConfirm({
        title: `${verb}?`,
        message: `${verb} for “${device?.label}”? ${device?.isActive ? "The current key will stop working immediately — " : ""}you'll need to enter the new key on the scale.`,
        confirmLabel: verb,
      }))
    ) {
      return;
    }
    setRegenerating(true);
    setActionError(null);
    try {
      const created = await api.regenerateDeviceKey(id);
      setNewKey(created);
      await loadDevice();
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Could not regenerate the key.");
    } finally {
      setRegenerating(false);
    }
  }

  useEffect(() => {
    if (!Number.isFinite(id)) return;
    void loadWeighs();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, from, to]);

  const filteredWeighs = useMemo(() => {
    if (!weighs) return null;
    return verdictFilter === "all" ? weighs : weighs.filter((w) => w.verdict === verdictFilter);
  }, [weighs, verdictFilter]);

  const counts = useMemo(() => {
    if (!weighs) return null;
    return {
      total: weighs.length,
      onWeight: weighs.filter((w) => w.verdict === "onweight").length,
      under: weighs.filter((w) => w.verdict === "under").length,
      over: weighs.filter((w) => w.verdict === "over").length,
    };
  }, [weighs]);

  if (!Number.isFinite(id)) return <Banner tone="bad">Invalid scale.</Banner>;
  if (deviceError) return <Banner tone="bad">{deviceError}</Banner>;
  if (!device) return <Spinner />;

  return (
    <div className="animate-fade-up">
      <Link to="/tablets" className="text-sm font-semibold text-muted hover:text-ink">
        ← Smart Scales
      </Link>

      <div className="mt-2 flex flex-wrap items-center gap-3">
        <StatusDot online={device.online} />
        <h1 className="text-2xl font-extrabold tracking-tight text-ink">{device.label}</h1>
        {!device.isActive && <Badge tone="bad">Removed</Badge>}
      </div>
      <p className="mt-1 text-sm text-muted">
        {device.brandName} ({device.brandCode}) ·{" "}
        {branchDisplayName({ name: device.branchName, nameLocalized: device.branchNameLocalized })}
        {device.appVersion ? ` · v${device.appVersion}` : ""}
      </p>
      <p className="mt-0.5 font-mono text-xs text-muted">
        {device.online ? "online now" : `last seen ${timeAgo(device.lastSeenAt)}`}
      </p>

      {device.lastEvent && (
        <div className="mt-4">
          <Banner tone={device.lastEvent.eventType === "recovered" ? "ok" : "warn"}>
            {device.lastEvent.eventType === "recovered"
              ? `Recovered ${timeAgo(device.lastEvent.occurredAt)}.`
              : `Last known issue, ${timeAgo(device.lastEvent.occurredAt)}: ${reasonLabel(device.lastEvent.reason)}${device.lastEvent.detail ? ` — ${device.lastEvent.detail}` : ""}`}
          </Banner>
        </div>
      )}

      <Card className="mt-4 p-4">
        <div className="flex flex-wrap items-center gap-3">
          <div>
            <div className="font-display text-sm text-ink">Connection key</div>
            <p className="mt-0.5 text-xs text-muted">
              For security, the key itself is never stored anywhere it could be shown again —
              only a one-way hash, the same principle as a password. If it's lost, issue a new
              one below; it keeps this scale's history exactly as it is.
            </p>
          </div>
          <Button
            variant="outline"
            className="ml-auto shrink-0"
            onClick={() => void regenerate()}
            disabled={regenerating}
          >
            {regenerating ? <ButtonSpinner /> : device.isActive ? "Regenerate key" : "Reconnect"}
          </Button>
        </div>

        {actionError && <div className="mt-3"><Banner tone="bad">{actionError}</Banner></div>}

        {newKey && (
          <div className="animate-pop-in mt-4 rounded-xl border border-green/40 bg-okbg p-4">
            <div className="text-sm font-bold text-oktext">
              New key for “{newKey.label}” — shown once, copy it now:
            </div>
            <div className="mt-2 flex items-center gap-2">
              <code className="grow overflow-x-auto rounded-lg bg-white px-3 py-2 font-mono text-sm">
                {newKey.deviceKey}
              </code>
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
            <div className="mt-2 text-xs text-oktext/80">
              Enter this on the scale's Head-office connection settings.
            </div>
          </div>
        )}
      </Card>

      {events && events.length > 0 && (
        <Card className="mt-4 p-4">
          <div className="mb-2 font-display text-sm text-ink">Connection log</div>
          <div className="max-h-40 overflow-y-auto divide-y divide-line text-sm">
            {events.map((e) => (
              <div key={e.deviceEventId} className="flex items-center gap-3 py-1.5">
                <Badge tone={e.eventType === "recovered" ? "ok" : "warn"}>
                  {e.eventType === "recovered" ? "Recovered" : reasonLabel(e.reason)}
                </Badge>
                <span className="font-mono text-xs text-muted">{formatTime(e.occurredAt)}</span>
              </div>
            ))}
          </div>
        </Card>
      )}

      <div className="mt-6 flex flex-wrap items-end gap-3">
        <h2 className="font-display text-lg text-ink">Weigh history</h2>
        <div className="ml-auto flex flex-wrap items-end gap-2">
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
          <div>
            <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">
              Verdict
            </span>
            <Select value={verdictFilter} onChange={setVerdictFilter} options={VERDICT_OPTIONS} />
          </div>
        </div>
      </div>

      {counts && (
        <div className="mt-3 flex flex-wrap gap-2">
          <Badge tone="neutral">{counts.total} weighed</Badge>
          <Badge tone="ok">{counts.onWeight} on weight</Badge>
          <Badge tone="bad">{counts.under} under</Badge>
          <Badge tone="warn">{counts.over} over</Badge>
        </div>
      )}

      <Card className="mt-4 overflow-hidden">
        {weighsError ? (
          <div className="space-y-3 p-6">
            <Banner tone="bad">{weighsError}</Banner>
            <Button variant="outline" onClick={() => void loadWeighs()}>
              Retry
            </Button>
          </div>
        ) : filteredWeighs === null ? (
          <div className="p-8">
            <Spinner />
          </div>
        ) : filteredWeighs.length === 0 ? (
          <div className="p-6 text-sm text-muted">
            No weigh events in this range{verdictFilter !== "all" ? " for this verdict" : ""} yet.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-line bg-black/[0.02] text-xs font-semibold uppercase tracking-wide text-muted">
                <tr>
                  <th className="px-4 py-2.5">Order</th>
                  <th className="px-4 py-2.5">Verdict</th>
                  <th className="px-4 py-2.5">Measured</th>
                  <th className="px-4 py-2.5">Expected range</th>
                  <th className="px-4 py-2.5">Reason</th>
                  <th className="px-4 py-2.5">When</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {filteredWeighs.map((w) => (
                  <tr key={w.eventId} className="transition-colors duration-150 hover:bg-black/[0.03]">
                    <td className="px-4 py-2.5 font-mono text-xs">
                      {w.foodicsOrderId ? (
                        <button
                          type="button"
                          onClick={() => setSelectedWeigh(w)}
                          className="text-muted underline decoration-line decoration-dotted underline-offset-2 transition-colors hover:text-green hover:decoration-green"
                          title={w.orderLabel ? `View order breakdown (${w.foodicsOrderId})` : "View order breakdown"}
                        >
                          {w.orderLabel ?? w.foodicsOrderId}
                        </button>
                      ) : (
                        <span className="text-muted">—</span>
                      )}
                    </td>
                    <td className="px-4 py-2.5">{verdictBadge(w.verdict)}</td>
                    <td className="px-4 py-2.5 font-mono font-semibold">{g(w.measuredG)}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-muted">
                      {w.expectedMinG != null && w.expectedMaxG != null
                        ? `${g(w.expectedMinG)}–${g(w.expectedMaxG)}`
                        : "—"}
                    </td>
                    <td className="px-4 py-2.5 text-xs text-muted">{w.overrideReason ?? "—"}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-muted">
                      {formatTime(w.weighedAt)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      {selectedWeigh && (
        <OrderBreakdownModal
          weigh={selectedWeigh}
          brandId={device?.brandId}
          onClose={() => setSelectedWeigh(null)}
        />
      )}
    </div>
  );
}
