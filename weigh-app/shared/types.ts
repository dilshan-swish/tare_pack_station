// Shapes returned by GET /api/orders — imported (type-only) by both the
// server function and the browser app so they can't drift apart.

export interface ApiModifier {
  id: string;
  name: string;
}

export interface ApiLine {
  /** Stable per order: Foodics' own order-product id when present. */
  key: string;
  productId: string;
  productName: string;
  sku: string | null;
  /** Foodics menu category name, e.g. "ONE STOP MEAL", "Staff Meal". */
  category: string | null;
  /** Product list price in KD. Meal combos are 0 — their price sits on the size option. */
  price: number | null;
  quantity: number;
  modifiers: ApiModifier[];
}

export interface ApiOrder {
  id: string;
  number: number | null;
  reference: string | null;
  checkNumber: number | null;
  aggregatorName: string | null;
  aggregatorRef: string | null;
  /** Foodics order type: 1 Dine In, 2 Pick Up, 3 Delivery, 4 Drive Thru. */
  type: number | null;
  /** Foodics status: 1 Pending, 2 Active (preparing), 4 Closed (ready). */
  status: number | null;
  openedAt: string | null;
  receivedAt: string | null;
  customerLabel: string | null;
  lines: ApiLine[];
}

export interface ApiBranch {
  id: string;
  code: string;
  name: string;
}

export interface OrdersResponse {
  branch: ApiBranch;
  fetchedAt: string;
  orders: ApiOrder[];
}

export type ApiErrorCode =
  | "config"
  | "unauthenticated"
  | "no_branch"
  | "foodics_auth"
  | "foodics_unavailable"
  | "method";

export interface ErrorResponse {
  error: string;
  code: ApiErrorCode;
}

export interface LoginResponse {
  access_token: string;
  refresh_token: string;
  branch: ApiBranch;
}

export type LoginErrorCode =
  | "config"
  | "invalid_email"
  | "unknown_email"
  | "inactive"
  | "rate_limited"
  | "unavailable"
  | "method";
