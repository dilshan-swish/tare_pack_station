import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowRight, History } from "lucide-react";
import { api } from "../api";
import type { WeighSummary } from "../types";
import { Card, Banner, Spinner } from "../ui";

function Tile({
  label,
  value,
  tone = "ink",
  delayMs = 0,
}: {
  label: string;
  value: number;
  tone?: "ink" | "ok" | "amber" | "coral";
  delayMs?: number;
}) {
  const color = {
    ink: "text-ink",
    ok: "text-oktext",
    amber: "text-ink",
    coral: "text-badtext",
  }[tone];
  return (
    <Card hover className="animate-fade-up p-5" style={{ animationDelay: `${delayMs}ms` }}>
      <div className="text-xs font-semibold uppercase tracking-wide text-ink/60">
        {label}
      </div>
      <div className={`font-mono text-4xl font-bold ${color}`}>{value}</div>
    </Card>
  );
}

export function DashboardPage() {
  const [data, setData] = useState<WeighSummary | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        setData(await api.summary(undefined, 30));
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load.");
      }
    })();
  }, []);

  if (error) return <Banner tone="bad">{error}</Banner>;
  if (!data) return <Spinner />;

  const accuracy = data.total > 0 ? Math.round((data.onWeight / data.total) * 100) : 0;
  const okPct = data.total > 0 ? (data.onWeight / data.total) * 100 : 0;
  const offPct = data.total > 0 ? (data.offWeight / data.total) * 100 : 0;
  // Not every weighed order resolves to on/under/over — one reported before
  // an expected range was configured, say, lands as neither. The bar and its
  // legend must agree on what that remainder actually is, rather than
  // silently lumping it into "off weight" (which specifically means a
  // measured packing miss, not a data-completeness gap).
  const unresolved = Math.max(0, data.total - data.onWeight - data.offWeight);
  const unresolvedPct = data.total > 0 ? (unresolved / data.total) * 100 : 0;

  return (
    <div className="animate-fade-up">
      <h1 className="font-display text-2xl text-ink">Dashboard</h1>
      <p className="mb-6 mt-1 text-sm text-muted">Weigh activity, last 30 days.</p>

      {data.total === 0 && (
        <div className="mb-5">
          <Banner tone="warn">
            No weigh events yet — figures appear here once the store tablets start
            sending data.
          </Banner>
        </div>
      )}

      <div className="mb-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Tile label="Weighed" value={data.total} delayMs={0} />
        <Tile label="On weight" value={data.onWeight} tone="ok" delayMs={60} />
        <Tile label="Underweight" value={data.under} tone="coral" delayMs={120} />
        <Tile label="Overweight" value={data.over} tone="amber" delayMs={180} />
      </div>

      <Card className="animate-fade-up p-5" style={{ animationDelay: "240ms" }}>
        <div className="mb-2 flex items-center justify-between">
          <span className="font-display text-lg">Accuracy</span>
          <span className="font-mono text-lg font-bold">{accuracy}%</span>
        </div>
        <div className="flex h-5 w-full overflow-hidden rounded-full border-2 border-ink bg-white">
          <div
            className="h-full bg-oktext transition-[width] duration-700 ease-out"
            style={{ width: `${okPct}%` }}
          />
          <div
            className="h-full bg-amber transition-[width] duration-700 ease-out"
            style={{ width: `${offPct}%` }}
          />
          {unresolved > 0 && (
            <div
              className="h-full bg-line transition-[width] duration-700 ease-out"
              style={{ width: `${unresolvedPct}%` }}
            />
          )}
        </div>
        <div className="mt-2 flex flex-wrap gap-4 text-xs font-semibold text-ink/70">
          <span>
            <span className="text-oktext">■</span> On weight ({data.onWeight})
          </span>
          <span>
            <span className="text-amber">■</span> Off weight ({data.offWeight})
          </span>
          {unresolved > 0 && (
            <span>
              <span className="text-muted">■</span> Unconfigured ({unresolved})
            </span>
          )}
        </div>
      </Card>

      <Link to="/weigh-history" className="mt-4 block">
        <Card
          hover
          className="animate-fade-up flex items-center gap-4 p-5"
          style={{ animationDelay: "300ms" }}
        >
          <span className="flex h-10 w-10 flex-none items-center justify-center rounded-full bg-green/10 text-green">
            <History size={18} />
          </span>
          <span className="min-w-0 flex-1">
            <span className="block font-display text-sm text-ink">Weigh History</span>
            <span className="block text-xs text-muted">
              Browse, search by item, and download every weighed order in detail.
            </span>
          </span>
          <ArrowRight size={16} className="flex-none text-muted" />
        </Card>
      </Link>
    </div>
  );
}
