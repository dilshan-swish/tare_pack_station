import { useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { Link, Outlet, useLocation } from "react-router-dom";
import {
  MessageCircle,
  History,
  FileText,
  Bell,
  Database,
  Settings as SettingsIcon,
  ChevronsLeft,
  ChevronsRight,
  BarChart3,
} from "lucide-react";
import { DateRangeFilter, resolvePresetRange, type RangePresetKey } from "../ui";
import { loadSettings, saveSettings } from "../analyticsStorage";

const SECTIONS = [
  { to: "/analytics", label: "Ask", subtitle: "Ask AI", icon: MessageCircle },
  { to: "/analytics/history", label: "History", subtitle: "Your past questions", icon: History },
  { to: "/analytics/reports", label: "Reports", subtitle: "Saved insights", icon: FileText },
  { to: "/analytics/alerts", label: "Alerts", subtitle: "Thresholds & notifications", icon: Bell },
  { to: "/analytics/data", label: "Data", subtitle: "Sources & quality", icon: Database },
  { to: "/analytics/settings", label: "Settings", subtitle: "Preferences", icon: SettingsIcon },
];

// The date range picked here is shared context for every section that cares
// about it (Ask, Data) via useOutletContext — History/Reports/Alerts/Settings
// simply don't read it, so it's harmless for them to ignore.
export interface AnalyticsRangeContext {
  from?: string;
  to?: string;
}

export function AnalyticsLayout() {
  const loc = useLocation();
  const initialSettings = useMemo(() => loadSettings(), []);
  const [collapsed, setCollapsed] = useState(initialSettings.sidebarCollapsed);
  const [rangePreset, setRangePreset] = useState<RangePresetKey>(initialSettings.defaultRangePreset);
  const [customFrom, setCustomFrom] = useState("");
  const [customTo, setCustomTo] = useState("");

  const { from, to } = useMemo(() => {
    if (rangePreset === "custom") {
      return {
        from: customFrom ? new Date(`${customFrom}T00:00:00`).toISOString() : undefined,
        to: customTo ? new Date(`${customTo}T23:59:59.999`).toISOString() : undefined,
      };
    }
    return resolvePresetRange(rangePreset);
  }, [rangePreset, customFrom, customTo]);

  function toggleCollapsed() {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        saveSettings({ ...loadSettings(), sidebarCollapsed: next });
      } catch {
        /* preference persistence is best-effort — collapsing still works this session */
      }
      return next;
    });
  }

  return (
    <div className="animate-fade-up">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex items-start gap-2.5">
          <span className="mt-0.5 flex h-9 w-9 flex-none items-center justify-center rounded-xl bg-green/10 text-green">
            <BarChart3 size={19} />
          </span>
          <div>
            <h1 className="font-display text-2xl text-ink">Analytics</h1>
            <p className="mt-0.5 max-w-md text-sm text-muted">
              Ask questions about your weighing data. Insights are computed from live events.
            </p>
          </div>
        </div>
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
      </div>

      <div className="mt-5 flex gap-5">
        <aside className={`hidden flex-none md:block ${collapsed ? "w-14" : "w-56"} transition-[width] duration-200`}>
          <nav className="space-y-1 rounded-2xl border border-line bg-white p-2">
            {SECTIONS.map((s) => {
              const active = loc.pathname === s.to;
              const Icon = s.icon;
              return (
                <Link
                  key={s.to}
                  to={s.to}
                  title={collapsed ? s.label : undefined}
                  className={`flex items-center gap-2.5 rounded-xl px-2.5 py-2 text-sm transition-colors ${
                    active ? "bg-green/10 text-green" : "text-ink hover:bg-black/[0.04]"
                  }`}
                >
                  <Icon size={18} strokeWidth={2} className="flex-none" />
                  {!collapsed && (
                    <span className="min-w-0">
                      <span className="block truncate font-semibold leading-tight">{s.label}</span>
                      <span className="block truncate text-xs leading-tight text-muted">{s.subtitle}</span>
                    </span>
                  )}
                </Link>
              );
            })}
          </nav>
          <button
            type="button"
            onClick={toggleCollapsed}
            className="mt-2 flex w-full items-center gap-2 rounded-xl px-2.5 py-2 text-sm text-muted transition-colors hover:bg-black/[0.04] hover:text-ink"
          >
            {collapsed ? <ChevronsRight size={18} /> : <ChevronsLeft size={18} />}
            {!collapsed && "Collapse"}
          </button>
        </aside>

        {/* pb-24 clears the fixed mobile tab bar below so it never covers the
            last bit of content; md:pb-0 since the bar itself is md:hidden. */}
        <div className="min-w-0 flex-1 pb-24 md:pb-0">
          <div key={loc.pathname} className="animate-slide-up-fade">
            <Outlet context={{ from, to } satisfies AnalyticsRangeContext} />
          </div>
        </div>
      </div>

      <MobileTabBar sections={SECTIONS} activePath={loc.pathname} />
    </div>
  );
}

// A fixed, app-native bottom tab bar for phones — replaces the sidebar
// entirely below md, rather than squeezing it into a horizontal scroller
// that clips mid-label with no visible affordance that there's more to
// scroll to. The active tab gets a sliding pill indicator (not just a color
// swap) so switching sections reads as motion, not a hard cut.
function MobileTabBar({
  sections,
  activePath,
}: {
  sections: typeof SECTIONS;
  activePath: string;
}) {
  const activeIndex = Math.max(
    0,
    sections.findIndex((s) => s.to === activePath),
  );
  const width = 100 / sections.length;

  // Portaled straight onto <body> — NOT nested where it's declared. A
  // `position: fixed` element is normally pinned to the viewport, but any
  // ANCESTOR running a transform-based entrance animation (this layout's own
  // fade-up, or the per-section slide-up-fade) creates its own containing
  // block for the duration it's mounted, which silently reparents "fixed"
  // positioning to that ancestor instead of the viewport — exactly the same
  // failure mode Modal (ui.tsx) already documents and solves this same way.
  return createPortal(
    <nav
      className="fixed inset-x-0 bottom-0 z-30 border-t border-line bg-white/95 backdrop-blur md:hidden"
      style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
      aria-label="Analytics sections"
    >
      <div className="relative grid" style={{ gridTemplateColumns: `repeat(${sections.length}, 1fr)` }}>
        <span
          className="pointer-events-none absolute inset-y-1.5 left-0 rounded-xl bg-green/10 transition-transform duration-300 ease-out"
          style={{ width: `${width}%`, transform: `translateX(${activeIndex * 100}%)` }}
        />
        {sections.map((s) => {
          const active = s.to === activePath;
          const Icon = s.icon;
          return (
            <Link
              key={s.to}
              to={s.to}
              className="relative z-10 flex flex-col items-center gap-0.5 py-2 transition-transform duration-150 active:scale-90"
            >
              <Icon size={19} strokeWidth={2} className={active ? "text-green" : "text-muted"} />
              <span className={`text-[10px] font-semibold leading-none ${active ? "text-green" : "text-muted"}`}>
                {s.label}
              </span>
            </Link>
          );
        })}
      </div>
    </nav>,
    document.body,
  );
}
