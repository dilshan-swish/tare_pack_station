import type { EntryInsert } from "./types";

/**
 * Weights that haven't reached the server yet (no signal, server hiccup).
 * Persisted per branch so a refresh, a closed tab or a dead battery doesn't
 * lose a weighing; retried until they land. Each row carries its own id and
 * the (order, line, unit) key the database is unique on, so a retry can never
 * create a duplicate.
 */
export interface OutboxItem {
  unitKey: string;
  row: EntryInsert;
  /** Size label shown when queued — lets a rejected save roll back the right progress counter. */
  sizeLabel: string | null;
  /** First weighing of this unit (vs. a correction) — decides whether counters move. */
  isNew: boolean;
  attempts: number;
  queuedAt: number;
  lastError?: string;
}

const storageKey = (branchId: string) => `tare.outbox.v1.${branchId}`;

export function loadOutbox(branchId: string): OutboxItem[] {
  try {
    const raw = localStorage.getItem(storageKey(branchId));
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (x): x is OutboxItem =>
        !!x && typeof x === "object" && typeof (x as OutboxItem).unitKey === "string" && !!(x as OutboxItem).row,
    );
  } catch {
    return [];
  }
}

export function saveOutbox(branchId: string, items: OutboxItem[]): boolean {
  try {
    if (items.length) localStorage.setItem(storageKey(branchId), JSON.stringify(items));
    else localStorage.removeItem(storageKey(branchId));
    return true;
  } catch {
    // Storage full or blocked (private mode): the in-memory queue still works
    // for this session; the caller shows a warning.
    return false;
  }
}
