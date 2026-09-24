// GET /api/orders — the signed-in branch's live Foodics orders.
//
// Runs server-side (a Vercel function in production, a Vite dev middleware
// locally) so the Foodics token never reaches a browser. The caller proves who
// they are with their Supabase access token; the branch — and therefore which
// Foodics branch's orders come back — is looked up from that login, never
// taken from the request.
//
// Order fetching mirrors the tablet app's proven FoodicsApi/FoodicsOrderRepository:
// same status filter (1 pending, 2 active, 4 closed), same includes, the same
// browser-like User-Agent (Foodics sits behind Cloudflare, which blocks default
// client signatures), timeouts + retries, and orders open longer than 24 h are
// treated as abandoned and dropped.

import type { IncomingMessage, ServerResponse } from "node:http";
import type { ApiLine, ApiModifier, ApiOrder, ErrorResponse, OrdersResponse } from "../shared/types.ts";

export interface OrdersEnv {
  supabaseUrl: string | undefined;
  supabaseAnonKey: string | undefined;
  foodicsToken: string | undefined;
  foodicsBaseUrl: string;
}

export function envFromProcess(): OrdersEnv {
  const e = process.env;
  return {
    supabaseUrl: e.SUPABASE_URL || e.VITE_SUPABASE_URL,
    supabaseAnonKey: e.SUPABASE_ANON_KEY || e.VITE_SUPABASE_ANON_KEY,
    foodicsToken: e.FOODICS_TOKEN,
    foodicsBaseUrl: e.FOODICS_BASE_URL || "https://api.foodics.com/v5",
  };
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

type Result = { status: number; body: OrdersResponse | ErrorResponse };

const STALE_AFTER_MS = 24 * 60 * 60 * 1000;
const CACHE_TTL_MS = 8_000;
const cache = new Map<string, { at: number; orders: ApiOrder[] }>();

export async function handleOrdersRequest(authorization: string | undefined, env: OrdersEnv): Promise<Result> {
  const missing = [
    !env.supabaseUrl && "SUPABASE_URL",
    !env.supabaseAnonKey && "SUPABASE_ANON_KEY",
    !env.foodicsToken && "FOODICS_TOKEN",
  ].filter(Boolean);
  if (missing.length) {
    return fail(500, "config", `The server is missing ${missing.join(", ")}. Ask the admin to set it in Vercel.`);
  }

  const jwt = /^Bearer\s+(.+)$/i.exec(authorization ?? "")?.[1]?.trim();
  if (!jwt) return fail(401, "unauthenticated", "Please sign in again.");

  let branch: BranchRow | null;
  try {
    branch = await lookupBranch(env.supabaseUrl!, env.supabaseAnonKey!, jwt);
  } catch (e) {
    if (e instanceof AuthError) return fail(401, "unauthenticated", "Your session has expired. Please sign in again.");
    return fail(502, "foodics_unavailable", "Couldn't check your login right now. Retrying shortly.");
  }
  if (!branch) {
    return fail(403, "no_branch", "This login isn't linked to a branch. Ask the admin to link it.");
  }

  const cached = cache.get(branch.id);
  if (cached && Date.now() - cached.at < CACHE_TTL_MS) {
    return ok(branch, cached.orders);
  }

  try {
    const raw = await fetchFoodicsOrders(env, branch.foodics_branch_id);
    const orders = mapOrders(raw);
    cache.set(branch.id, { at: Date.now(), orders });
    return ok(branch, orders);
  } catch (e) {
    if (e instanceof FoodicsError && (e.status === 401 || e.status === 403)) {
      return fail(502, "foodics_auth", "Foodics rejected the connection. Tell the admin (the Foodics token needs checking).");
    }
    const msg = e instanceof FoodicsError ? e.message : "Couldn't reach Foodics.";
    return fail(502, "foodics_unavailable", `${msg} Retrying shortly.`);
  }
}

function ok(branch: BranchRow, orders: ApiOrder[]): Result {
  return {
    status: 200,
    body: {
      branch: { id: branch.id, code: branch.code, name: branch.name },
      fetchedAt: new Date().toISOString(),
      orders,
    },
  };
}

function fail(status: number, code: ErrorResponse["code"], error: string): Result {
  return { status, body: { error, code } };
}

// ---------------------------------------------------------------------------
// Supabase: who is calling?
// ---------------------------------------------------------------------------

interface BranchRow {
  id: string;
  code: string;
  name: string;
  foodics_branch_id: string;
}

class AuthError extends Error {}

async function lookupBranch(supabaseUrl: string, anonKey: string, jwt: string): Promise<BranchRow | null> {
  const res = await fetchWithTimeout(`${supabaseUrl.replace(/\/+$/, "")}/rest/v1/rpc/my_branch`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${jwt}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: "{}",
  }, 8_000);
  if (res.status === 401 || res.status === 403) throw new AuthError("unauthorized");
  if (!res.ok) throw new Error(`Supabase returned ${res.status}`);
  const rows = (await res.json()) as unknown;
  if (!Array.isArray(rows) || rows.length === 0) return null;
  const r = rows[0] as Partial<BranchRow>;
  if (!r.id || !r.foodics_branch_id) return null;
  return { id: r.id, code: r.code ?? "", name: r.name ?? "", foodics_branch_id: r.foodics_branch_id };
}

// ---------------------------------------------------------------------------
// Foodics
// ---------------------------------------------------------------------------

class FoodicsError extends Error {
  status: number | undefined;
  constructor(message: string, status?: number) {
    super(message);
    this.status = status;
  }
}

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36 TARE-WeighApp";

export async function fetchFoodicsOrders(env: OrdersEnv, foodicsBranchId: string): Promise<unknown[]> {
  // Foodics needs the filter[...] brackets and comma lists left literal —
  // percent-encoding them returns HTTP 400. Only the branch id is encoded.
  const query =
    `filter[branch_id]=${encodeURIComponent(foodicsBranchId)}` +
    "&filter[status]=1,2,4" +
    "&include=products,products.product,products.product.category,products.options.modifier_option,customer" +
    "&sort=-created_at&per_page=50";
  const url = `${env.foodicsBaseUrl.replace(/\/+$/, "")}/orders?${query}`;

  let lastError: FoodicsError = new FoodicsError("Couldn't reach Foodics.");
  for (let attempt = 0; attempt <= 2; attempt++) {
    try {
      const res = await fetchWithTimeout(url, {
        headers: {
          Authorization: `Bearer ${env.foodicsToken}`,
          Accept: "application/json",
          "User-Agent": USER_AGENT,
        },
      }, 12_000);
      if (res.ok) {
        const body = (await res.json()) as { data?: unknown };
        return Array.isArray(body.data) ? body.data : [];
      }
      if (res.status === 401 || res.status === 403 || res.status === 422) {
        throw new FoodicsError(`Foodics rejected the request (${res.status}).`, res.status);
      }
      lastError = new FoodicsError(
        res.status === 429 ? "Foodics is rate-limiting requests." : `Foodics returned HTTP ${res.status}.`,
        res.status,
      );
    } catch (e) {
      if (e instanceof FoodicsError && e.status && [401, 403, 422].includes(e.status)) throw e;
      if (!(e instanceof FoodicsError)) {
        lastError = new FoodicsError(
          e instanceof Error && e.name === "AbortError" ? "Foodics took too long to respond." : "Couldn't reach Foodics.",
        );
      }
    }
    if (attempt < 2) await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
  }
  throw lastError;
}

async function fetchWithTimeout(url: string, init: RequestInit, ms: number): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { ...init, signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Mapping (every step defensive: one odd order never blanks the list)
// ---------------------------------------------------------------------------

type J = Record<string, unknown>;
const isObj = (v: unknown): v is J => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | null => (v === null || v === undefined ? null : String(v).trim() || null);
const int = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : null);

export function mapOrders(raw: unknown[], now: Date = new Date()): ApiOrder[] {
  const out: ApiOrder[] = [];
  for (const o of raw) {
    try {
      if (!isObj(o)) continue;
      const opened = parseFoodicsTimestamp(o.opened_at);
      if (opened && now.getTime() - opened.getTime() > STALE_AFTER_MS) continue;
      const mapped = mapOrder(o);
      if (mapped) out.push(mapped);
    } catch {
      // skip just this order
    }
  }
  return out;
}

function mapOrder(j: J): ApiOrder | null {
  const number = int(j.number);
  const reference = str(j.reference);
  const id = str(j.id) ?? reference ?? (number !== null ? String(number) : null);
  if (!id) return null;

  const type = int(j.type);
  const [aggregatorName, aggregatorRef] = parseFoodicsAggregator(j.meta);

  const lines: ApiLine[] = [];
  const products = Array.isArray(j.products) ? j.products : [];
  products.forEach((p, i) => {
    if (!isObj(p)) return;
    const product = isObj(p.product) ? p.product : null;
    const productId = str(product?.id);
    if (!productId) return;
    const qty = int(p.quantity) ?? 1;
    const category = product && isObj(product.category) ? str(product.category.name) : null;
    const price = typeof product?.price === "number" && Number.isFinite(product.price) ? product.price : null;
    lines.push({
      key: str(p.id) ?? `line-${i}`,
      productId,
      productName: str(product?.name) ?? "Unnamed item",
      sku: str(product?.sku),
      category,
      price,
      quantity: Math.min(Math.max(qty, 1), 20),
      modifiers: parseModifiers(p.options),
    });
  });

  const customer = isObj(j.customer) ? j.customer : null;
  return {
    id,
    number,
    reference,
    checkNumber: int(j.check_number),
    aggregatorName,
    aggregatorRef,
    type,
    status: int(j.status),
    openedAt: parseFoodicsTimestamp(j.opened_at)?.toISOString() ?? null,
    receivedAt: parseReceivedAt(j)?.toISOString() ?? null,
    customerLabel: aggregatorName ? null : displayName(str(customer?.name), type),
    lines,
  };
}

function parseModifiers(options: unknown): ApiModifier[] {
  if (!Array.isArray(options)) return [];
  const out: ApiModifier[] = [];
  for (const o of options) {
    if (!isObj(o) || !isObj(o.modifier_option)) continue;
    const id = str(o.modifier_option.id);
    const name = str(o.modifier_option.name);
    if (id && name) out.push({ id, name });
  }
  return out;
}

const TYPE_LABELS: Record<number, string> = { 1: "Dine In", 2: "Pick Up", 3: "Delivery", 4: "Drive Thru" };

function displayName(name: string | null, type: number | null): string | null {
  if (name) {
    const parts = name.split(/\s+/);
    return parts.length === 1 ? parts[0] : `${parts[0]} ${parts[parts.length - 1][0].toUpperCase()}.`;
  }
  return type !== null ? (TYPE_LABELS[type] ?? null) : null;
}

/** Foodics timestamps are UTC with no zone suffix ("2026-07-05 15:16:46"). */
export function parseFoodicsTimestamp(v: unknown): Date | null {
  if (typeof v !== "string" || !v) return null;
  const d = new Date(`${v.replace(" ", "T")}Z`);
  return Number.isNaN(d.getTime()) ? null : d;
}

function parseReceivedAt(order: J): Date | null {
  const meta = isObj(order.meta) ? order.meta : null;
  const foodics = meta && isObj(meta.foodics) ? meta.foodics : null;
  return (
    parseFoodicsTimestamp(foodics?.kitchen_received_at) ??
    parseFoodicsTimestamp(foodics?.cashier_received_at) ??
    parseFoodicsTimestamp(order.opened_at)
  );
}

/**
 * The delivery aggregator and its own order number, from `meta`:
 *   "Mishmash - Talabat: 3815711802, #4887"  -> [Talabat, 4887]
 *   "Mishmash - KeeTa: 3990"                 -> [KeeTa, 3990]
 *   "Mishmash - Keeta 2.0: 4874140355579055" -> [Keeta 2.0, …9055]
 *   "SUNV-4490" / missing                    -> [null, null]
 */
export function parseFoodicsAggregator(meta: unknown): [string | null, string | null] {
  try {
    if (!isObj(meta)) return [null, null];
    let name = str(meta.external_source);
    const external = str(meta.external_number);
    let payload: string | null = null;
    if (external) {
      const colon = external.indexOf(":");
      if (colon !== -1) {
        const prefix = external.slice(0, colon).trim();
        payload = external.slice(colon + 1).trim();
        if (!name) {
          const dash = prefix.lastIndexOf(" - ");
          name = (dash !== -1 ? prefix.slice(dash + 3) : prefix).trim() || null;
        }
      } else {
        payload = external;
      }
    }
    if (!name) return [null, null];

    let ref: string | null = null;
    if (payload) {
      const hash = payload.lastIndexOf("#");
      if (hash !== -1) {
        ref = payload.slice(hash + 1).trim();
      } else {
        const tokens = payload.split(/[,\s]+/).filter(Boolean);
        ref = tokens.length ? tokens[tokens.length - 1].trim() : null;
      }
      ref = ref?.replace(/^#+/, "").trim() || null;
      if (ref && /^\d+$/.test(ref) && ref.length > 8) ref = `…${ref.slice(-4)}`;
    }
    return [name, ref];
  } catch {
    return [null, null];
  }
}

// ---------------------------------------------------------------------------
// Vercel entry point
// ---------------------------------------------------------------------------

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  let result: Result;
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    result = fail(405, "method", "Method not allowed.");
  } else {
    try {
      result = await handleOrdersRequest(req.headers.authorization, envFromProcess());
    } catch {
      result = fail(500, "foodics_unavailable", "Something went wrong loading orders. Retrying shortly.");
    }
  }
  res.statusCode = result.status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(result.body));
}
