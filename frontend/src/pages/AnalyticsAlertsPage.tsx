import { useState } from "react";
import { useOutletContext } from "react-router-dom";
import { Bell, Plus, Trash2, PlayCircle, AlertTriangle, CheckCircle2 } from "lucide-react";
import { api, ApiError } from "../api";
import type { ChartSpec } from "../types";
import { Card, Button, Banner, ButtonSpinner, Select } from "../ui";
import { askConfirm } from "../confirmDialog";
import {
  loadAlertRules,
  saveAlertRules,
  loadAlertLog,
  appendAlertLog,
  clearAlertLog,
  type AlertRule,
  type AlertMetric,
  type AlertLogEntry,
} from "../analyticsStorage";
import type { AnalyticsRangeContext } from "./AnalyticsLayout";

interface MetricDef {
  label: string;
  unit: string;
  endpoint: string;
  dataKey: string;
  nameKey: string;
  direction: "below" | "above";
  describe: (threshold: number) => string;
}

const METRIC_DEFS: Record<AlertMetric, MetricDef> = {
  "branch-accuracy-below": {
    label: "Branch accuracy drops below",
    unit: "%",
    endpoint: "branch-accuracy",
    dataKey: "accuracyPct",
    nameKey: "label",
    direction: "below",
    describe: (t) => `Alert if any branch's on-weight accuracy falls below ${t}%`,
  },
  "branch-variance-above": {
    label: "Branch variance rises above",
    unit: "%",
    endpoint: "branch-variance",
    dataKey: "stdDevPct",
    nameKey: "label",
    direction: "above",
    describe: (t) => `Alert if any branch's weight variance rises above ±${t}%`,
  },
  "hourly-offweight-above": {
    label: "Hourly off-weight rate rises above",
    unit: "%",
    endpoint: "hourly-pattern",
    dataKey: "offWeightPct",
    nameKey: "label",
    direction: "above",
    describe: (t) => `Alert if any hour's off-weight rate rises above ${t}%`,
  },
  "reweigh-flagged-above": {
    label: "Item flagged for recalibration more than",
    unit: "times",
    endpoint: "reweigh-candidates",
    dataKey: "flagCount",
    nameKey: "label",
    direction: "above",
    describe: (t) => `Alert if any item/modifier is flagged for recalibration more than ${t} times`,
  },
};

const METRIC_OPTIONS = (Object.keys(METRIC_DEFS) as AlertMetric[]).map((m) => ({
  value: m,
  label: METRIC_DEFS[m].label,
}));

interface RuleResult {
  rule: AlertRule;
  breached: boolean;
  detail: string;
}

export function AnalyticsAlertsPage() {
  const { from, to } = useOutletContext<AnalyticsRangeContext>();
  const [rules, setRules] = useState<AlertRule[]>(() => {
    try {
      return loadAlertRules();
    } catch {
      return [];
    }
  });
  const [log, setLog] = useState<AlertLogEntry[]>(() => {
    try {
      return loadAlertLog();
    } catch {
      return [];
    }
  });
  const [newMetric, setNewMetric] = useState<AlertMetric>("branch-accuracy-below");
  const [newThreshold, setNewThreshold] = useState("60");
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const [results, setResults] = useState<RuleResult[] | null>(null);
  const [storageError, setStorageError] = useState<string | null>(null);

  function persistRules(next: AlertRule[]) {
    setRules(next);
    if (!saveAlertRules(next)) {
      setStorageError("Rule saved for this session, but couldn't be written to storage — it won't survive a reload.");
    }
  }

  function addRule() {
    const threshold = Number(newThreshold);
    if (!Number.isFinite(threshold) || threshold < 0) {
      setStorageError("Enter a valid, non-negative threshold number.");
      return;
    }
    setStorageError(null);
    const def = METRIC_DEFS[newMetric];
    const rule: AlertRule = {
      id: `${Date.now()}`,
      metric: newMetric,
      threshold,
      label: def.describe(threshold),
    };
    persistRules([...rules, rule]);
  }

  function removeRule(id: string) {
    persistRules(rules.filter((r) => r.id !== id));
    setResults((prev) => (prev ? prev.filter((r) => r.rule.id !== id) : prev));
  }

  async function checkNow() {
    if (rules.length === 0) return;
    setChecking(true);
    setCheckError(null);
    try {
      const neededEndpoints = Array.from(new Set(rules.map((r) => METRIC_DEFS[r.metric].endpoint)));
      const responses = await Promise.all(
        neededEndpoints.map((ep) => api.analytics(ep, { from, to })),
      );
      const byEndpoint = new Map(neededEndpoints.map((ep, i) => [ep, responses[i]]));

      const newResults: RuleResult[] = rules.map((rule) => {
        const def = METRIC_DEFS[rule.metric];
        const result = byEndpoint.get(def.endpoint);
        const chart: ChartSpec | null = result?.chart ?? null;
        if (!chart || chart.data.length === 0) {
          return { rule, breached: false, detail: "No data available for this metric in the selected range." };
        }
        const breaches = chart.data.filter((row) => {
          const value = row[def.dataKey];
          if (typeof value !== "number") return false;
          return def.direction === "below" ? value < rule.threshold : value > rule.threshold;
        });
        if (breaches.length === 0) {
          return { rule, breached: false, detail: "Within range — no breach found." };
        }
        const detail = breaches
          .slice(0, 5)
          .map((row) => `${row[def.nameKey]}: ${row[def.dataKey]}${def.unit === "%" ? "%" : ` ${def.unit}`}`)
          .join("; ");
        return { rule, breached: true, detail };
      });

      setResults(newResults);
      const breachedEntries: AlertLogEntry[] = newResults
        .filter((r) => r.breached)
        .map((r) => ({
          id: `${Date.now()}-${r.rule.id}`,
          checkedAt: new Date().toISOString(),
          ruleLabel: r.rule.label,
          detail: r.detail,
          breached: true,
        }));
      if (breachedEntries.length > 0) {
        try {
          setLog(appendAlertLog(breachedEntries));
        } catch {
          /* the check result is still shown live even if logging it fails */
        }
      }
    } catch (err) {
      setCheckError(
        err instanceof ApiError ? err.message : "Couldn't check alerts. Check your connection and try again.",
      );
    } finally {
      setChecking(false);
    }
  }

  async function onClearLog() {
    if (
      !(await askConfirm({
        message: "Clear the alert log? This can't be undone.",
        confirmLabel: "Clear log",
        tone: "danger",
      }))
    )
      return;
    setLog(clearAlertLog());
  }

  return (
    <div>
      <div className="mb-4">
        <h2 className="font-display text-lg text-ink">Alerts</h2>
        <p className="text-sm text-muted">
          Set a threshold, then hit "Check now" against the selected date range. This checks on demand when
          you're on this page — it doesn't run in the background or send notifications outside the portal.
        </p>
      </div>

      <Card className="p-4 sm:p-5">
        <div className="text-sm font-bold text-ink">Add a threshold</div>
        <div className="mt-3 flex flex-col gap-2.5 sm:flex-row sm:items-end">
          <div className="flex-1">
            <label className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Metric</label>
            <Select value={newMetric} onChange={setNewMetric} options={METRIC_OPTIONS} />
          </div>
          <div className="sm:w-32">
            <label className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">
              Threshold ({METRIC_DEFS[newMetric].unit})
            </label>
            <input
              type="number"
              min={0}
              value={newThreshold}
              onChange={(e) => setNewThreshold(e.target.value)}
              className="w-full rounded-lg border border-line bg-white px-3 py-2 text-sm text-ink focus:border-green focus:outline-none"
            />
          </div>
          <Button variant="outline" onClick={addRule} className="sm:flex-none">
            <Plus size={14} /> Add rule
          </Button>
        </div>
        {storageError && (
          <div className="mt-2.5">
            <Banner tone="bad">{storageError}</Banner>
          </div>
        )}
      </Card>

      <Card className="mt-4 p-4 sm:p-5">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="text-sm font-bold text-ink">Configured thresholds ({rules.length})</div>
          <Button variant="primary" onClick={() => void checkNow()} disabled={rules.length === 0 || checking}>
            {checking ? (
              <>
                <ButtonSpinner /> Checking…
              </>
            ) : (
              <>
                <PlayCircle size={15} /> Check now
              </>
            )}
          </Button>
        </div>

        {checkError && (
          <div className="mt-3">
            <Banner tone="bad">{checkError}</Banner>
          </div>
        )}

        {rules.length === 0 ? (
          <div className="mt-4 flex flex-col items-center py-8 text-center">
            <span className="flex h-12 w-12 items-center justify-center rounded-full bg-muted/10 text-muted">
              <Bell size={20} />
            </span>
            <p className="mt-3 text-sm text-muted">No thresholds configured yet — add one above.</p>
          </div>
        ) : (
          <div className="mt-3 space-y-2">
            {rules.map((rule) => {
              const result = results?.find((r) => r.rule.id === rule.id);
              return (
                <div key={rule.id} className="flex items-start justify-between gap-3 rounded-xl border border-line p-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      {result &&
                        (result.breached ? (
                          <AlertTriangle size={15} className="flex-none text-badtext" />
                        ) : (
                          <CheckCircle2 size={15} className="flex-none text-oktext" />
                        ))}
                      <span className="break-words text-sm font-semibold text-ink">{rule.label}</span>
                    </div>
                    {result && (
                      <p className={`mt-1 text-xs ${result.breached ? "text-badtext" : "text-muted"}`}>
                        {result.breached ? "Breached — " : ""}
                        {result.detail}
                      </p>
                    )}
                  </div>
                  <button
                    type="button"
                    onClick={() => removeRule(rule.id)}
                    className="flex-none text-muted transition-colors hover:text-badtext"
                    aria-label="Remove threshold"
                  >
                    <Trash2 size={15} />
                  </button>
                </div>
              );
            })}
          </div>
        )}
      </Card>

      <Card className="mt-4 p-4 sm:p-5">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="text-sm font-bold text-ink">Alert log</div>
          {log.length > 0 && (
            <Button variant="outline" onClick={() => void onClearLog()}>
              <Trash2 size={14} /> Clear log
            </Button>
          )}
        </div>
        {log.length === 0 ? (
          <p className="mt-3 text-sm text-muted">No breaches recorded yet — they'll show up here after "Check now" finds one.</p>
        ) : (
          <div className="mt-3 space-y-2">
            {log.map((entry) => (
              <div key={entry.id} className="rounded-xl border border-badtext/20 bg-badbg/40 p-3">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-sm font-semibold text-ink">{entry.ruleLabel}</span>
                  <span className="text-xs text-muted">{new Date(entry.checkedAt).toLocaleString()}</span>
                </div>
                <p className="mt-1 text-xs text-badtext">{entry.detail}</p>
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}
