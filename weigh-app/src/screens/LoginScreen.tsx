import { useState } from "react";
import { LogIn } from "lucide-react";
import { describeError, supabase } from "../lib/supabase";
import type { LoginErrorCode, LoginResponse } from "../../shared/types.ts";
import { Button, Spinner } from "../components/ui";

const LAST_EMAIL_KEY = "tare.lastEmail";

function lastEmail(): string {
  try {
    return localStorage.getItem(LAST_EMAIL_KEY) ?? "";
  } catch {
    return "";
  }
}

export function LoginScreen({ notice }: { notice?: string }) {
  const [email, setEmail] = useState(lastEmail);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const signIn = async () => {
    const clean = email.trim().toLowerCase();
    setError(null);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(clean)) return setError("Enter the branch email, e.g. bbtbayan@swishhh.net");
    setBusy(true);
    const ctrl = new AbortController();
    const timer = window.setTimeout(() => ctrl.abort(), 20_000);
    try {
      const res = await fetch("/api/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: clean }),
        signal: ctrl.signal,
      });
      const body = (await res.json().catch(() => null)) as (LoginResponse & { error?: string; code?: LoginErrorCode }) | null;
      if (!res.ok || !body?.access_token) {
        setError(body?.error ?? `Couldn't sign in (HTTP ${res.status}). Try again.`);
        return;
      }
      try {
        localStorage.setItem(LAST_EMAIL_KEY, clean);
      } catch {
        // not essential
      }
      const { error: sErr } = await supabase.auth.setSession({
        access_token: body.access_token,
        refresh_token: body.refresh_token,
      });
      if (sErr) setError(describeError(sErr, "Couldn't sign in. Try again."));
    } catch (e) {
      setError(
        (e as Error)?.name === "AbortError"
          ? "Signing in is taking too long. Check the internet and try again."
          : describeError(e, "Couldn't sign in. Try again."),
      );
    } finally {
      window.clearTimeout(timer);
      setBusy(false);
    }
  };

  return (
    <div className="flex min-h-dvh items-center justify-center p-5">
      <div className="w-full max-w-md">
        <div className="mb-6 text-center">
          <div className="font-display text-5xl tracking-tight text-cream">TARE.</div>
          <div className="mt-1 text-sm font-bold uppercase tracking-[0.18em] text-cream/85">Item weighing · BBT</div>
        </div>
        <form
          className="neo p-6"
          noValidate
          onSubmit={(e) => {
            e.preventDefault();
            if (!busy) void signIn();
          }}
        >
          <h1 className="font-display text-2xl">Branch sign in</h1>
          <p className="mt-1 text-sm text-muted">Enter your branch email to open today's orders.</p>
          {notice && <p className="mt-3 rounded-xl bg-amber/30 px-3 py-2 text-sm font-semibold text-ink">{notice}</p>}

          <label className="mt-5 block">
            <span className="mb-1.5 block text-sm font-bold">Branch email</span>
            <input
              type="email"
              value={email}
              onChange={(e) => {
                setEmail(e.target.value);
                if (error) setError(null);
              }}
              autoComplete="email"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              inputMode="email"
              enterKeyHint="go"
              placeholder="bbtbayan@swishhh.net"
              aria-invalid={!!error}
              className="h-14 w-full rounded-2xl border-[2.5px] border-ink bg-white px-4 text-base font-semibold outline-none focus:shadow-[0_0_0_4px_rgb(243_169_59/0.6)]"
            />
          </label>

          {error && (
            <p role="alert" className="mt-4 rounded-xl bg-underbg px-3 py-2 text-sm font-bold text-undertext">
              {error}
            </p>
          )}

          <Button type="submit" size="lg" className="mt-6 w-full" disabled={busy}>
            {busy ? <Spinner /> : <LogIn size={20} />} {busy ? "Signing in…" : "Sign in"}
          </Button>
        </form>
      </div>
    </div>
  );
}
