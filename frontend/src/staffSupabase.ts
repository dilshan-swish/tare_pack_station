// The staff-weighing data lives in Supabase (written by the branch weigh app).
// The portal reaches it through its own .NET API (StaffWeighingController),
// which it's already connected to — so there's no separate login, and the
// Supabase service-role key stays on the server. supabase-js is only used as a
// query builder here: its REST calls go to {api}/api/staff-weighing/rest/v1/…

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getConfig } from "./api";

let client: SupabaseClient | null = null;
let clientFor = "";

export function sb(): SupabaseClient {
  const cfg = getConfig();
  if (!cfg) throw new Error("The portal isn't connected to the API.");
  const base = `${cfg.baseUrl.replace(/\/+$/, "")}/api/staff-weighing`;
  const fingerprint = `${base}|${cfg.apiKey}`;
  if (!client || clientFor !== fingerprint) {
    client = createClient(base, "via-portal-api", {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { headers: { "X-Api-Key": cfg.apiKey } },
    });
    clientFor = fingerprint;
  }
  return client;
}

export function describeSbError(e: unknown, fallback = "Something went wrong."): string {
  const msg = (e as { message?: string } | null)?.message ?? (typeof e === "string" ? e : "");
  if (/failed to fetch|networkerror|load failed/i.test(msg)) return "Can't reach the API — is it running?";
  return msg || fallback;
}

// --- rows ---------------------------------------------------------------------

export interface StaffBranch {
  id: string;
  brand_code: string;
  code: string;
  name: string;
  email: string;
  foodics_branch_id: string;
  session_start: string | null;
  session_end: string | null;
  is_active: boolean;
}

export interface StaffEntry {
  id: string;
  branch_id: string;
  business_date: string;
  weighed_at: string;
  foodics_order_id: string;
  order_number: number | null;
  check_number: number | null;
  aggregator_name: string | null;
  aggregator_ref: string | null;
  line_key: string;
  unit_index: number;
  product_id: string;
  product_name: string;
  product_sku: string | null;
  product_category: string | null;
  size_label: string | null;
  modifiers_label: string;
  weight_g: number;
  is_excluded: boolean;
  exclude_reason: string | null;
  entered_email: string | null;
  note: string | null;
}

export const ENTRY_COLUMNS =
  "id, branch_id, business_date, weighed_at, foodics_order_id, order_number, check_number, aggregator_name, aggregator_ref, line_key, unit_index, product_id, product_name, product_sku, product_category, size_label, modifiers_label, weight_g, is_excluded, exclude_reason, entered_email, note";

export interface StaffSettings {
  target_samples: number;
  min_weight_g: number;
  max_weight_g: number;
  business_day_cutoff_hour: number;
  timezone: string;
  edit_window_hours: number;
  skip_categories: string[];
  skip_price_at_or_below: number;
}

export interface StaffFocusItem {
  id: string;
  branch_id: string | null;
  product_id: string | null;
  product_name: string;
  size_label: string | null;
  priority: number;
  note: string | null;
  is_active: boolean;
}

/** Loads every entry weighed in [from, to] (inclusive, ISO), in pages; stops at `cap`. */
export async function loadEntries(
  range: { from?: string; to?: string },
  cap: number,
  onProgress?: (n: number) => void,
): Promise<{ rows: StaffEntry[]; truncated: boolean }> {
  const PAGE = 1000;
  const rows: StaffEntry[] = [];
  for (let offset = 0; offset < cap; offset += PAGE) {
    let q = sb()
      .from("weigh_entries")
      .select(ENTRY_COLUMNS)
      .order("weighed_at", { ascending: false })
      .order("id", { ascending: true })
      .range(offset, Math.min(offset + PAGE, cap) - 1);
    if (range.from) q = q.gte("weighed_at", range.from);
    if (range.to) q = q.lte("weighed_at", range.to);
    const { data, error } = await q;
    if (error) throw error;
    for (const r of data ?? []) rows.push({ ...(r as StaffEntry), weight_g: Number((r as StaffEntry).weight_g) });
    onProgress?.(rows.length);
    if (!data || data.length < PAGE) return { rows, truncated: false };
  }
  return { rows, truncated: true };
}
