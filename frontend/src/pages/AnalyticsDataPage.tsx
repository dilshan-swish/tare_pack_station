import { useEffect, useState } from "react";
import { useOutletContext } from "react-router-dom";
import { Database, ListChecks, Ruler, Building2, Cpu, AlertCircle } from "lucide-react";
import { api, ApiError } from "../api";
import type { DataQualitySummary } from "../types";
import { Card, Banner, Button, Spinner } from "../ui";
import { DataTable } from "../analyticsUi";
import type { AnalyticsRangeContext } from "./AnalyticsLayout";

function formatDate(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso.endsWith("Z") ? iso : iso + "Z").toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function StatTile({
  icon: Icon,
  label,
  value,
  sub,
}: {
  icon: typeof Database;
  label: string;
  value: string;
  sub?: string;
}) {
  return (
    <Card className="p-4">
      <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-muted">
        <Icon size={14} /> {label}
      </div>
      <div className="mt-1.5 font-mono text-2xl font-bold text-ink">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-muted">{sub}</div>}
    </Card>
  );
}

export function AnalyticsDataPage() {
  const { from, to } = useOutletContext<AnalyticsRangeContext>();
  const [data, setData] = useState<DataQualitySummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      setData(await api.dataQuality({ from, to }));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Couldn't load data quality. Check your connection and try again.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [from, to]);

  return (
    <div>
      <div className="mb-4">
        <h2 className="font-display text-lg text-ink">Data</h2>
        <p className="text-sm text-muted">
          What's actually behind the numbers above — how much weigh-event data exists, and how complete it
          is, for the selected date range.
        </p>
      </div>

      {loading ? (
        <Card className="p-8">
          <Spinner />
        </Card>
      ) : error ? (
        <Card className="p-5">
          <Banner tone="bad">{error}</Banner>
          <div className="mt-3">
            <Button variant="outline" onClick={() => void load()}>
              Retry
            </Button>
          </div>
        </Card>
      ) : data ? (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
            <StatTile icon={Database} label="Weighed events" value={data.totalWeighEvents.toLocaleString()} />
            <StatTile
              icon={ListChecks}
              label="Composition captured"
              value={`${data.compositionCapturePct}%`}
              sub={`${data.eventsWithComposition} of ${data.totalWeighEvents} events`}
            />
            <StatTile
              icon={Ruler}
              label="Expected range set"
              value={`${data.expectedRangeCapturePct}%`}
              sub={`${data.eventsWithExpectedRange} of ${data.totalWeighEvents} events`}
            />
            <StatTile
              icon={Building2}
              label="Active branches"
              value={`${data.activeBranches}/${data.totalBranches}`}
              sub={`${data.branchesWithNoWeighs} with no weighs in range`}
            />
            <StatTile
              icon={Cpu}
              label="Active scales"
              value={`${data.activeDevices}/${data.totalDevices}`}
            />
            <StatTile
              icon={AlertCircle}
              label="Date span"
              value={data.totalWeighEvents > 0 ? "Covered" : "No data"}
              sub={
                data.totalWeighEvents > 0
                  ? `${formatDate(data.oldestEventAt)} — ${formatDate(data.newestEventAt)}`
                  : undefined
              }
            />
          </div>

          <Card className="mt-4 p-4 sm:p-5">
            <div className="text-sm font-bold text-ink">Coverage by branch</div>
            <p className="mt-0.5 text-xs text-muted">
              Composition and expected-range capture rates for every branch with at least one weighed order
              in this range.
            </p>
            {data.byBranch.length === 0 ? (
              <p className="mt-4 text-sm text-muted">No weighed orders in this range yet.</p>
            ) : (
              <DataTable
                columns={["Branch", "Weighed orders", "Composition captured", "Expected range set", "Last weighed"]}
                rows={data.byBranch.map((b) => ({
                  Branch: b.branchLabel,
                  "Weighed orders": b.eventCount,
                  "Composition captured": `${b.compositionCapturePct}%`,
                  "Expected range set": `${b.expectedRangeCapturePct}%`,
                  "Last weighed": formatDate(b.lastWeighedAt),
                }))}
              />
            )}
          </Card>
        </>
      ) : null}
    </div>
  );
}
