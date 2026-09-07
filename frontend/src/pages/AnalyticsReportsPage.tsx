import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { BookmarkX, RotateCcw, FileText } from "lucide-react";
import { Card } from "../ui";
import { QUESTION_VISUALS, DEFAULT_VISUAL, IconBadge } from "../analyticsIcons";
import { AnswerBody } from "../analyticsUi";
import { loadHistory, toggleHistorySaved, type HistoryEntry } from "../analyticsStorage";

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export function AnalyticsReportsPage() {
  const navigate = useNavigate();
  const [saved, setSaved] = useState<HistoryEntry[]>(() => {
    try {
      return loadHistory().filter((h) => h.saved);
    } catch {
      return [];
    }
  });
  const [loadError, setLoadError] = useState<string | null>(null);

  function unsave(id: string) {
    try {
      toggleHistorySaved(id);
      setSaved(loadHistory().filter((h) => h.saved));
    } catch {
      setLoadError("Couldn't update saved reports — storage may be unavailable in this browser.");
    }
  }

  return (
    <div>
      <div className="mb-4">
        <h2 className="font-display text-lg text-ink">Reports</h2>
        <p className="text-sm text-muted">
          Insights you've bookmarked from Ask or History, so they're quick to find again later.
        </p>
      </div>

      {loadError && (
        <div className="mb-3">
          <Card className="border-badtext/30 bg-badbg p-3 text-sm text-badtext">{loadError}</Card>
        </div>
      )}

      {saved.length === 0 ? (
        <Card className="flex flex-col items-center px-6 py-14 text-center">
          <span className="flex h-12 w-12 items-center justify-center rounded-full bg-muted/10 text-muted">
            <FileText size={20} />
          </span>
          <p className="mt-3 max-w-sm text-sm text-muted">
            Nothing saved yet — hit "Save to reports" under any answer on the Ask page or in History to pin
            it here.
          </p>
        </Card>
      ) : (
        <div className="space-y-3">
          {saved.map((entry) => {
            const visual = QUESTION_VISUALS[entry.questionId] ?? DEFAULT_VISUAL;
            return (
              <Card key={entry.id} className="p-4 sm:p-5">
                <div className="flex items-start gap-3">
                  <IconBadge icon={visual.icon} tint={visual.tint} />
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="text-sm font-semibold text-ink">{entry.question}</span>
                      <span className="flex-none text-xs text-muted">{formatDate(entry.askedAt)}</span>
                    </div>
                    <div className="mt-3">
                      <AnswerBody result={entry.result} animate={false} maxTableRows={10} />
                    </div>
                    <div className="mt-3 flex flex-wrap items-center gap-3">
                      <button
                        type="button"
                        onClick={() => navigate("/analytics", { state: { reaskId: entry.questionId } })}
                        className="flex items-center gap-1.5 text-xs font-semibold text-muted transition-colors hover:text-ink"
                      >
                        <RotateCcw size={13} /> Refresh with current range
                      </button>
                      <button
                        type="button"
                        onClick={() => unsave(entry.id)}
                        className="flex items-center gap-1.5 text-xs font-semibold text-muted transition-colors hover:text-badtext"
                      >
                        <BookmarkX size={13} /> Remove from reports
                      </button>
                    </div>
                  </div>
                </div>
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
}
