import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

/** Set when the deployment is missing its Supabase settings. */
export const configError: string | null =
  !url || !anonKey ? "This app isn't configured yet (Supabase URL/key missing). Tell the admin." : null;

export const AUTH_STORAGE_KEY = "tare-weigh-auth";

export const supabase = createClient(url ?? "http://localhost.invalid", anonKey ?? "missing-key", {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: AUTH_STORAGE_KEY,
  },
});

/** A readable message for anything supabase-js / fetch can throw at us. */
export function describeError(e: unknown, fallback = "Something went wrong."): string {
  if (!e) return fallback;
  if (typeof e === "string") return e;
  const msg = (e as { message?: string }).message ?? "";
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(msg)) {
    return "No connection to the server. Check the internet and try again.";
  }
  if (/invalid login credentials/i.test(msg)) return "Wrong email or password.";
  if (/email not confirmed/i.test(msg)) return "This login hasn't been activated yet. Tell the admin.";
  if (/jwt|token.*expired|session/i.test(msg)) return "Your session expired. Please sign in again.";
  return msg || fallback;
}

/** True for failures worth retrying later (offline, timeouts, server hiccups). */
export function isTransient(e: unknown): boolean {
  const err = e as { message?: string; code?: string; status?: number } | null;
  if (!err) return false;
  if (typeof err.status === "number" && (err.status >= 500 || err.status === 408 || err.status === 429)) return true;
  const code = err.code ?? "";
  // Postgres data/constraint/permission errors will never succeed on retry.
  if (/^(22|23|42|P0)/.test(code)) return false;
  if (code.startsWith("PGRST3")) return true; // JWT problems — retried after a token refresh
  return /failed to fetch|networkerror|load failed|network request failed|timeout|aborted/i.test(err.message ?? "") || !code;
}
