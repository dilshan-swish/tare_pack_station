import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { AlertTriangle, CheckCircle2, Clock, PackageCheck, RefreshCw, Search, Star, X } from "lucide-react";
import { useSession } from "../state/session";
import { useWeighing } from "../state/weighing";
import { focusFor, progressKey, unitsOf } from "../lib/rules";
import { ago, clock } from "../lib/format";
import type { ApiOrder, Unit } from "../lib/types";
import { OrderHeadline } from "../components/OrderHeadline";
import { Button, Pill, Spinner } from "../components/ui";

type Tab = "todo" | "done" | "all";

interface Card {
  order: ApiOrder;
  units: Unit[];
  done: number;
  priority: number;
}

export function OrdersScreen() {
  const { settings, focus, branch, progress } = useSession();
  const { orders, weighed, refresh, storageWarning } = useWeighing();
  const [tab, setTab] = useState<Tab>("todo");
  const [query, setQuery] = useState("");
  const [, setNow] = useState(Date.now());
  const navigate = useNavigate();

  // Keep "12 min ago" labels fresh between polls.
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(t);
  }, []);

  const { cards, hidden } = useMemo(() => {
    const all: Card[] = [];
    let hiddenCount = 0;
    for (const order of orders.orders ?? []) {
      const units = unitsOf(order, settings);
      if (!units.length) {
        hiddenCount++;
        continue;
      }
      let done = 0;
      let priority = 0;
      for (const u of units) {
        if (weighed.has(u.key)) {
          done++;
          continue;
        }
        const reached = (progress.get(progressKey(u.line.productId, u.sizeLabel))?.samples ?? 0) >= settings.target_samples;
        if (!reached && branch && focusFor(u, focus, branch.id)) priority++;
      }
      all.push({ order, units, done, priority });
    }
    return { cards: all, hidden: hiddenCount };
  }, [orders.orders, settings, weighed, progress, focus, branch]);

  const q = query.trim().toLowerCase();
  const matches = (c: Card) => {
    if (!q) return true;
    const o = c.order;
    const digits = q.replace(/[^0-9a-z-]/g, "");
    const hay = [
      o.number !== null ? String(o.number) : "",
      o.aggregatorRef?.replace("…", "") ?? "",
      o.reference ?? "",
      o.checkNumber !== null ? String(o.checkNumber) : "",
    ];
    if (digits && hay.some((h) => h.toLowerCase().includes(digits))) return true;
    return c.units.some((u) => u.line.productName.toLowerCase().includes(q));
  };

  const todo = cards.filter((c) => c.done < c.units.length);
  const done = cards.filter((c) => c.done === c.units.length);
  const shown = (tab === "todo" ? todo : tab === "done" ? done : cards).filter(matches);

  if (orders.orders === null) {
    return (
      <div className="mx-auto max-w-6xl px-4 py-10 sm:px-6">
        {orders.error ? (
          <div className="neo mx-auto max-w-lg p-6 text-center">
            <AlertTriangle className="mx-auto mb-2 text-coral" size={32} />
            <p className="font-semibold text-ink">{orders.error}</p>
            <Button className="mt-5" onClick={refresh} disabled={orders.refreshing}>
              {orders.refreshing ? <Spinner /> : <RefreshCw size={18} />} Try again
            </Button>
          </div>
        ) : (
          <div className="flex flex-col items-center gap-3 py-16 text-cream">
            <Spinner className="h-8 w-8" />
            <span className="font-semibold">Loading live orders…</span>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-6xl px-4 pb-24 pt-2 sm:px-6">
      {orders.error && (
        <div className="animate-rise mb-4 flex items-center gap-2 rounded-2xl border-[2.5px] border-ink bg-amber px-4 py-3 text-sm font-semibold text-ink">
          <AlertTriangle size={18} className="flex-none" />
          <span className="min-w-0 flex-1">
            {orders.error}
            {orders.fetchedAt && ` Showing orders from ${clock(orders.fetchedAt, settings.timezone)}.`}
          </span>
        </div>
      )}
      {storageWarning && (
        <div className="mb-4 rounded-2xl border-[2.5px] border-ink bg-underbg px-4 py-3 text-sm font-semibold text-undertext">
          This browser won't let the app save unsent weights on the device (private mode or storage full). Keep this tab open until everything syncs.
        </div>
      )}

      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <label className="relative flex-1">
          <span className="sr-only">Find an order</span>
          <Search size={20} className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-muted" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            inputMode="search"
            placeholder="Find order # or item"
            className="neo-sm h-14 w-full pl-12 pr-12 text-base font-semibold outline-none placeholder:font-normal placeholder:text-muted"
          />
          {query && (
            <button
              type="button"
              onClick={() => setQuery("")}
              aria-label="Clear search"
              className="absolute right-2 top-1/2 flex h-10 w-10 -translate-y-1/2 items-center justify-center rounded-full text-muted hover:bg-black/5"
            >
              <X size={18} />
            </button>
          )}
        </label>
        <div className="flex gap-2" role="tablist" aria-label="Order filter">
          <TabButton active={tab === "todo"} onClick={() => setTab("todo")} count={todo.length}>
            To weigh
          </TabButton>
          <TabButton active={tab === "done"} onClick={() => setTab("done")} count={done.length}>
            Done
          </TabButton>
          <TabButton active={tab === "all"} onClick={() => setTab("all")} count={cards.length}>
            All
          </TabButton>
        </div>
      </div>

      {shown.length === 0 ? (
        <div className="neo mx-auto mt-8 max-w-lg p-6 text-center">
          {q ? (
            <>
              <p className="font-display text-xl">No match for “{query}”</p>
              <p className="mt-2 text-muted">Check the number on the slip, or try the “All” tab.</p>
            </>
          ) : tab === "todo" ? (
            <>
              <PackageCheck className="mx-auto mb-2 text-green" size={34} />
              <p className="font-display text-xl">All caught up</p>
              <p className="mt-2 text-muted">New orders appear here automatically.</p>
            </>
          ) : (
            <p className="font-display text-xl">Nothing here yet</p>
          )}
        </div>
      ) : (
        <ul className="mt-5 grid gap-5 [grid-template-columns:repeat(auto-fill,minmax(min(100%,17rem),1fr))]">
          {shown.map((c) => (
            <li key={c.order.id}>
              <OrderCard card={c} timeZone={settings.timezone} onOpen={() => navigate(`/order/${encodeURIComponent(c.order.id)}`)} />
            </li>
          ))}
        </ul>
      )}

      {hidden > 0 && (
        <p className="mt-6 text-center text-sm font-semibold text-cream/80">
          {hidden} order{hidden === 1 ? "" : "s"} with nothing to weigh (staff meals, drinks, sauces) {hidden === 1 ? "is" : "are"} hidden.
        </p>
      )}
    </div>
  );
}

function TabButton({
  active,
  onClick,
  count,
  children,
}: {
  active: boolean;
  onClick: () => void;
  count: number;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      onClick={onClick}
      className={`press flex min-h-[52px] flex-1 items-center justify-center gap-1.5 whitespace-nowrap rounded-full border-[2.5px] border-ink px-3 text-sm font-bold sm:flex-none sm:gap-2 sm:px-4 ${
        active ? "bg-ink text-cream" : "bg-cream text-ink shadow-[3px_3px_0_rgb(22_27_20/0.9)]"
      }`}
    >
      {children}
      <span className={`rounded-full px-2 py-0.5 font-mono text-xs ${active ? "bg-cream text-ink" : "bg-ink/10"}`}>{count}</span>
    </button>
  );
}

function OrderCard({ card, timeZone, onOpen }: { card: Card; timeZone: string; onOpen: () => void }) {
  const { order, units, done, priority } = card;
  const total = units.length;
  const complete = done === total;
  const ready = order.status === 4;
  const pct = total ? Math.round((done / total) * 100) : 0;
  return (
    <button
      type="button"
      onClick={onOpen}
      className={`press neo flex h-full w-full flex-col gap-3 p-4 text-left ${complete ? "opacity-75" : ""}`}
    >
      <div className="flex items-start justify-between gap-2">
        <OrderHeadline order={order} />
        {complete ? (
          <CheckCircle2 size={30} className="flex-none text-green" aria-label="All weighed" />
        ) : (
          <Pill tone={ready ? "ok" : "amber"}>{ready ? "Ready" : "Preparing"}</Pill>
        )}
      </div>
      <div className="flex items-center gap-1.5 font-mono text-xs text-muted">
        <Clock size={13} />
        {clock(order.receivedAt, timeZone)} · {ago(order.receivedAt)}
      </div>
      <div className="mt-auto">
        <div className="mb-1.5 flex items-center justify-between gap-2 text-sm font-bold">
          <span>
            <span className="font-mono">{done}/{total}</span> weighed
          </span>
          {priority > 0 && (
            <Pill tone="amber">
              <Star size={12} fill="currentColor" /> {priority} priority
            </Pill>
          )}
        </div>
        <div className="h-3 overflow-hidden rounded-full border-2 border-ink bg-white/60" aria-hidden>
          <div className="h-full bg-green transition-all" style={{ width: `${pct}%` }} />
        </div>
      </div>
    </button>
  );
}
