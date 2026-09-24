import { useEffect, type ButtonHTMLAttributes, type ReactNode } from "react";
import { createPortal } from "react-dom";

type Variant = "ink" | "cream" | "green" | "danger" | "ghost";

export function Button({
  variant = "ink",
  size = "md",
  className = "",
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: "md" | "lg" | "sm" }) {
  const sizes = { sm: "min-h-[44px] px-4 text-sm", md: "min-h-[52px] px-5 text-base", lg: "min-h-[60px] px-6 text-lg" };
  const variants: Record<Variant, string> = {
    ink: "bg-ink text-cream border-[2.5px] border-ink shadow-[4px_4px_0_rgb(22_27_20/0.35)]",
    cream: "bg-cream text-ink border-[2.5px] border-ink shadow-[4px_4px_0_rgb(22_27_20/0.9)]",
    green: "bg-green text-white border-[2.5px] border-ink shadow-[4px_4px_0_rgb(22_27_20/0.9)]",
    danger: "bg-underbg text-undertext border-[2.5px] border-ink shadow-[4px_4px_0_rgb(22_27_20/0.9)]",
    ghost: "bg-transparent text-ink border-[2.5px] border-transparent",
  };
  return (
    <button
      type="button"
      className={`press inline-flex select-none items-center justify-center gap-2 rounded-full font-bold disabled:cursor-not-allowed disabled:opacity-45 ${sizes[size]} ${variants[variant]} ${className}`}
      {...rest}
    >
      {children}
    </button>
  );
}

export function Pill({
  tone = "ink",
  children,
  className = "",
}: {
  tone?: "ink" | "ok" | "amber" | "under" | "cream" | "muted";
  children: ReactNode;
  className?: string;
}) {
  const tones = {
    ink: "bg-ink text-cream border-ink",
    ok: "bg-okbg text-oktext border-oktext/40",
    amber: "bg-amber text-ink border-ink",
    under: "bg-underbg text-undertext border-undertext/40",
    cream: "bg-cream text-ink border-ink",
    muted: "bg-black/5 text-muted border-transparent",
  } as const;
  return (
    <span
      className={`inline-flex items-center gap-1 whitespace-nowrap rounded-full border-2 px-2.5 py-0.5 text-xs font-bold ${tones[tone]} ${className}`}
    >
      {children}
    </span>
  );
}

export function Spinner({ className = "" }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={`inline-block h-5 w-5 animate-spin-slow rounded-full border-[3px] border-current/25 border-t-current ${className}`}
    />
  );
}

export function FullScreenMessage({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="flex min-h-dvh items-center justify-center p-5">
      <div className="neo w-full max-w-md p-6 text-center">
        <h1 className="font-display text-2xl text-ink">{title}</h1>
        {children && <div className="mt-3 space-y-4 text-muted">{children}</div>}
      </div>
    </div>
  );
}

/** A bottom sheet on phones, a centred dialog on larger screens. */
export function Sheet({
  open,
  onClose,
  title,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
}) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onClose]);
  if (!open) return null;
  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-ink/50 sm:items-center sm:p-6"
      role="dialog"
      aria-modal="true"
      aria-label={title}
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="animate-rise neo max-h-[92dvh] w-full max-w-lg overflow-y-auto rounded-b-none p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] sm:rounded-b-[20px]">
        <h2 className="mb-3 font-display text-xl text-ink">{title}</h2>
        {children}
      </div>
    </div>,
    document.body,
  );
}
