import { useEffect, useRef, useState, type CSSProperties, type ReactNode, type ButtonHTMLAttributes, type InputHTMLAttributes } from "react";
import { createPortal } from "react-dom";

// Clean, brand-accented building blocks with tasteful motion.

export function Card({
  children,
  className = "",
  hover = false,
  style,
}: {
  children: ReactNode;
  className?: string;
  hover?: boolean;
  style?: CSSProperties;
}) {
  return (
    <div
      style={style}
      className={
        "rounded-2xl border border-line bg-white card-shadow transition-all duration-300 ease-out " +
        (hover ? "hover:-translate-y-1 hover:border-green/30 hover:card-shadow-hover " : "") +
        className
      }
    >
      {children}
    </div>
  );
}

type BtnVariant = "primary" | "outline" | "danger" | "ghost";

export function Button({
  variant = "primary",
  className = "",
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: BtnVariant }) {
  const base =
    "inline-flex items-center justify-center gap-2 rounded-xl font-semibold px-4 py-2.5 text-sm transition-all duration-150 ease-out active:scale-[0.97] disabled:opacity-40 disabled:cursor-not-allowed disabled:active:scale-100 disabled:hover:translate-y-0 disabled:hover:shadow-none cursor-pointer select-none";
  const styles: Record<BtnVariant, string> = {
    primary: "bg-green text-white card-shadow hover:-translate-y-px hover:bg-green-dark hover:card-shadow-hover",
    outline:
      "border border-line bg-white text-ink hover:-translate-y-px hover:border-ink hover:bg-black/[0.03] hover:card-shadow-hover",
    danger: "bg-badbg text-badtext border border-badtext/40 hover:bg-badbg/70",
    ghost: "bg-transparent text-muted hover:bg-black/[0.04] hover:text-ink",
  };
  return (
    <button className={`${base} ${styles[variant]} ${className}`} {...rest}>
      {children}
    </button>
  );
}

export function Badge({
  children,
  tone = "neutral",
}: {
  children: ReactNode;
  tone?: "neutral" | "ok" | "warn" | "bad";
}) {
  const tones = {
    neutral: "bg-black/[0.04] text-muted",
    ok: "bg-okbg text-oktext",
    warn: "bg-warnbg text-[#8a5a10]",
    bad: "bg-badbg text-badtext",
  } as const;
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-bold transition-colors duration-300 ${tones[tone]}`}
    >
      {children}
    </span>
  );
}

/// A pill that toggles between an "on" (selected) and "off" state on click —
/// for building a multi-select out of a handful of options (brands, verdicts)
/// without a native <select multiple>, which can't be styled to match the
/// rest of the portal and reads poorly with only a few options.
export function TogglePill({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={`rounded-full border px-3 py-1.5 text-xs font-semibold transition-all duration-150 ease-out active:scale-[0.96] ${
        active
          ? "border-green bg-green text-white card-shadow"
          : "border-line bg-white text-muted hover:-translate-y-px hover:border-ink/30 hover:text-ink"
      }`}
    >
      {children}
    </button>
  );
}

/// A small "is this thing alive" indicator — solid when idle, with a soft
/// looping pulse ring while genuinely online. Shared by every screen that
/// shows a scale's connection state, so the effect (and its meaning) stays
/// consistent app-wide.
export function StatusDot({ online, title }: { online: boolean; title?: string }) {
  return (
    <span className="relative inline-flex h-2.5 w-2.5 shrink-0" title={title ?? (online ? "online" : "offline")}>
      {online && (
        <span className="status-pulse absolute inline-flex h-full w-full rounded-full bg-green" />
      )}
      <span
        className={`relative inline-flex h-2.5 w-2.5 rounded-full ${online ? "bg-green" : "bg-black/20"}`}
      />
    </span>
  );
}

export function NumberInput({
  className = "",
  style,
  ...rest
}: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      type="number"
      inputMode="decimal"
      min={0}
      // No up/down spinner — these are weight fields typed or pasted in,
      // not counters someone clicks through one unit at a time.
      className={
        "w-full rounded-lg border border-line bg-white px-3 py-2 font-mono text-sm outline-none transition focus:border-green focus:ring-2 focus:ring-green/20 " +
        "[appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none " +
        className
      }
      style={{ MozAppearance: "textfield", ...style }}
      {...rest}
    />
  );
}

export function TextInput({
  className = "",
  ...rest
}: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={
        "w-full rounded-lg border border-line bg-white px-3.5 py-2 text-sm outline-none transition focus:border-green focus:ring-2 focus:ring-green/20 " +
        className
      }
      {...rest}
    />
  );
}

// A themed dropdown for filters etc. — a plain <select>'s open panel is drawn
// by the OS/browser and can't be restyled, so this is a real listbox built
// from divs/buttons to match the rest of the portal (rounded pill trigger,
// card-shadow panel, green highlight for the selected row).
export function Select<T extends string>({
  value,
  onChange,
  options,
}: {
  value: T;
  onChange: (v: T) => void;
  options: { value: T; label: string }[];
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const current = options.find((o) => o.value === value) ?? options[0];

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
        className="flex items-center gap-2 rounded-full border border-line bg-white px-3.5 py-2 text-sm font-semibold text-muted outline-none transition hover:border-ink/30 focus:border-green focus:ring-2 focus:ring-green/20"
      >
        {current?.label}
        <svg
          width="10"
          height="6"
          viewBox="0 0 10 6"
          fill="none"
          className={`shrink-0 text-muted transition-transform duration-150 ${open ? "-rotate-180" : ""}`}
        >
          <path
            d="M1 1l4 4 4-4"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </button>
      {open && (
        <div
          role="listbox"
          className="animate-pop-in absolute left-0 z-20 mt-1.5 min-w-full overflow-hidden rounded-xl border border-line bg-white py-1 card-shadow-hover"
        >
          {options.map((o) => (
            <button
              key={o.value}
              type="button"
              role="option"
              aria-selected={o.value === value}
              onClick={() => {
                onChange(o.value);
                setOpen(false);
              }}
              className={`block w-full whitespace-nowrap px-3.5 py-2 text-left text-sm font-semibold transition-colors ${
                o.value === value ? "bg-green/10 text-green-dark" : "text-ink hover:bg-black/[0.04]"
              }`}
            >
              {o.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// A centered overlay dialog — used where an action needs focus pulled off
// the page (e.g. weighing a single modifier option) instead of expanding
// content inline and reflowing whatever's around it.
export function Modal({
  open,
  onClose,
  title,
  children,
  entrance = "pop",
  maxWidth = "max-w-sm",
}: {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: ReactNode;
  /// "pop" is the default gentle scale-in used everywhere; "turn" is a
  /// heavier 3D flip-and-settle for a moment worth a bit more presence (e.g.
  /// revealing a full order breakdown), not meant for routine dialogs.
  entrance?: "pop" | "turn";
  /// Tailwind max-width class — the default "max-w-sm" suits a short
  /// confirmation; content with real structure (a receipt, a table) wants
  /// more room. Always still `w-full` under that, so it stays responsive
  /// down to phone widths.
  maxWidth?: string;
}) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  if (!open) return null;

  // Rendered via a portal straight onto <body> — NOT as a plain nested
  // child. A `position: fixed` element normally covers the whole viewport,
  // but any ANCESTOR with a `transform` (e.g. Card's `hover:-translate-y-0.5`
  // hover-lift) creates its own containing block, which traps a nested fixed
  // element inside that ancestor's bounds instead. That's exactly what made
  // this dim only the item card behind it, and then flicker as the mouse
  // crossed the card's hover boundary (transform toggling on/off mid-open).
  // Portaling to <body> guarantees this is never nested inside anything
  // that could apply such a transform.
  return createPortal(
    <div
      className="animate-fade-up fixed inset-0 z-50 flex items-center justify-center bg-ink/40 p-4"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        className={`${entrance === "turn" ? "animate-turn-pop-in" : "animate-pop-in"} w-full ${maxWidth} rounded-2xl border border-line bg-white p-5 card-shadow-hover`}
      >
        {title && (
          <div className="mb-4 flex items-center justify-between gap-3">
            <h3 className="text-base font-extrabold tracking-tight text-ink">{title}</h3>
            <button
              type="button"
              onClick={onClose}
              aria-label="Close"
              className="flex h-7 w-7 items-center justify-center rounded-full text-muted transition hover:bg-black/[0.05] hover:text-ink"
            >
              ✕
            </button>
          </div>
        )}
        {children}
      </div>
    </div>,
    document.body,
  );
}

export function Banner({
  tone = "bad",
  children,
}: {
  tone?: "bad" | "ok" | "warn";
  children: ReactNode;
}) {
  const tones = {
    bad: "bg-badbg text-badtext",
    ok: "bg-okbg text-oktext",
    warn: "bg-warnbg text-[#8a5a10]",
  } as const;
  return (
    <div
      className={`animate-fade-up rounded-xl px-4 py-3 text-sm font-semibold ${tones[tone]}`}
    >
      {children}
    </div>
  );
}

export function Spinner() {
  return (
    <div className="flex justify-center py-16">
      <div className="h-8 w-8 animate-spin rounded-full border-[3px] border-line border-t-green" />
    </div>
  );
}

/// A small inline spinner for a button's own busy state — pairs with a label
/// ("Syncing…") so a busy action reads as active work, not a frozen click.
export function ButtonSpinner({ className = "" }: { className?: string }) {
  return (
    <span
      className={`inline-block h-3.5 w-3.5 shrink-0 animate-spin rounded-full border-2 border-current/25 border-t-current ${className}`}
      aria-hidden
    />
  );
}

export function Coverage({
  total,
  missing,
  compact = false,
}: {
  total: number;
  missing: number;
  compact?: boolean;
}) {
  const done = Math.max(0, total - missing);
  const pct = total > 0 ? Math.round((done / total) * 100) : 0;
  const full = pct === 100;
  return (
    <div>
      {!compact && (
        <div className="mb-1 flex justify-between text-xs font-semibold text-muted">
          <span>
            {done} of {total} weighed
          </span>
          <span className="font-mono">{pct}%</span>
        </div>
      )}
      <div className="h-2 w-full overflow-hidden rounded-full bg-black/[0.06]">
        <div
          className={`h-full rounded-full transition-all duration-500 ${full ? "bg-green" : "bg-amber"}`}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}

// --- Date range filtering: a themed calendar (native <input type="date">
// can't be restyled at all — it's OS/browser shadow DOM) plus a preset
// dropdown for the common cases, so most filtering never needs the calendar.

/** yyyy-mm-dd, built from LOCAL date parts — never round-tripped through
 * ISO/UTC, which can silently roll the date back a day in timezones behind
 * UTC. */
function toDateInputValue(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}
function fromDateInputValue(s: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (!m) return null;
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
}

const RANGE_PRESETS = [
  { key: "today", label: "Today" },
  { key: "this_week", label: "This week" },
  { key: "this_month", label: "This month" },
  { key: "this_year", label: "This year" },
  { key: "7d", label: "Last 7 days" },
  { key: "30d", label: "Last 30 days" },
  { key: "90d", label: "Last 90 days" },
  { key: "all", label: "All time" },
  { key: "custom", label: "Custom range" },
] as const;
export type RangePresetKey = (typeof RANGE_PRESETS)[number]["key"];
export const RANGE_PRESET_OPTIONS = RANGE_PRESETS.map((p) => ({ value: p.key, label: p.label }));

/** Resolves a preset to a {from, to} ISO range. "custom"/"all" resolve to an
 * empty object — the caller supplies its own explicit from/to for "custom",
 * and an empty object already means "no filter" for "all". */
export function resolvePresetRange(key: RangePresetKey): { from?: string; to?: string } {
  const now = new Date();
  const startOfDay = (d: Date) => {
    const x = new Date(d);
    x.setHours(0, 0, 0, 0);
    return x;
  };
  switch (key) {
    case "today":
      return { from: startOfDay(now).toISOString() };
    case "this_week": {
      const d = startOfDay(now);
      d.setDate(d.getDate() - d.getDay());
      return { from: d.toISOString() };
    }
    case "this_month":
      return { from: new Date(now.getFullYear(), now.getMonth(), 1).toISOString() };
    case "this_year":
      return { from: new Date(now.getFullYear(), 0, 1).toISOString() };
    case "7d":
      return { from: new Date(now.getTime() - 7 * 86_400_000).toISOString() };
    case "30d":
      return { from: new Date(now.getTime() - 30 * 86_400_000).toISOString() };
    case "90d":
      return { from: new Date(now.getTime() - 90 * 86_400_000).toISOString() };
    case "all":
    case "custom":
      return {};
  }
}

function Calendar({
  value,
  onPick,
}: {
  value: string; // yyyy-mm-dd, or ""
  onPick: (v: string) => void;
}) {
  const selected = value ? fromDateInputValue(value) : null;
  const initial = selected ?? new Date();
  const [viewYear, setViewYear] = useState(initial.getFullYear());
  const [viewMonth, setViewMonth] = useState(initial.getMonth());

  const firstWeekday = new Date(viewYear, viewMonth, 1).getDay();
  const numDays = new Date(viewYear, viewMonth + 1, 0).getDate();
  const monthLabel = new Date(viewYear, viewMonth, 1).toLocaleDateString(undefined, {
    month: "long",
    year: "numeric",
  });
  const today = toDateInputValue(new Date());

  function shiftMonth(delta: number) {
    let m = viewMonth + delta;
    let y = viewYear;
    if (m < 0) {
      m = 11;
      y -= 1;
    } else if (m > 11) {
      m = 0;
      y += 1;
    }
    setViewMonth(m);
    setViewYear(y);
  }

  const cells: (number | null)[] = [
    ...Array<null>(firstWeekday).fill(null),
    ...Array.from({ length: numDays }, (_, i) => i + 1),
  ];

  return (
    <div className="w-64 rounded-2xl border border-line bg-white p-3 card-shadow-hover">
      <div className="mb-2 flex items-center justify-between">
        <button
          type="button"
          onClick={() => shiftMonth(-1)}
          aria-label="Previous month"
          className="flex h-7 w-7 items-center justify-center rounded-full text-muted transition hover:bg-black/[0.05] hover:text-ink"
        >
          ‹
        </button>
        <span className="text-sm font-bold text-ink">{monthLabel}</span>
        <button
          type="button"
          onClick={() => shiftMonth(1)}
          aria-label="Next month"
          className="flex h-7 w-7 items-center justify-center rounded-full text-muted transition hover:bg-black/[0.05] hover:text-ink"
        >
          ›
        </button>
      </div>
      <div className="grid grid-cols-7 gap-y-1 text-center text-[11px] font-semibold text-muted">
        {["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"].map((d) => (
          <div key={d}>{d}</div>
        ))}
      </div>
      <div className="mt-1 grid grid-cols-7 gap-y-1">
        {cells.map((day, i) => {
          if (day === null) return <div key={i} />;
          const iso = toDateInputValue(new Date(viewYear, viewMonth, day));
          const isSelected = iso === value;
          const isToday = iso === today;
          return (
            <div key={i} className="flex justify-center">
              <button
                type="button"
                onClick={() => onPick(iso)}
                className={`flex h-8 w-8 items-center justify-center rounded-full text-sm transition-colors duration-150 ${
                  isSelected
                    ? "bg-green font-bold text-white"
                    : isToday
                      ? "font-bold text-green"
                      : "text-ink hover:bg-black/[0.06]"
                }`}
              >
                {day}
              </button>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** A themed date field — a button showing the chosen date that opens a
 * calendar popover, replacing the native (unstylable) `<input type="date">`. */
export function DateField({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string; // yyyy-mm-dd, or "" for unset
  onChange: (v: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const display = value
    ? (fromDateInputValue(value)?.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) ?? value)
    : "Select date";

  return (
    <div ref={rootRef} className="relative">
      <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">{label}</span>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="dialog"
        aria-expanded={open}
        className={`flex items-center gap-2 rounded-lg border bg-white px-3 py-1.5 text-sm font-semibold outline-none transition focus:border-green focus:ring-2 focus:ring-green/20 ${
          value ? "border-line text-ink" : "border-line text-muted"
        } hover:border-ink/30`}
      >
        {display}
        <svg
          width="10"
          height="6"
          viewBox="0 0 10 6"
          fill="none"
          className={`shrink-0 text-muted transition-transform duration-150 ${open ? "-rotate-180" : ""}`}
        >
          <path d="M1 1l4 4 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
      {open && (
        <div className="animate-pop-in absolute left-0 z-30 mt-1.5">
          <Calendar
            value={value}
            onPick={(v) => {
              onChange(v);
              setOpen(false);
            }}
          />
        </div>
      )}
    </div>
  );
}

/** A preset dropdown ("Today", "This month", …) plus a themed custom-range
 * calendar pair shown only when "Custom range" is picked — the one filter
 * control used everywhere a date range is needed (the weighed-orders export,
 * a scale's weigh history), so both always match and both stay themed. */
export function DateRangeFilter({
  preset,
  onPresetChange,
  customFrom,
  customTo,
  onCustomChange,
}: {
  preset: RangePresetKey;
  onPresetChange: (p: RangePresetKey) => void;
  customFrom: string;
  customTo: string;
  onCustomChange: (from: string, to: string) => void;
}) {
  return (
    <div className="flex flex-wrap items-end gap-2">
      <div>
        <span className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Date range</span>
        <Select value={preset} onChange={onPresetChange} options={RANGE_PRESET_OPTIONS} />
      </div>
      {preset === "custom" && (
        <div className="animate-fade-up flex flex-wrap items-end gap-2">
          <DateField label="From" value={customFrom} onChange={(v) => onCustomChange(v, customTo)} />
          <DateField label="To" value={customTo} onChange={(v) => onCustomChange(customFrom, v)} />
        </div>
      )}
    </div>
  );
}
