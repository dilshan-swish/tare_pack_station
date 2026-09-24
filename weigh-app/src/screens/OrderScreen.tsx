import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { ArrowLeft, Check, ChevronDown, ChevronUp, CloudUpload, Pencil, Star, Undo2 } from "lucide-react";
import { useSession } from "../state/session";
import { useWeighing } from "../state/weighing";
import { checkWeight, fmt, focusFor, progressKey, skippedCount, unitsOf } from "../lib/rules";
import { ago, clock } from "../lib/format";
import type { AppSettings, FocusItem, ItemProgress, Unit, WeighedState } from "../lib/types";
import { OrderHeadline } from "../components/OrderHeadline";
import { Button, Pill, Sheet, Spinner } from "../components/ui";

export function OrderScreen() {
  const { orderId = "" } = useParams();
  const id = decodeURIComponent(orderId);
  const navigate = useNavigate();
  const { settings, focus, branch, progress } = useSession();
  const { orders, weighed, save, remove } = useWeighing();
  const [focusKey, setFocusKey] = useState<string | null>(null);

  const order = orders.orders?.find((o) => o.id === id) ?? null;
  const units = useMemo(() => (order ? unitsOf(order, settings) : []), [order, settings]);
  const firstOpen = units.find((u) => !weighed.has(u.key))?.key ?? null;

  // Put the cursor in the first unweighed item as soon as the order opens.
  const didInitialFocus = useRef(false);
  useEffect(() => {
    if (!didInitialFocus.current && firstOpen) {
      didInitialFocus.current = true;
      setFocusKey(firstOpen);
    }
  }, [firstOpen]);

  if (!order) {
    return (
      <div className="mx-auto max-w-2xl px-4 py-10">
        {orders.orders === null ? (
          <div className="flex justify-center py-16 text-cream">
            <Spinner className="h-8 w-8" />
          </div>
        ) : (
          <div className="neo p-6 text-center">
            <p className="font-display text-xl">This order isn't in the live list any more</p>
            <p className="mt-2 text-muted">It may be older than 24 hours, voided or returned in Foodics.</p>
            <Link to="/" className="mt-5 inline-block">
              <Button>Back to orders</Button>
            </Link>
          </div>
        )}
      </div>
    );
  }

  const doneCount = units.filter((u) => weighed.has(u.key)).length;
  const complete = units.length > 0 && doneCount === units.length;
  const skipped = skippedCount(order, settings);

  const nextOrder = (orders.orders ?? []).find(
    (o) => o.id !== order.id && unitsOf(o, settings).some((u) => !weighed.has(u.key)),
  );

  const handleSaved = (key: string) => {
    const idx = units.findIndex((u) => u.key === key);
    const next = units.slice(idx + 1).find((u) => !weighed.has(u.key) && u.key !== key)
      ?? units.find((u) => !weighed.has(u.key) && u.key !== key);
    setFocusKey(next?.key ?? null);
  };

  return (
    <div className="mx-auto max-w-2xl px-4 pb-28 pt-2 sm:px-6">
      <div className="neo mb-5 p-4 sm:p-5">
        <div className="flex items-start gap-3">
          <button
            type="button"
            // Opened from a bookmark/refresh there's no in-app page to go back to.
            onClick={() => ((window.history.state?.idx ?? 0) > 0 ? navigate(-1) : navigate("/"))}
            aria-label="Back to orders"
            className="press -ml-1 flex h-12 w-12 flex-none items-center justify-center rounded-full border-[2.5px] border-ink bg-white shadow-[3px_3px_0_rgb(22_27_20/0.9)]"
          >
            <ArrowLeft size={22} />
          </button>
          <div className="min-w-0 flex-1">
            <OrderHeadline order={order} size="lg" />
            <div className="mt-2 flex flex-wrap items-center gap-2 font-mono text-xs text-muted">
              <Pill tone={order.status === 4 ? "ok" : "amber"}>{order.status === 4 ? "Ready" : "Preparing"}</Pill>
              Received {clock(order.receivedAt, settings.timezone)} · {ago(order.receivedAt)}
            </div>
          </div>
        </div>
        <div className="mt-4 flex items-center justify-between text-sm font-bold">
          <span>
            <span className="font-mono">{doneCount} of {units.length}</span> weighed
          </span>
          {skipped > 0 && (
            <span className="text-xs font-semibold text-muted">
              {skipped} item{skipped === 1 ? "" : "s"} don't need weighing
            </span>
          )}
        </div>
        <div className="mt-1.5 h-3 overflow-hidden rounded-full border-2 border-ink bg-white/60" aria-hidden>
          <div className="h-full bg-green transition-all" style={{ width: `${units.length ? (doneCount / units.length) * 100 : 0}%` }} />
        </div>
      </div>

      {units.length === 0 ? (
        <div className="neo p-6 text-center text-muted">Nothing on this order needs weighing.</div>
      ) : (
        <ol className="space-y-4">
          {units.map((u) => (
            <li key={u.key}>
              <UnitRow
                unit={u}
                state={weighed.get(u.key)}
                settings={settings}
                focusItem={branch ? focusFor(u, focus, branch.id) : null}
                progress={progress.get(progressKey(u.line.productId, u.sizeLabel))}
                wantFocus={focusKey === u.key}
                onFocused={() => setFocusKey(null)}
                onSave={(w) => {
                  save(u, w);
                  handleSaved(u.key);
                }}
                onRemove={() => remove(u)}
              />
            </li>
          ))}
        </ol>
      )}

      {complete && (
        <div className="animate-rise neo mt-6 bg-okbg p-5 text-center">
          <p className="flex items-center justify-center gap-2 font-display text-xl text-oktext">
            <Check size={24} strokeWidth={3} /> All items weighed
          </p>
          <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:justify-center">
            {nextOrder && (
              <Button variant="ink" size="lg" onClick={() => navigate(`/order/${encodeURIComponent(nextOrder.id)}`, { replace: true })}>
                Next order to weigh
              </Button>
            )}
            <Button variant="cream" size="lg" onClick={() => navigate("/")}>
              Back to orders
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function UnitRow({
  unit,
  state,
  settings,
  focusItem,
  progress,
  wantFocus,
  onFocused,
  onSave,
  onRemove,
}: {
  unit: Unit;
  state: WeighedState | undefined;
  settings: AppSettings;
  focusItem: FocusItem | null;
  progress: ItemProgress | undefined;
  wantFocus: boolean;
  onFocused: () => void;
  onSave: (weight: number) => void;
  onRemove: () => Promise<boolean>;
}) {
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<{ value: number; message: string } | null>(null);
  const [showDetails, setShowDetails] = useState(false);
  const [removing, setRemoving] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const showInput = !state || editing;
  const samples = progress?.samples ?? 0;
  const reached = samples >= settings.target_samples;

  useEffect(() => {
    if (wantFocus && showInput) {
      inputRef.current?.focus({ preventScroll: false });
      inputRef.current?.scrollIntoView({ block: "center", behavior: "smooth" });
      onFocused();
    }
  }, [wantFocus, showInput, onFocused]);

  const commit = (v: number) => {
    onSave(v);
    setEditing(false);
    setValue("");
    setError(null);
    setConfirm(null);
  };

  const submit = () => {
    const { value: v, check } = checkWeight(value, settings, progress);
    if (check.kind === "invalid" || v === null) {
      setError(check.kind === "invalid" ? check.message : "Enter the weight in grams.");
      inputRef.current?.focus();
      return;
    }
    if (check.kind === "unusual") {
      setConfirm({ value: v, message: check.message });
      return;
    }
    commit(v);
  };

  return (
    <div className={`neo p-4 sm:p-5 ${state && !editing ? "bg-okbg" : ""}`}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="text-lg font-extrabold leading-snug text-ink sm:text-xl">{unit.line.productName}</h3>
          <div className="mt-1.5 flex flex-wrap gap-1.5">
            {unit.sizeLabel && <Pill tone="ink">{unit.sizeLabel}</Pill>}
            {unit.unitCount > 1 && (
              <Pill tone="cream">
                {unit.unitIndex + 1} of {unit.unitCount}
              </Pill>
            )}
            {focusItem && !reached && (
              <Pill tone="amber">
                <Star size={12} fill="currentColor" /> Priority
              </Pill>
            )}
            {reached ? (
              <Pill tone="ok">
                <Check size={12} strokeWidth={3} /> Target reached · optional
              </Pill>
            ) : (
              <Pill tone="muted">
                <span className="font-mono">{samples}/{settings.target_samples}</span> samples
              </Pill>
            )}
          </div>
        </div>
        {unit.line.modifiers.length > 0 && (
          <button
            type="button"
            onClick={() => setShowDetails((s) => !s)}
            aria-expanded={showDetails}
            className="flex h-11 flex-none items-center gap-1 rounded-full px-3 text-xs font-bold text-muted hover:bg-black/5"
          >
            Details {showDetails ? <ChevronUp size={15} /> : <ChevronDown size={15} />}
          </button>
        )}
      </div>

      {showDetails && (
        <ul className="mt-2 flex flex-wrap gap-1.5">
          {unit.line.modifiers.map((m) => (
            <li key={m.id} className="rounded-full bg-black/5 px-2.5 py-1 text-xs font-semibold text-muted">
              {m.name}
            </li>
          ))}
        </ul>
      )}

      {showInput ? (
        <form
          className="mt-4"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          <div className="flex gap-3">
            <label className="relative min-w-0 flex-1">
              <span className="sr-only">Weight of {unit.line.productName} in grams</span>
              <input
                ref={inputRef}
                value={value}
                onChange={(e) => {
                  setValue(e.target.value);
                  if (error) setError(null);
                }}
                inputMode="decimal"
                autoComplete="off"
                enterKeyHint="done"
                placeholder="0"
                aria-invalid={!!error}
                className={`h-16 w-full rounded-2xl border-[2.5px] bg-white pl-4 pr-12 font-mono text-3xl font-bold text-ink outline-none placeholder:text-ink/25 focus:shadow-[0_0_0_4px_rgb(243_169_59/0.6)] ${
                  error ? "border-coral" : "border-ink"
                }`}
              />
              <span className="pointer-events-none absolute right-4 top-1/2 -translate-y-1/2 font-mono text-xl font-bold text-muted">g</span>
            </label>
            <Button type="submit" size="lg" className="min-w-[6.5rem]">
              Save
            </Button>
          </div>
          {error && (
            <p role="alert" className="mt-2 text-sm font-bold text-undertext">
              {error}
            </p>
          )}
          {editing && (
            <button
              type="button"
              onClick={() => {
                setEditing(false);
                setError(null);
                setValue("");
              }}
              className="mt-3 min-h-[44px] text-sm font-bold text-muted underline-offset-2 hover:underline"
            >
              Cancel change
            </button>
          )}
        </form>
      ) : (
        <div className="mt-4 flex flex-wrap items-center gap-3">
          <div className="flex w-full items-center gap-2 sm:w-auto sm:flex-1">
            <span className="flex h-9 w-9 flex-none items-center justify-center rounded-full bg-green text-white">
              <Check size={20} strokeWidth={3} />
            </span>
            <span className="whitespace-nowrap font-mono text-3xl font-bold text-ink">{fmt(state!.weight)} g</span>
            {state!.status === "pending" && (
              <span className="flex items-center gap-1 text-xs font-bold text-muted">
                <CloudUpload size={14} /> waiting to sync
              </span>
            )}
          </div>
          <div className="flex gap-2">
            <Button
              variant="cream"
              size="sm"
              onClick={() => {
                setEditing(true);
                setValue(String(state!.weight));
                window.setTimeout(() => inputRef.current?.select(), 0);
              }}
            >
              <Pencil size={16} /> Change
            </Button>
            <Button
              variant="danger"
              size="sm"
              disabled={removing}
              onClick={async () => {
                setRemoving(true);
                await onRemove();
                setRemoving(false);
              }}
            >
              {removing ? <Spinner className="h-4 w-4" /> : <Undo2 size={16} />} Undo
            </Button>
          </div>
        </div>
      )}

      <Sheet open={!!confirm} onClose={() => setConfirm(null)} title="Double-check this weight">
        <p className="text-base font-semibold text-ink">{confirm?.message}</p>
        <p className="mt-1 text-sm text-muted">A slip of the finger (an extra 0) is the usual cause.</p>
        <div className="mt-5 flex flex-col gap-3 sm:flex-row-reverse">
          <Button
            variant="ink"
            size="lg"
            className="flex-1"
            onClick={() => {
              setConfirm(null);
              window.setTimeout(() => inputRef.current?.select(), 0);
            }}
          >
            Fix it
          </Button>
          <Button variant="cream" size="lg" className="flex-1" onClick={() => confirm && commit(confirm.value)}>
            Save {confirm ? fmt(confirm.value) : ""} g anyway
          </Button>
        </div>
      </Sheet>
    </div>
  );
}
