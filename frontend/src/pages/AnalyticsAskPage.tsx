import { useEffect, useMemo, useRef, useState } from "react";
import { useLocation, useNavigate, useOutletContext } from "react-router-dom";
import {
  Search,
  Sparkles,
  ArrowRight,
  Bookmark,
  BookmarkCheck,
  Scale,
  CheckCircle2,
  ArrowDownCircle,
  ArrowUpCircle,
} from "lucide-react";
import { api, ApiError } from "../api";
import type { AnalyticsResult } from "../types";
import { Card, Button, Banner } from "../ui";
import { QUESTIONS, type QuestionDef } from "../analyticsQuestions";
import { QUESTION_VISUALS, DEFAULT_VISUAL, IconBadge } from "../analyticsIcons";
import { AnswerBody, ThinkingSkeleton, StatTile } from "../analyticsUi";
import { STATUS_COLORS } from "../analyticsPalette";
import { addHistoryEntry, loadSettings, toggleHistorySaved } from "../analyticsStorage";
import type { AnalyticsRangeContext } from "./AnalyticsLayout";

interface KpiState {
  total: number;
  onWeight: number;
  under: number;
  over: number;
  totalTrend: number[];
  onWeightTrend: number[];
  underTrend: number[];
  overTrend: number[];
}

// The KPI row's exact totals come from verdict-breakdown (it's the one
// endpoint that accounts for every weighed order, unconfigured included);
// the four sparkline shapes ride along on accuracy-trend's per-period
// breakdown, fetched once alongside it — a reasonable trend shape even
// though that endpoint's own totals exclude unconfigured events, since a
// sparkline is a decoration, not a labeled axis someone reads a value off.
function KpiStrip({ from, to }: { from?: string; to?: string }) {
  const [kpi, setKpi] = useState<KpiState | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setKpi(null);
    setFailed(false);
    Promise.all([
      api.analytics("verdict-breakdown", { from, to }),
      api.analytics("accuracy-trend", { from, to }),
    ])
      .then(([verdict, trend]) => {
        if (cancelled) return;
        const shares = verdict.chart?.data ?? [];
        const byName = (name: string) => {
          const row = shares.find((r) => r.name === name);
          return typeof row?.value === "number" ? row.value : 0;
        };
        const rows = trend.table ?? [];
        const toTrend = (col: string) =>
          rows.map((r) => (typeof r[col] === "number" ? (r[col] as number) : 0));
        setKpi({
          total: byName("On weight") + byName("Under") + byName("Over") + byName("Unconfigured"),
          onWeight: byName("On weight"),
          under: byName("Under"),
          over: byName("Over"),
          totalTrend: toTrend("Weighed orders"),
          onWeightTrend: toTrend("On weight"),
          underTrend: toTrend("Under"),
          overTrend: toTrend("Over"),
        });
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, [from, to]);

  if (failed) return null; // the KPI strip is a convenience — a failed fetch just hides it, the Ask page still works
  if (!kpi) {
    return (
      <div className="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[0, 1, 2, 3].map((i) => (
          <div key={i} className="h-[92px] animate-shimmer rounded-2xl" />
        ))}
      </div>
    );
  }

  return (
    <div className="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
      <StatTile
        icon={Scale}
        tint="bg-[#4a8bc9]/15 text-[#4a8bc9]"
        label="Weighed"
        value={kpi.total.toLocaleString()}
        trend={kpi.totalTrend}
        trendColor="#4a8bc9"
      />
      <StatTile
        icon={CheckCircle2}
        tint="bg-green/15 text-green"
        label="On weight"
        value={kpi.onWeight.toLocaleString()}
        trend={kpi.onWeightTrend}
        trendColor={STATUS_COLORS.onWeight}
      />
      <StatTile
        icon={ArrowDownCircle}
        tint="bg-coral/15 text-coral"
        label="Underweight"
        value={kpi.under.toLocaleString()}
        trend={kpi.underTrend}
        trendColor={STATUS_COLORS.under}
      />
      <StatTile
        icon={ArrowUpCircle}
        tint="bg-amber/15 text-[#8a5a10]"
        label="Overweight"
        value={kpi.over.toLocaleString()}
        trend={kpi.overTrend}
        trendColor={STATUS_COLORS.over}
      />
    </div>
  );
}

// A fixed, curated subset shown as quick-start chips on the empty state —
// picked for variety (an order-level, a branch-level, an operational, and a
// trend question) rather than just the first four in catalog order.
const QUICK_START_IDS = ["branch-accuracy", "hourly", "missed", "trend"];

interface TranscriptEntry {
  key: number;
  q: QuestionDef;
  status: "loading" | "done" | "error";
  result?: AnalyticsResult;
  error?: string;
  historyId?: string;
  saved?: boolean;
}

export function AnalyticsAskPage() {
  const { from, to } = useOutletContext<AnalyticsRangeContext>();
  const location = useLocation();
  const navigate = useNavigate();
  const [search, setSearch] = useState("");
  const [transcript, setTranscript] = useState<TranscriptEntry[]>([]);
  const nextKey = useRef(0);
  const bottomRef = useRef<HTMLDivElement | null>(null);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return QUESTIONS;
    return QUESTIONS.filter(
      (item) =>
        item.shortLabel.toLowerCase().includes(q) ||
        item.description.toLowerCase().includes(q) ||
        item.question.toLowerCase().includes(q),
    );
  }, [search]);

  async function ask(q: QuestionDef) {
    const key = nextKey.current++;
    setTranscript((prev) => [...prev, { key, q, status: "loading" }]);
    requestAnimationFrame(() =>
      bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "start" }),
    );

    const started = Date.now();
    try {
      const result = await api.analytics(q.endpoint, { ...q.extraParams, from, to });
      // A near-instant response would make the "thinking" moment flash by
      // too fast to register — holding it to at least ~650ms keeps the
      // "generating an answer" feel consistent regardless of latency.
      const elapsed = Date.now() - started;
      if (elapsed < 650) await new Promise((r) => setTimeout(r, 650 - elapsed));

      let historyId: string | undefined;
      try {
        historyId = `${Date.now()}-${key}`;
        addHistoryEntry({
          id: historyId,
          askedAt: new Date().toISOString(),
          questionId: q.id,
          questionLabel: q.shortLabel,
          question: q.question,
          from,
          to,
          result,
          saved: false,
        });
      } catch {
        /* history is a convenience, not a requirement — a storage failure here must never block the answer itself */
      }

      setTranscript((prev) =>
        prev.map((e) => (e.key === key ? { ...e, status: "done", result, historyId, saved: false } : e)),
      );
    } catch (err) {
      const message =
        err instanceof ApiError
          ? err.message
          : "Couldn't load this analysis. Check your connection and try again.";
      setTranscript((prev) =>
        prev.map((e) => (e.key === key ? { ...e, status: "error", error: message } : e)),
      );
    }
  }

  function retry(entry: TranscriptEntry) {
    setTranscript((prev) => prev.filter((e) => e.key !== entry.key));
    void ask(entry.q);
  }

  function toggleSave(entry: TranscriptEntry) {
    if (!entry.historyId) return;
    try {
      toggleHistorySaved(entry.historyId);
    } catch {
      /* best-effort */
    }
    setTranscript((prev) =>
      prev.map((e) => (e.key === entry.key ? { ...e, saved: !e.saved } : e)),
    );
  }

  // "Ask again" from History hands off the question id via router state —
  // consumed once, then cleared, so navigating back here later never
  // silently re-fires the same question a second time.
  useEffect(() => {
    const state = location.state as { reaskId?: string } | null;
    if (!state?.reaskId) return;
    const q = QUESTIONS.find((item) => item.id === state.reaskId);
    navigate(location.pathname, { replace: true, state: null });
    if (q) void ask(q);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.state]);

  const animate = loadSettings().typewriterEnabled;

  return (
    <div>
      <KpiStrip from={from} to={to} />
      <div className="grid grid-cols-1 gap-5 lg:grid-cols-[300px_1fr] lg:items-start">
      <Card className="p-3 lg:sticky lg:top-20">
        <div className="px-1.5 pb-2 pt-1 text-sm font-bold text-ink">Ask about your data</div>
        <div className="relative px-1.5 pb-2">
          <Search size={15} className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-muted" />
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search questions..."
            className="w-full rounded-lg border border-line bg-page py-2 pl-8 pr-3 text-sm text-ink placeholder:text-muted focus:border-green focus:outline-none"
          />
        </div>
        <div className="max-h-[420px] space-y-0.5 overflow-y-auto px-1 pb-1 lg:max-h-[calc(100vh-260px)]">
          {filtered.length === 0 && (
            <p className="px-2 py-6 text-center text-sm text-muted">No questions match "{search}".</p>
          )}
          {filtered.map((q, i) => {
            const visual = QUESTION_VISUALS[q.id] ?? DEFAULT_VISUAL;
            return (
              <button
                key={q.id}
                type="button"
                onClick={() => void ask(q)}
                style={{ animationDelay: `${Math.min(i, 8) * 35}ms` }}
                className="animate-fade-up flex w-full min-h-[44px] items-center gap-2.5 rounded-xl border border-transparent px-2 py-2 text-left transition-all duration-150 hover:border-line hover:bg-black/[0.02] active:scale-[0.98]"
              >
                <IconBadge icon={visual.icon} tint={visual.tint} size="sm" />
                <span className="min-w-0">
                  <span className="block truncate text-sm font-semibold text-ink">{q.shortLabel}</span>
                  <span className="block truncate text-xs text-muted">{q.description}</span>
                </span>
              </button>
            );
          })}
        </div>
      </Card>

      <div className="min-w-0">
        {transcript.length === 0 ? (
          <Card className="flex flex-col items-center px-5 py-14 text-center sm:px-10">
            <span className="animate-breathe flex h-14 w-14 items-center justify-center rounded-full bg-ink text-white">
              <Sparkles size={22} />
            </span>
            <h2 className="mt-4 font-display text-xl text-ink">Hi there! I'm your analytics assistant.</h2>
            <p className="mt-2 max-w-sm text-sm text-muted">
              Ask me anything about your weighing data and I'll help you find the insights you need.
            </p>
            <div className="mt-6 grid w-full max-w-lg grid-cols-1 gap-2.5 lg:grid-cols-2">
              {QUICK_START_IDS.map((id, i) => {
                const q = QUESTIONS.find((item) => item.id === id);
                if (!q) return null;
                return (
                  <button
                    key={id}
                    type="button"
                    onClick={() => void ask(q)}
                    style={{ animationDelay: `${150 + i * 60}ms` }}
                    className="animate-fade-up flex min-h-[44px] items-center justify-between gap-2 rounded-xl border border-line bg-white px-4 py-3 text-left text-sm font-semibold text-ink transition-all duration-150 hover:-translate-y-0.5 hover:border-green/40 hover:card-shadow-hover active:scale-[0.97] active:translate-y-0"
                  >
                    {q.shortLabel}
                    <ArrowRight size={15} className="flex-none text-muted" />
                  </button>
                );
              })}
            </div>
          </Card>
        ) : (
          <div className="space-y-5">
            {transcript.map((entry) => {
              const visual = QUESTION_VISUALS[entry.q.id] ?? DEFAULT_VISUAL;
              return (
                <div key={entry.key} className="animate-fade-up">
                  <div className="mb-2 flex flex-wrap items-center gap-2">
                    <span className="flex-none rounded-full bg-ink px-3 py-1 text-xs font-semibold text-white">
                      You asked
                    </span>
                    <span className="break-words text-sm font-semibold text-ink">{entry.q.question}</span>
                  </div>
                  <Card className="p-4 sm:p-5">
                    <div className="flex items-start gap-3">
                      <IconBadge icon={visual.icon} tint={visual.tint} />
                      <div className="min-w-0 flex-1">
                        {entry.status === "loading" && <ThinkingSkeleton />}
                        {entry.status === "error" && (
                          <div className="space-y-2">
                            <Banner tone="bad">{entry.error}</Banner>
                            <Button variant="outline" onClick={() => retry(entry)}>
                              Try again
                            </Button>
                          </div>
                        )}
                        {entry.status === "done" && entry.result && (
                          <>
                            <AnswerBody result={entry.result} animate={animate} />
                            {entry.historyId && (
                              <button
                                type="button"
                                onClick={() => toggleSave(entry)}
                                className="mt-3 flex items-center gap-1.5 text-xs font-semibold text-muted transition-colors hover:text-green"
                              >
                                {entry.saved ? (
                                  <>
                                    <BookmarkCheck size={14} className="text-green" /> Saved to reports
                                  </>
                                ) : (
                                  <>
                                    <Bookmark size={14} /> Save to reports
                                  </>
                                )}
                              </button>
                            )}
                          </>
                        )}
                      </div>
                    </div>
                  </Card>
                </div>
              );
            })}
            <div ref={bottomRef} />
          </div>
        )}
        <p className="mt-4 text-center text-xs text-muted">
          Answers are generated from your data and may not always be 100% accurate.
        </p>
      </div>
      </div>
    </div>
  );
}
