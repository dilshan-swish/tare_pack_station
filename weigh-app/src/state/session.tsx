import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { configError, describeError, supabase } from "../lib/supabase";
import { DEFAULT_SETTINGS, type AppSettings, type Branch, type FocusItem, type ItemProgress } from "../lib/types";
import { progressKey } from "../lib/rules";

export type SessionStatus =
  | { kind: "config" ; message: string }
  | { kind: "loading" }
  | { kind: "signed_out"; notice?: string }
  | { kind: "no_branch"; message: string }
  | { kind: "error"; message: string }
  | { kind: "ready" };

interface SessionValue {
  status: SessionStatus;
  session: Session | null;
  branch: Branch | null;
  settings: AppSettings;
  focus: FocusItem[];
  progress: Map<string, ItemProgress>;
  refreshProgress: () => Promise<void>;
  bumpProgress: (productId: string, size: string | null, delta: number) => void;
  retry: () => void;
  signOut: (notice?: string) => Promise<void>;
}

const Ctx = createContext<SessionValue | null>(null);

export function useSession(): SessionValue {
  const v = useContext(Ctx);
  if (!v) throw new Error("useSession must be used inside <SessionProvider>");
  return v;
}

function toSettings(row: Record<string, unknown> | null): AppSettings {
  if (!row) return DEFAULT_SETTINGS;
  const num = (v: unknown, d: number) => (v === null || v === undefined || Number.isNaN(Number(v)) ? d : Number(v));
  return {
    target_samples: num(row.target_samples, DEFAULT_SETTINGS.target_samples),
    min_weight_g: num(row.min_weight_g, DEFAULT_SETTINGS.min_weight_g),
    max_weight_g: num(row.max_weight_g, DEFAULT_SETTINGS.max_weight_g),
    business_day_cutoff_hour: num(row.business_day_cutoff_hour, DEFAULT_SETTINGS.business_day_cutoff_hour),
    timezone: typeof row.timezone === "string" && row.timezone ? row.timezone : DEFAULT_SETTINGS.timezone,
    edit_window_hours: num(row.edit_window_hours, DEFAULT_SETTINGS.edit_window_hours),
    size_aliases:
      row.size_aliases && typeof row.size_aliases === "object" ? (row.size_aliases as Record<string, string>) : DEFAULT_SETTINGS.size_aliases,
    skip_categories: Array.isArray(row.skip_categories) ? (row.skip_categories as string[]) : DEFAULT_SETTINGS.skip_categories,
    skip_price_at_or_below: num(row.skip_price_at_or_below, DEFAULT_SETTINGS.skip_price_at_or_below),
  };
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [status, setStatus] = useState<SessionStatus>(
    configError ? { kind: "config", message: configError } : { kind: "loading" },
  );
  const [branch, setBranch] = useState<Branch | null>(null);
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [focus, setFocus] = useState<FocusItem[]>([]);
  const [progress, setProgress] = useState<Map<string, ItemProgress>>(new Map());
  const [reloadTick, setReloadTick] = useState(0);

  // Auth state: initial session + every change afterwards.
  useEffect(() => {
    if (configError) return;
    let mounted = true;
    supabase.auth
      .getSession()
      .then(({ data, error }) => {
        if (!mounted) return;
        if (error) {
          setStatus({ kind: "signed_out", notice: describeError(error) });
          return;
        }
        setSession(data.session);
        if (!data.session) setStatus({ kind: "signed_out" });
      })
      .catch((e) => mounted && setStatus({ kind: "signed_out", notice: describeError(e) }));

    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      if (!s) {
        setBranch(null);
        setStatus((prev) => (prev.kind === "signed_out" ? prev : { kind: "signed_out" }));
      }
    });
    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const loadProgress = useCallback(async () => {
    const { data, error } = await supabase.rpc("get_item_progress");
    if (error) throw error;
    const map = new Map<string, ItemProgress>();
    for (const r of (data ?? []) as ItemProgress[]) {
      map.set(progressKey(r.product_id, r.size_label), {
        ...r,
        samples: Number(r.samples),
        median_g: r.median_g === null ? null : Number(r.median_g),
        p10_g: r.p10_g === null ? null : Number(r.p10_g),
        p90_g: r.p90_g === null ? null : Number(r.p90_g),
      });
    }
    setProgress(map);
  }, []);

  // Branch + reference data whenever a (new) user is signed in.
  const userId = session?.user.id ?? null;
  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    setStatus({ kind: "loading" });
    (async () => {
      try {
        const { data: branchRows, error: bErr } = await supabase.rpc("my_branch");
        if (bErr) throw bErr;
        const b = (branchRows as Branch[] | null)?.[0] ?? null;
        if (!b) {
          const { data: admin } = await supabase.rpc("is_admin");
          if (cancelled) return;
          setStatus({
            kind: "no_branch",
            message: admin
              ? "This is an admin account. Use the portal to view the data — this app is for branch logins."
              : "This login isn't linked to a branch yet. Ask the admin to add it.",
          });
          return;
        }
        const [sRes, fRes] = await Promise.all([
          supabase.from("app_settings").select("*").maybeSingle(),
          supabase.from("focus_items").select("*").eq("is_active", true),
        ]);
        if (sRes.error) throw sRes.error;
        if (fRes.error) throw fRes.error;
        await loadProgress().catch(() => undefined); // non-critical: the app works without it
        if (cancelled) return;
        setBranch(b);
        setSettings(toSettings(sRes.data as Record<string, unknown> | null));
        setFocus((fRes.data ?? []) as FocusItem[]);
        setStatus({ kind: "ready" });
      } catch (e) {
        if (!cancelled) setStatus({ kind: "error", message: describeError(e, "Couldn't load your branch.") });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [userId, reloadTick, loadProgress]);

  // Keep progress roughly current in the background.
  useEffect(() => {
    if (status.kind !== "ready") return;
    const t = window.setInterval(() => void loadProgress().catch(() => undefined), 120_000);
    return () => window.clearInterval(t);
  }, [status.kind, loadProgress]);

  const bumpProgress = useCallback((productId: string, size: string | null, delta: number) => {
    setProgress((prev) => {
      const next = new Map(prev);
      const k = progressKey(productId, size);
      const cur = next.get(k);
      if (cur) next.set(k, { ...cur, samples: Math.max(0, cur.samples + delta) });
      else if (delta > 0)
        next.set(k, { product_id: productId, product_name: "", size_label: size, samples: delta, median_g: null, p10_g: null, p90_g: null });
      return next;
    });
  }, []);

  const signOut = useCallback(async (notice?: string) => {
    try {
      await supabase.auth.signOut();
    } catch {
      // Clearing the local session is what matters; ignore network failures.
    }
    setBranch(null);
    setSession(null);
    setStatus({ kind: "signed_out", notice });
  }, []);

  const value = useMemo<SessionValue>(
    () => ({
      status,
      session,
      branch,
      settings,
      focus,
      progress,
      refreshProgress: () => loadProgress().catch(() => undefined),
      bumpProgress,
      retry: () => setReloadTick((t) => t + 1),
      signOut,
    }),
    [status, session, branch, settings, focus, progress, loadProgress, bumpProgress, signOut],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
