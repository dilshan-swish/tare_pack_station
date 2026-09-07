import type {
  BrandSummary,
  MenuItem,
  Modifier,
  ItemModifierGroup,
  SyncResult,
  WeighSummary,
  Branch,
  Device,
  DeviceCreated,
  DeviceDetail,
  DeviceEventLogEntry,
  BranchSyncResult,
  WeighEventEntry,
  ModelMeta,
  AnalyticsResult,
  DataQualitySummary,
  ModifierCombination,
  MenuImportResult,
  TrainingPreviewResult,
} from "./types";

// --- Connection config (base URL + API key), kept in localStorage ---

export interface ApiConfig {
  baseUrl: string;
  apiKey: string;
}

const KEY = "swish.api.config";

export function getConfig(): ApiConfig | null {
  // A manual override (set via the Connection screen) wins.
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return JSON.parse(raw) as ApiConfig;
  } catch {
    /* fall through to env defaults */
  }
  // Otherwise auto-connect from build-time config so there's no login step.
  const envBase = import.meta.env.VITE_API_BASE as string | undefined;
  const envKey = import.meta.env.VITE_API_KEY as string | undefined;
  if (envBase && envKey) return { baseUrl: envBase, apiKey: envKey };
  return null;
}

export function setConfig(cfg: ApiConfig) {
  localStorage.setItem(KEY, JSON.stringify(cfg));
}

export function clearConfig() {
  localStorage.removeItem(KEY);
}

// --- Fetch wrapper: attaches the key, turns failures into readable errors ---

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const cfg = getConfig();
  if (!cfg) throw new ApiError("Not connected.", 0);

  let res: Response;
  try {
    res = await fetch(cfg.baseUrl.replace(/\/$/, "") + path, {
      ...init,
      headers: {
        "X-Api-Key": cfg.apiKey,
        "Content-Type": "application/json",
        ...(init?.headers ?? {}),
      },
    });
  } catch {
    throw new ApiError(
      "Can't reach the API. Is it running, and is the base URL correct?",
      0,
    );
  }

  if (res.status === 401)
    throw new ApiError("Unauthorized — check your API key.", 401);
  if (!res.ok) {
    let msg = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.error) msg = body.error;
    } catch {
      /* keep default */
    }
    throw new ApiError(msg, res.status);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

// Note: `false` is a meaningful, explicit value here (e.g. active=false means
// "inactive only", not "unset") so only undefined/""/empty-array are dropped
// — a plain boolean flag that defaults to false either way (like
// missingOnly) behaves identically whether sent as "false" or omitted. An
// array becomes a single comma-separated value, matching what the backend's
// multi-id/multi-verdict filters (e.g. brandIds, verdicts) expect.
const qs = (params: Record<string, string | number | boolean | undefined | (string | number)[]>) => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === "") continue;
    if (Array.isArray(v)) {
      if (v.length > 0) p.set(k, v.join(","));
    } else {
      p.set(k, String(v));
    }
  }
  const s = p.toString();
  return s ? `?${s}` : "";
};

export const api = {
  brands: () => request<BrandSummary[]>("/api/brands"),

  items: (
    brandId: number,
    search?: string,
    missingOnly?: boolean,
    active?: boolean,
    hasModifiers?: boolean,
  ) =>
    request<MenuItem[]>(
      `/api/brands/${brandId}/items` + qs({ search, missingOnly, active, hasModifiers }),
    ),

  itemModifierGroups: (itemId: number) =>
    request<ItemModifierGroup[]>(`/api/items/${itemId}/modifiers`),

  modifiers: (brandId: number, search?: string, active?: boolean) =>
    request<Modifier[]>(`/api/brands/${brandId}/modifiers` + qs({ search, active })),

  updateItem: (
    id: number,
    body: {
      idealWeightG: number | null;
      minWeightG: number | null;
      maxWeightG: number | null;
      packagingWeightG: number | null;
      updatedBy?: string;
    },
  ) =>
    request<MenuItem>(`/api/items/${id}/weight`, {
      method: "PUT",
      body: JSON.stringify(body),
    }),

  updateModifier: (
    id: number,
    body: {
      weightG: number | null;
      minWeightG?: number | null;
      maxWeightG?: number | null;
      updatedBy?: string;
    },
  ) =>
    request<Modifier>(`/api/modifiers/${id}/weight`, {
      method: "PUT",
      body: JSON.stringify(body),
    }),

  // Applies one weight to every active modifier in the brand sharing this
  // exact name — e.g. the same "Arwa Water" bottle Foodics has split into many
  // separate rows across different deals/combos.
  bulkUpdateModifiers: (
    brandId: number,
    body: {
      name: string;
      weightG: number | null;
      minWeightG?: number | null;
      maxWeightG?: number | null;
      updatedBy?: string;
    },
  ) =>
    request<{ updatedCount: number; modifiers: Modifier[] }>(
      `/api/brands/${brandId}/modifiers/bulk-weight`,
      { method: "PUT", body: JSON.stringify(body) },
    ),

  sync: (brandId: number) =>
    request<SyncResult>(`/api/brands/${brandId}/sync-foodics`, { method: "POST" }),

  // 2-4 modifiers that must be weighed TOGETHER — e.g. a combo-size choice
  // affecting both the fries-type AND drink-type portions at once — see
  // docs/BBT_WEIGHT_RECONCILIATION.md for the real case that motivated this.
  modifierCombinations: (brandId: number) =>
    request<ModifierCombination[]>(`/api/brands/${brandId}/modifier-combinations`),

  // Creates or updates one combination (2-4 modifier ids, in any order).
  // anchorModifierId (two-modifier combinations only) names which modifier's
  // own weight stays untouched, so weightG replaces only the OTHER one's.
  upsertModifierCombination: (body: {
    modifierIds: number[];
    anchorModifierId?: number | null;
    weightG: number;
    minWeightG?: number | null;
    maxWeightG?: number | null;
    updatedBy?: string;
  }) =>
    request<ModifierCombination>("/api/modifier-combinations", {
      method: "PUT",
      body: JSON.stringify(body),
    }),

  deleteModifierCombination: (combinationId: number) =>
    request<void>(`/api/modifier-combinations/${combinationId}`, { method: "DELETE" }),

  // The full menu (items, modifiers, combination overrides) as an Excel
  // workbook — bypasses `request()` since the response is a file, not JSON.
  exportMenu: (brandId: number) => downloadFile(`/api/brands/${brandId}/menu-export.xlsx`),

  // Uploads a (previously exported) workbook back — validates the WHOLE file
  // before applying anything; see MenuImportResult.errors.
  importMenu: (brandId: number, file: File) =>
    uploadMenuFile(`/api/brands/${brandId}/menu-import`, file),

  publish: (brandId: number, body?: { publishedBy?: string; notes?: string }) =>
    request<{ publishedVersion: number }>(`/api/brands/${brandId}/publish`, {
      method: "POST",
      body: JSON.stringify(body ?? {}),
    }),

  summary: (branchId?: number, days = 30) =>
    request<WeighSummary>("/api/weigh-events/summary" + qs({ branchId, days })),

  branches: (brandId: number) =>
    request<Branch[]>(`/api/brands/${brandId}/branches`),

  syncBranches: (brandId: number) =>
    request<BranchSyncResult>(`/api/brands/${brandId}/sync-branches`, { method: "POST" }),

  devices: (branchId: number) =>
    request<Device[]>(`/api/branches/${branchId}/devices`),

  createDevice: (branchId: number, label: string) =>
    request<DeviceCreated>(`/api/branches/${branchId}/devices`, {
      method: "POST",
      body: JSON.stringify({ label }),
    }),

  deleteDevice: (id: number) =>
    request<void>(`/api/devices/${id}`, { method: "DELETE" }),

  // Moves a scale to a different branch (and, transitively, brand if the
  // target branch belongs to one) — its key keeps working unchanged.
  reassignDevice: (deviceId: number, branchId: number) =>
    request<{ deviceId: number; branchId: number }>(`/api/devices/${deviceId}`, {
      method: "PATCH",
      body: JSON.stringify({ branchId }),
    }),

  // Issues a brand-new key for an EXISTING device — same DeviceId, so every
  // weigh event and connection-log entry already tied to it stays intact.
  // Also reactivates the device, so a previously-removed one can be brought
  // back this way instead of losing its history to a re-add.
  regenerateDeviceKey: (deviceId: number) =>
    request<DeviceCreated>(`/api/devices/${deviceId}/regenerate-key`, {
      method: "POST",
    }),

  deviceDetail: (deviceId: number) => request<DeviceDetail>(`/api/devices/${deviceId}`),

  deviceEvents: (deviceId: number, limit = 50) =>
    request<DeviceEventLogEntry[]>(`/api/devices/${deviceId}/events` + qs({ limit })),

  weighEvents: (params: {
    deviceId?: number;
    branchId?: number;
    from?: string;
    to?: string;
    limit?: number;
  }) => request<WeighEventEntry[]>("/api/weigh-events" + qs(params)),

  // Every weighed order as a CSV (item/modifier composition included) — the
  // raw material for training a weight-prediction model later, or for
  // item-level analytics (format: "items" explodes to one row per
  // order/item/modifier line instead of one row per order). Bypasses
  // `request()` since the response is a file, not JSON.
  exportWeighedOrders: (params: {
    deviceId?: number;
    brandIds?: number[];
    branchIds?: number[];
    verdicts?: string[];
    from?: string;
    to?: string;
    format?: "orders" | "items";
  }) => downloadFile("/api/weigh-events/export" + qs(params)),

  // The exact same CSV the download above produces, fetched as text instead
  // of a file — used to render a "what you're about to get" preview before
  // committing to a download, with the same filters the export button uses.
  previewWeighedOrders: (params: {
    deviceId?: number;
    brandIds?: number[];
    branchIds?: number[];
    verdicts?: string[];
    from?: string;
    to?: string;
    format?: "orders" | "items";
  }) => fetchTextFile("/api/weigh-events/export" + qs(params)),

  // A small, recent sample of matched weighed orders — regardless of trust
  // status, each one flagged — plus full-filtered-set summary counts. The
  // interactive "clean & review" step behind the AI Training Data page;
  // never the bulk export itself (see exportTrainingData for that).
  trainingPreview: (params: {
    brandIds?: number[];
    branchIds?: number[];
    from?: string;
    to?: string;
    limit?: number;
  }) => request<TrainingPreviewResult>("/api/weigh-events/training-preview" + qs(params)),

  // The full cleaned, combination-resolved dataset as a CSV, ready to fit a
  // per-component weight model against — "orders" (one row per order,
  // components semicolon-joined) or "components" (tidy long format, one row
  // per order/component, no JSON parsing needed downstream).
  exportTrainingData: (params: {
    brandIds?: number[];
    branchIds?: number[];
    from?: string;
    to?: string;
    trustedOnly?: boolean;
    format?: "orders" | "components";
  }) => downloadFile("/api/weigh-events/training-export" + qs(params)),

  // A brand's published ML weight-prediction model (see
  // docs/AI_MODEL_CONTRACT.md). Null means "no model published yet" — a
  // normal, permanent state the backend reports as a 200 with a null body
  // (not a 404), specifically so this never shows as a failed request for a
  // brand that simply hasn't had a model uploaded. A genuine failure still
  // throws ApiError like every other call here.
  modelMeta: (brandId: number) => request<ModelMeta | null>(`/api/brands/${brandId}/model`),

  // Publishes a new model for the brand, replacing whatever was there
  // before. Bypasses `request()`: this is a multipart upload, not JSON.
  uploadModel: (brandId: number, file: File, uploadedBy?: string) =>
    uploadFile(`/api/brands/${brandId}/model` + qs({ uploadedBy }), file),

  deleteModel: (brandId: number) =>
    request<void>(`/api/brands/${brandId}/model`, { method: "DELETE" }),

  // One predefined analytics question, computed server-side from real weigh
  // events — `endpoint` is the path segment under /api/analytics (e.g.
  // "branch-accuracy"), `params` carries the shared date range plus any
  // question-specific extras (e.g. order-consistency's `mode`).
  analytics: (endpoint: string, params: Record<string, string | number | undefined> = {}) =>
    request<AnalyticsResult>(`/api/analytics/${endpoint}` + qs(params)),

  dataQuality: (params: { from?: string; to?: string } = {}) =>
    request<DataQualitySummary>("/api/analytics/data-quality" + qs(params)),
};

async function uploadFile(path: string, file: File): Promise<ModelMeta> {
  const cfg = getConfig();
  if (!cfg) throw new ApiError("Not connected.", 0);

  const form = new FormData();
  form.append("file", file);

  let res: Response;
  try {
    res = await fetch(cfg.baseUrl.replace(/\/$/, "") + path, {
      method: "POST",
      headers: { "X-Api-Key": cfg.apiKey }, // no Content-Type — the browser sets the multipart boundary itself
      body: form,
    });
  } catch {
    throw new ApiError("Can't reach the API. Is it running, and is the base URL correct?", 0);
  }
  if (res.status === 401) throw new ApiError("Unauthorized — check your API key.", 401);
  if (!res.ok) {
    let msg = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.error) msg = body.error;
    } catch {
      /* keep default */
    }
    throw new ApiError(msg, res.status);
  }
  return (await res.json()) as ModelMeta;
}

async function uploadMenuFile(path: string, file: File): Promise<MenuImportResult> {
  const cfg = getConfig();
  if (!cfg) throw new ApiError("Not connected.", 0);

  const form = new FormData();
  form.append("file", file);

  let res: Response;
  try {
    res = await fetch(cfg.baseUrl.replace(/\/$/, "") + path, {
      method: "POST",
      headers: { "X-Api-Key": cfg.apiKey },
      body: form,
    });
  } catch {
    throw new ApiError("Can't reach the API. Is it running, and is the base URL correct?", 0);
  }
  if (res.status === 401) throw new ApiError("Unauthorized — check your API key.", 401);
  if (!res.ok) {
    let msg = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.error) msg = body.error;
    } catch {
      /* keep default */
    }
    throw new ApiError(msg, res.status);
  }
  return (await res.json()) as MenuImportResult;
}

async function downloadFile(path: string): Promise<Blob> {
  const cfg = getConfig();
  if (!cfg) throw new ApiError("Not connected.", 0);

  let res: Response;
  try {
    res = await fetch(cfg.baseUrl.replace(/\/$/, "") + path, {
      headers: { "X-Api-Key": cfg.apiKey },
    });
  } catch {
    throw new ApiError("Can't reach the API. Is it running, and is the base URL correct?", 0);
  }
  if (res.status === 401) throw new ApiError("Unauthorized — check your API key.", 401);
  if (!res.ok) {
    let msg = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.error) msg = body.error;
    } catch {
      /* keep default */
    }
    throw new ApiError(msg, res.status);
  }
  return res.blob();
}

async function fetchTextFile(path: string): Promise<string> {
  const cfg = getConfig();
  if (!cfg) throw new ApiError("Not connected.", 0);

  let res: Response;
  try {
    res = await fetch(cfg.baseUrl.replace(/\/$/, "") + path, {
      headers: { "X-Api-Key": cfg.apiKey },
    });
  } catch {
    throw new ApiError("Can't reach the API. Is it running, and is the base URL correct?", 0);
  }
  if (res.status === 401) throw new ApiError("Unauthorized — check your API key.", 401);
  if (!res.ok) {
    let msg = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body?.error) msg = body.error;
    } catch {
      /* keep default */
    }
    throw new ApiError(msg, res.status);
  }
  return res.text();
}

/** Maps a device-event reason code (from the tablet's own classification) to
 * a readable label — kept in sync with `ConnectionIssue.label` in the app. */
export function reasonLabel(code: string): string {
  const labels: Record<string, string> = {
    ok: "Connected",
    no_internet: "No internet, or the API address is wrong",
    timeout: "Timed out — slow or unreachable network",
    unauthorized: "Invalid or revoked scale key",
    server_error: "Head office responded with an error",
    malformed_response: "Connected, but the response wasn't understood",
  };
  return labels[code] ?? code;
}

/**
 * The best available human-readable branch label — Foodics' own localized
 * name (e.g. "Ardiya Branch") when set, falling back to the short internal
 * code (e.g. "ARD-BBT") a branch always has. Never a raw Foodics UUID.
 */
export function branchDisplayName(branch: { name: string; nameLocalized?: string | null }): string {
  return branch.nameLocalized && branch.nameLocalized.trim() ? branch.nameLocalized : branch.name;
}

/** Relative "last seen" label. */
export function timeAgo(iso: string | null): string {
  if (!iso) return "never";
  const then = new Date(iso + (iso.endsWith("Z") ? "" : "Z")).getTime();
  const s = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (s < 45) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}
