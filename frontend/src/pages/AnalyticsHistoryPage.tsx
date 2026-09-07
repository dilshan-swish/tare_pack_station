import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ChevronDown, ChevronUp, RotateCcw, Trash2, Bookmark, BookmarkCheck, History as HistoryIcon } from "lucide-react";
import { Card, Button } from "../ui";
import { askConfirm } from "../confirmDialog";
import { QUESTION_VISUALS, DEFAULT_VISUAL, IconBadge } from "../analyticsIcons";
import { AnswerBody } from "../analyticsUi";
import {
  loadHistory,
  clearHistory,
  removeHistoryEntry,
  toggleHistorySaved,
  type HistoryEntry,
} from "../analyticsStorage";

function timeAgo(iso: string): string {
  const d = new Date(iso).getTime();
  const diffMs = Date.now() - d;
  const mins = Math.floor(diffMs / 60_000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function AnalyticsHistoryPage() {
  const navigate = useNavigate();
  const [entries, setEntries] = useState<HistoryEntry[]>(() => {
    try {
      return loadHistory();
    } catch {
      return [];
    }
  });
  const [expanded, setExpanded] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  function refresh() {
    try {
      setEntries(loadHistory());
      setLoadError(null);
    } catch {
      setLoadError("Couldn't read saved history from this browser's storage.");
    }
  }

  async function onClear() {
    if (
      !(await askConfirm({
        message: "Clear all question history? This can't be undone.",
        confirmLabel: "Clear history",
        tone: "danger",
      }))
    )
      return;
    try {
      setEntries(clearHistory());
    } catch {
      setLoadError("Couldn't clear history — storage may be unavailable in this browser.");
    }
  }

  function onRemove(id: string) {
    try {
      setEntries(removeHistoryEntry(id));
    } catch {
      setLoadError("Couldn't remove this entry.");
    }
  }

  function onToggleSave(id: string) {
    try {
      setEntries(toggleHistorySaved(id));
    } catch {
      setLoadError("Couldn't update saved status.");
    }
  }

  return (
    <div>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="font-display text-lg text-ink">History</h2>
          <p className="text-sm text-muted">Every question you've asked on this browser, most recent first.</p>
        </div>
        {entries.length > 0 && (
          <Button variant="outline" onClick={() => void onClear()}>
            <Trash2 size={14} /> Clear history
          </Button>
        )}
      </div>

      {loadError && (
        <div className="mb-3">
          <Card className="border-badtext/30 bg-badbg p-3 text-sm text-badtext">
            {loadError}
            <button type="button" onClick={refresh} className="ml-2 font-semibold underline">
              Retry
            </button>
          </Card>
        </div>
      )}

      {entries.length === 0 ? (
        <Card className="flex flex-col items-center px-6 py-14 text-center">
          <span className="flex h-12 w-12 items-center justify-center rounded-full bg-muted/10 text-muted">
            <HistoryIcon size={20} />
          </span>
          <p className="mt-3 text-sm text-muted">
            Nothing here yet — questions you ask on the Ask page will show up here.
          </p>
        </Card>
      ) : (
        <div className="space-y-2.5">
          {entries.map((entry) => {
            const visual = QUESTION_VISUALS[entry.questionId] ?? DEFAULT_VISUAL;
            const isOpen = expanded === entry.id;
            return (
              <Card key={entry.id} className="p-3 sm:p-4">
                <div className="flex items-start gap-3">
                  <IconBadge icon={visual.icon} tint={visual.tint} size="sm" />
                  <div className="min-w-0 flex-1">
                    <button
                      type="button"
                      onClick={() => setExpanded(isOpen ? null : entry.id)}
                      className="flex w-full items-start justify-between gap-2 text-left"
                    >
                      <span className="min-w-0">
                        <span className="block break-words text-sm font-semibold text-ink">{entry.question}</span>
                        <span className="mt-0.5 block text-xs text-muted">{timeAgo(entry.askedAt)}</span>
                      </span>
                      {isOpen ? (
                        <ChevronUp size={16} className="mt-0.5 flex-none text-muted" />
                      ) : (
                        <ChevronDown size={16} className="mt-0.5 flex-none text-muted" />
                      )}
                    </button>
                    {isOpen && entry.result && (
                      <div className="mt-3 border-t border-line pt-3">
                        <AnswerBody result={entry.result} animate={false} maxTableRows={10} />
                      </div>
                    )}
                    <div className="mt-2.5 flex flex-wrap items-center gap-3">
                      <button
                        type="button"
                        onClick={() => onToggleSave(entry.id)}
                        className="flex items-center gap-1.5 text-xs font-semibold text-muted transition-colors hover:text-green"
                      >
                        {entry.saved ? (
                          <>
                            <BookmarkCheck size={13} className="text-green" /> Saved
                          </>
                        ) : (
                          <>
                            <Bookmark size={13} /> Save to reports
                          </>
                        )}
                      </button>
                      <button
                        type="button"
                        onClick={() => navigate("/analytics", { state: { reaskId: entry.questionId } })}
                        className="flex items-center gap-1.5 text-xs font-semibold text-muted transition-colors hover:text-ink"
                      >
                        <RotateCcw size={13} /> Ask again
                      </button>
                      <button
                        type="button"
                        onClick={() => onRemove(entry.id)}
                        className="flex items-center gap-1.5 text-xs font-semibold text-muted transition-colors hover:text-badtext"
                      >
                        <Trash2 size={13} /> Remove
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
