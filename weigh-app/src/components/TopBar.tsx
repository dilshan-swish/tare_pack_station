import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link, useLocation } from "react-router-dom";
import { History, ListChecks, LogOut, Menu, RefreshCw, WifiOff, X } from "lucide-react";
import { useSession } from "../state/session";
import { useWeighing } from "../state/weighing";
import { sessionState } from "../lib/format";
import { Spinner } from "./ui";

export function TopBar() {
  const { branch, settings, signOut } = useSession();
  const { online, pendingCount, todayCount, orders, refresh } = useWeighing();
  const [menuOpen, setMenuOpen] = useState(false);
  const [, setTick] = useState(0);
  const menuRef = useRef<HTMLDivElement>(null);
  const loc = useLocation();

  // Re-render each minute so the session countdown stays right.
  useEffect(() => {
    const t = window.setInterval(() => setTick((x) => x + 1), 60_000);
    return () => window.clearInterval(t);
  }, []);

  useEffect(() => setMenuOpen(false), [loc.pathname]);
  useEffect(() => {
    if (!menuOpen) return;
    const onDown = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setMenuOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [menuOpen]);

  const sess = branch ? sessionState(branch.session_start, branch.session_end, settings.timezone) : null;

  return (
    <header className="sticky top-0 z-30 bg-green/95 backdrop-blur pt-[env(safe-area-inset-top)]">
      <div className="mx-auto flex max-w-6xl items-center gap-3 px-4 py-3 sm:px-6">
        <Link to="/" className="min-w-0 flex-1" aria-label="Orders">
          <div className="truncate font-display text-xl leading-tight text-cream sm:text-2xl">
            {branch?.brand_code ?? "BBT"} · {branch?.name ?? ""}
          </div>
          <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs font-semibold text-cream/85">
            {todayCount !== null && (
              <span className="font-mono">
                {todayCount} weighed today
              </span>
            )}
            {sess && (
              <span className={`rounded-full px-2 py-0.5 ${sess.live ? "bg-cream text-green-dark" : "bg-green-dark text-cream"}`}>
                {sess.label}
              </span>
            )}
          </div>
        </Link>

        <SyncBadge online={online} pending={pendingCount} failing={!!orders.error} />

        <button
          type="button"
          onClick={() => refresh()}
          aria-label="Refresh orders"
          className="press hidden h-12 w-12 flex-none items-center justify-center rounded-full border-[2.5px] border-ink bg-cream text-ink shadow-[3px_3px_0_rgb(22_27_20/0.9)] sm:flex"
        >
          {orders.refreshing ? <Spinner /> : <RefreshCw size={20} />}
        </button>

        <div ref={menuRef} className="relative">
          <button
            type="button"
            onClick={() => setMenuOpen((o) => !o)}
            aria-label="Menu"
            aria-expanded={menuOpen}
            className="press flex h-12 w-12 flex-none items-center justify-center rounded-full border-[2.5px] border-ink bg-cream text-ink shadow-[3px_3px_0_rgb(22_27_20/0.9)]"
          >
            {menuOpen ? <X size={22} /> : <Menu size={22} />}
          </button>
          {menuOpen && (
            <div className="animate-rise neo-sm absolute right-0 mt-3 w-60 overflow-hidden p-1.5">
              <MenuLink to="/" icon={<ListChecks size={19} />}>Orders</MenuLink>
              <MenuLink to="/history" icon={<History size={19} />}>My weighings</MenuLink>
              <button
                type="button"
                onClick={() => {
                  setMenuOpen(false);
                  refresh();
                }}
                className="flex min-h-[48px] w-full items-center gap-3 rounded-xl px-3 text-left font-semibold hover:bg-black/5"
              >
                <RefreshCw size={19} /> Refresh orders
              </button>
              <button
                type="button"
                onClick={() => {
                  if (pendingCount && !window.confirm(`${pendingCount} weight(s) haven't synced yet. Sign out anyway? They stay on this device and sync when this branch signs in again.`)) return;
                  void signOut();
                }}
                className="flex min-h-[48px] w-full items-center gap-3 rounded-xl px-3 text-left font-semibold text-undertext hover:bg-underbg"
              >
                <LogOut size={19} /> Sign out
              </button>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}

function MenuLink({ to, icon, children }: { to: string; icon: ReactNode; children: ReactNode }) {
  return (
    <Link to={to} className="flex min-h-[48px] items-center gap-3 rounded-xl px-3 font-semibold hover:bg-black/5">
      {icon} {children}
    </Link>
  );
}

function SyncBadge({ online, pending, failing }: { online: boolean; pending: number; failing: boolean }) {
  if (!online) {
    return (
      <span className="flex flex-none items-center gap-1.5 rounded-full border-2 border-ink bg-underbg px-2.5 py-1 text-xs font-bold text-undertext">
        <WifiOff size={14} /> Offline{pending ? ` · ${pending} to sync` : ""}
      </span>
    );
  }
  if (pending) {
    return (
      <span className="flex flex-none items-center gap-1.5 rounded-full border-2 border-ink bg-amber px-2.5 py-1 text-xs font-bold text-ink">
        <Spinner className="h-3.5 w-3.5 border-2" /> {pending} syncing
      </span>
    );
  }
  return (
    <span
      className={`hidden flex-none items-center gap-1.5 rounded-full border-2 px-2.5 py-1 text-xs font-bold sm:flex ${
        failing ? "border-ink bg-amber text-ink" : "border-cream/60 text-cream"
      }`}
    >
      <span className={`h-2 w-2 rounded-full ${failing ? "bg-ink" : "animate-pulse-dot bg-cream"}`} />
      {failing ? "Reconnecting" : "Live"}
    </span>
  );
}
