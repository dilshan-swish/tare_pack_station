import type { AnalyticsResult } from "./types";
import type { RangePresetKey } from "./ui";

// Everything here is browser-local (localStorage): history, saved reports,
// alert rules/log, and preferences are all personal to whoever is using this
// browser on this machine — they don't sync across devices or other admins.
// That's an intentional, honest scope: there is no backend table for any of
// this. Every read/write is wrapped in try/catch — storage can throw in
// private browsing, over quota, or with a corrupted value — and a failure
// here should never crash the page, just fall back to an empty/default
// state for that session.

export interface HistoryEntry {
  id: string;
  askedAt: string; // ISO
  questionId: string;
  questionLabel: string;
  question: string;
  from?: string;
  to?: string;
  result: AnalyticsResult;
  saved: boolean;
}

export type AlertMetric =
  | "branch-accuracy-below"
  | "branch-variance-above"
  | "hourly-offweight-above"
  | "reweigh-flagged-above";

export interface AlertRule {
  id: string;
  metric: AlertMetric;
  label: string;
  threshold: number;
}

export interface AlertLogEntry {
  id: string;
  checkedAt: string; // ISO
  ruleLabel: string;
  detail: string;
  breached: boolean;
}

export interface AnalyticsSettings {
  defaultRangePreset: RangePresetKey;
  typewriterEnabled: boolean;
  maxTableRows: number;
  sidebarCollapsed: boolean;
}

const KEYS = {
  history: "swish.analytics.history",
  alertRules: "swish.analytics.alertRules",
  alertLog: "swish.analytics.alertLog",
  settings: "swish.analytics.settings",
} as const;

const HISTORY_CAP = 100;
const ALERT_LOG_CAP = 30;

function readJson<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as unknown;
    return parsed as T;
  } catch {
    return fallback;
  }
}

function writeJson(key: string, value: unknown): boolean {
  try {
    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch {
    return false;
  }
}

// --- History ---

export function loadHistory(): HistoryEntry[] {
  return readJson<HistoryEntry[]>(KEYS.history, []);
}

export function addHistoryEntry(entry: HistoryEntry): HistoryEntry[] {
  const next = [entry, ...loadHistory()].slice(0, HISTORY_CAP);
  writeJson(KEYS.history, next);
  return next;
}

export function toggleHistorySaved(id: string): HistoryEntry[] {
  const next = loadHistory().map((h) => (h.id === id ? { ...h, saved: !h.saved } : h));
  writeJson(KEYS.history, next);
  return next;
}

export function clearHistory(): HistoryEntry[] {
  writeJson(KEYS.history, []);
  return [];
}

export function removeHistoryEntry(id: string): HistoryEntry[] {
  const next = loadHistory().filter((h) => h.id !== id);
  writeJson(KEYS.history, next);
  return next;
}

// --- Alerts ---

export function loadAlertRules(): AlertRule[] {
  return readJson<AlertRule[]>(KEYS.alertRules, []);
}

export function saveAlertRules(rules: AlertRule[]): boolean {
  return writeJson(KEYS.alertRules, rules);
}

export function loadAlertLog(): AlertLogEntry[] {
  return readJson<AlertLogEntry[]>(KEYS.alertLog, []);
}

export function appendAlertLog(entries: AlertLogEntry[]): AlertLogEntry[] {
  const next = [...entries, ...loadAlertLog()].slice(0, ALERT_LOG_CAP);
  writeJson(KEYS.alertLog, next);
  return next;
}

export function clearAlertLog(): AlertLogEntry[] {
  writeJson(KEYS.alertLog, []);
  return [];
}

// --- Settings ---

export const DEFAULT_SETTINGS: AnalyticsSettings = {
  defaultRangePreset: "30d",
  typewriterEnabled: true,
  maxTableRows: 25,
  sidebarCollapsed: false,
};

export function loadSettings(): AnalyticsSettings {
  return { ...DEFAULT_SETTINGS, ...readJson<Partial<AnalyticsSettings>>(KEYS.settings, {}) };
}

export function saveSettings(settings: AnalyticsSettings): boolean {
  return writeJson(KEYS.settings, settings);
}
