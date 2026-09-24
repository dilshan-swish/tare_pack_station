import type { ApiLine, ApiOrder } from "../../shared/types.ts";

export type { ApiLine, ApiModifier, ApiOrder, ErrorResponse, OrdersResponse } from "../../shared/types.ts";

export interface Branch {
  id: string;
  brand_code: string;
  code: string;
  name: string;
  email: string;
  foodics_branch_id: string;
  session_start: string | null;
  session_end: string | null;
}

export interface AppSettings {
  target_samples: number;
  min_weight_g: number;
  max_weight_g: number;
  business_day_cutoff_hour: number;
  timezone: string;
  edit_window_hours: number;
  size_aliases: Record<string, string>;
  skip_categories: string[];
  skip_price_at_or_below: number;
}

export const DEFAULT_SETTINGS: AppSettings = {
  target_samples: 200,
  min_weight_g: 1,
  max_weight_g: 5000,
  business_day_cutoff_hour: 6,
  timezone: "Asia/Kuwait",
  edit_window_hours: 48,
  size_aliases: { REGULAR: "REGULAR", MEDIUM: "MEDIUM", SUUUBER: "SUUUBER", SUUUBERT: "SUUUBER", SUUUBERTM: "SUUUBER" },
  skip_categories: ["Staff Meal", "Beverages", "Dine In Drinks", "Merch", "BBT X SAY SUCO MERCH"],
  skip_price_at_or_below: 0.7,
};

export interface FocusItem {
  id: string;
  branch_id: string | null;
  product_id: string | null;
  product_name: string;
  size_label: string | null;
  priority: number;
  note: string | null;
  is_active: boolean;
}

export interface ItemProgress {
  product_id: string;
  product_name: string;
  size_label: string | null;
  samples: number;
  median_g: number | null;
  p10_g: number | null;
  p90_g: number | null;
}

/** One physical unit to weigh: a line with quantity 3 becomes 3 units. */
export interface Unit {
  key: string;
  order: ApiOrder;
  line: ApiLine;
  unitIndex: number;
  unitCount: number;
  sizeLabel: string | null;
}

export type WeighedStatus = "synced" | "pending";

export interface WeighedState {
  entryId: string;
  weight: number;
  status: WeighedStatus;
}

/** The row the app sends; branch, staff, dates and size are filled in server-side. */
export interface EntryInsert {
  id: string;
  foodics_order_id: string;
  order_number: number | null;
  order_reference: string | null;
  check_number: number | null;
  aggregator_name: string | null;
  aggregator_ref: string | null;
  order_type: number | null;
  order_status: number | null;
  order_opened_at: string | null;
  line_key: string;
  unit_index: number;
  product_id: string;
  product_name: string;
  product_sku: string | null;
  product_category: string | null;
  unit_price: number | null;
  modifiers: { id: string; name: string }[];
  weight_g: number;
  note: string | null;
  client_created_at: string;
}

export interface EntryRow {
  id: string;
  foodics_order_id: string;
  order_number: number | null;
  aggregator_name: string | null;
  aggregator_ref: string | null;
  line_key: string;
  unit_index: number;
  product_id: string;
  product_name: string;
  size_label: string | null;
  modifiers_label: string;
  weight_g: number;
  note: string | null;
  weighed_at: string;
  created_at: string;
  business_date: string;
}
