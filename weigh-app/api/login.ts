// POST /api/login  { email }  →  { access_token, refresh_token, branch }
//
// Email-only sign-in for branch devices: if the email belongs to an active
// branch, the server signs that branch in — no password, nothing to open in an
// inbox. It issues a normal Supabase session (auto-creating the branch's auth
// user on first use), so every row-level-security rule keeps applying exactly
// as before. The service-role key needed for that stays here, server-side.

import type { IncomingMessage, ServerResponse } from "node:http";
import { createClient } from "@supabase/supabase-js";
import type { LoginErrorCode, LoginResponse } from "../shared/types.ts";

interface LoginEnv {
  supabaseUrl: string | undefined;
  anonKey: string | undefined;
  serviceKey: string | undefined;
}

export function loginEnvFromProcess(): LoginEnv {
  const e = process.env;
  return {
    supabaseUrl: e.SUPABASE_URL || e.VITE_SUPABASE_URL,
    anonKey: e.SUPABASE_ANON_KEY || e.VITE_SUPABASE_ANON_KEY,
    serviceKey: e.SUPABASE_SERVICE_ROLE_KEY,
  };
}

type Result = { status: number; body: LoginResponse | { error: string; code: LoginErrorCode } };

const fail = (status: number, code: LoginErrorCode, error: string): Result => ({ status, body: { error, code } });

// Slows down anyone trying emails one after another. Per server instance —
// a speed bump, not a vault.
const WINDOW_MS = 10 * 60_000;
const MAX_ATTEMPTS = 20;
const attempts = new Map<string, { count: number; resetAt: number }>();

function rateLimited(key: string): boolean {
  const now = Date.now();
  const a = attempts.get(key);
  if (!a || a.resetAt < now) {
    attempts.set(key, { count: 1, resetAt: now + WINDOW_MS });
    if (attempts.size > 5000) for (const [k, v] of attempts) if (v.resetAt < now) attempts.delete(k);
    return false;
  }
  a.count++;
  return a.count > MAX_ATTEMPTS;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function handleLoginRequest(rawEmail: unknown, clientKey: string, env: LoginEnv): Promise<Result> {
  const missing = [!env.supabaseUrl && "SUPABASE_URL", !env.anonKey && "SUPABASE_ANON_KEY", !env.serviceKey && "SUPABASE_SERVICE_ROLE_KEY"].filter(Boolean);
  if (missing.length) return fail(500, "config", `Sign-in isn't set up yet (missing ${missing.join(", ")}). Tell the admin.`);

  const email = typeof rawEmail === "string" ? rawEmail.trim().toLowerCase() : "";
  if (!EMAIL_RE.test(email) || email.length > 254) return fail(400, "invalid_email", "Enter a valid email, e.g. bbtbayan@swishhh.net");
  if (rateLimited(clientKey)) return fail(429, "rate_limited", "Too many attempts. Wait a few minutes and try again.");

  const opts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
  const admin = createClient(env.supabaseUrl!, env.serviceKey!, opts);

  const { data: branch, error: bErr } = await admin
    .from("branches")
    .select("id, code, name, is_active")
    .eq("email", email)
    .maybeSingle();
  if (bErr) return fail(502, "unavailable", "Couldn't reach the database. Try again in a moment.");
  if (!branch) return fail(404, "unknown_email", "This email isn't registered for a branch. Check the spelling or ask the admin.");
  if (!branch.is_active) return fail(403, "inactive", "This branch is switched off for weighing. Ask the admin.");

  // First sign-in for this branch: create its auth user (already-exists is fine).
  const { error: cErr } = await admin.auth.admin.createUser({ email, email_confirm: true });
  if (cErr && !/already|exists|registered/i.test(`${cErr.code ?? ""} ${cErr.message}`)) {
    return fail(502, "unavailable", "Couldn't prepare the sign-in. Try again in a moment.");
  }

  const { data: link, error: lErr } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link?.properties?.hashed_token;
  if (lErr || !tokenHash) return fail(502, "unavailable", "Couldn't start the sign-in. Try again in a moment.");

  const anon = createClient(env.supabaseUrl!, env.anonKey!, opts);
  const { data: verified, error: vErr } = await anon.auth.verifyOtp({ token_hash: tokenHash, type: "magiclink" });
  const session = verified?.session;
  if (vErr || !session) return fail(502, "unavailable", "Couldn't finish the sign-in. Try again in a moment.");

  return {
    status: 200,
    body: {
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      branch: { id: branch.id, code: branch.code, name: branch.name },
    },
  };
}

async function readJsonBody(req: IncomingMessage & { body?: unknown }): Promise<Record<string, unknown>> {
  // Vercel parses JSON bodies itself; the local dev server hands over the raw stream.
  if (req.body !== undefined) {
    if (typeof req.body === "string") return JSON.parse(req.body || "{}");
    return (req.body ?? {}) as Record<string, unknown>;
  }
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 4096) throw new Error("too large");
  }
  return raw ? JSON.parse(raw) : {};
}

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  let result: Result;
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    result = fail(405, "method", "Method not allowed.");
  } else {
    try {
      const body = await readJsonBody(req);
      const ip = String(req.headers["x-forwarded-for"] ?? req.socket?.remoteAddress ?? "unknown").split(",")[0].trim();
      result = await handleLoginRequest(body.email, ip, loginEnvFromProcess());
    } catch {
      result = fail(400, "invalid_email", "Couldn't read the request. Try again.");
    }
  }
  res.statusCode = result.status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(result.body));
}
