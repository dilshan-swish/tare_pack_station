import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Link, useLocation } from "react-router-dom";
import { Menu, X } from "lucide-react";
import { Button } from "./ui";

function NavLink({
  to,
  active,
  children,
}: {
  to: string;
  active: boolean;
  children: ReactNode;
}) {
  return (
    <Link
      to={to}
      className={`rounded-full px-3.5 py-1.5 text-sm font-semibold transition-all duration-200 ${
        active
          ? "bg-green text-white card-shadow"
          : "text-muted hover:-translate-y-px hover:bg-black/[0.04] hover:text-ink"
      }`}
    >
      {children}
    </Link>
  );
}

interface NavItem {
  to: string;
  label: string;
  active: boolean;
}

// The four top-level destinations, shared by the desktop nav row and the
// mobile drawer so they can never drift out of sync with each other.
function useNavItems(): NavItem[] {
  const loc = useLocation();
  const isBrands = loc.pathname === "/" || loc.pathname.startsWith("/brands");
  return [
    { to: "/", label: "Brands", active: isBrands },
    { to: "/tablets", label: "Smart Scales", active: loc.pathname === "/tablets" },
    { to: "/dashboard", label: "Dashboard", active: loc.pathname === "/dashboard" },
    { to: "/analytics", label: "Analytics", active: loc.pathname.startsWith("/analytics") },
    { to: "/training-data", label: "Training Data", active: loc.pathname === "/training-data" },
  ];
}

// A real off-canvas drawer for phones — not just the same nav row squeezed
// into a narrower box. Below `md` there isn't room for four nav pills plus
// the logo plus a Connection button on one line without an ungainly wrap
// (a pill per line, "Connection" stranded on its own row); a drawer keeps
// the header to just the logo and one tap target, and gives every
// destination a full-width, easy-to-hit row instead.
function MobileNavDrawer({
  open,
  items,
  onClose,
  onConnection,
}: {
  open: boolean;
  items: NavItem[];
  onClose: () => void;
  onConnection: () => void;
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

  // Portaled straight onto <body>, same reasoning as Modal in ui.tsx: a
  // `position: fixed` panel nested under an ancestor that runs its own
  // transform (a hover-lift card, a page-transition animation) gets trapped
  // inside that ancestor's bounds instead of the real viewport.
  return createPortal(
    <div className="fixed inset-0 z-50 md:hidden" role="dialog" aria-modal="true" aria-label="Navigation">
      <div className="animate-fade-up absolute inset-0 bg-ink/40" onClick={onClose} />
      <div className="animate-slide-in-right absolute inset-y-0 right-0 flex w-full max-w-[19rem] flex-col bg-white p-4 card-shadow-hover">
        <div className="mb-2 flex items-center justify-between">
          <span className="font-display text-sm text-ink">Menu</span>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close menu"
            className="flex h-10 w-10 items-center justify-center rounded-full text-muted transition hover:bg-black/[0.05] hover:text-ink"
          >
            <X size={19} />
          </button>
        </div>
        <nav className="flex flex-col gap-1">
          {items.map((item) => (
            <Link
              key={item.to}
              to={item.to}
              onClick={onClose}
              className={`min-h-[44px] rounded-xl px-4 py-3 text-sm font-semibold transition-colors ${
                item.active ? "bg-green text-white" : "text-ink hover:bg-black/[0.04]"
              }`}
            >
              {item.label}
            </Link>
          ))}
        </nav>
        <div className="mt-auto border-t border-line pt-4">
          <Button variant="outline" className="w-full" onClick={onConnection}>
            Connection
          </Button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

export function Layout({
  children,
  onConnection,
}: {
  children: ReactNode;
  onConnection: () => void;
}) {
  const loc = useLocation();
  const items = useNavItems();
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  // A route change from tapping a drawer link already closes the drawer
  // itself (onClick={onClose} above); this also catches every OTHER way the
  // route can change while it's open — back/forward, a link elsewhere on the
  // page — so it never gets left open over the wrong screen.
  useEffect(() => {
    setMobileNavOpen(false);
  }, [loc.pathname]);

  return (
    <div className="min-h-full">
      <header className="sticky top-0 z-20 border-b border-line bg-white/85 backdrop-blur">
        <div className="flex w-full items-center gap-3 px-4 py-3 sm:px-6 lg:px-10">
          <Link
            to="/"
            className="flex items-center gap-2 transition-transform duration-200 hover:scale-[1.03]"
            aria-label="Home"
            title="Home"
          >
            <img src="/Swish Logo.png" alt="SWiSH" className="h-8 w-auto" />
            <span className="rounded-full bg-amber/20 px-2 py-0.5 text-xs font-bold text-[#8a5a10]">
              Weighing
            </span>
          </Link>

          <nav className="ml-2 hidden min-w-0 flex-wrap gap-1 md:flex">
            {items.map((item) => (
              <NavLink key={item.to} to={item.to} active={item.active}>
                {item.label}
              </NavLink>
            ))}
          </nav>
          <div className="ml-auto hidden md:block">
            <Button variant="ghost" onClick={onConnection}>
              Connection
            </Button>
          </div>

          <button
            type="button"
            onClick={() => setMobileNavOpen(true)}
            aria-label="Open menu"
            aria-expanded={mobileNavOpen}
            className="ml-auto flex h-11 w-11 flex-none items-center justify-center rounded-full text-ink transition hover:bg-black/[0.04] md:hidden"
          >
            <Menu size={22} />
          </button>
        </div>
      </header>

      <MobileNavDrawer
        open={mobileNavOpen}
        items={items}
        onClose={() => setMobileNavOpen(false)}
        onConnection={() => {
          setMobileNavOpen(false);
          onConnection();
        }}
      />

      <main className="w-full px-4 py-8 sm:px-6 lg:px-10">{children}</main>
    </div>
  );
}
