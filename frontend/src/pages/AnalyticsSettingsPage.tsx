import { useState } from "react";
import { Check, RotateCcw, RefreshCw } from "lucide-react";
import { Card, Button, Banner, Select, RANGE_PRESET_OPTIONS } from "../ui";
import { useTypewriter, TypeCursor } from "../analyticsUi";
import { loadSettings, saveSettings, DEFAULT_SETTINGS, type AnalyticsSettings } from "../analyticsStorage";

const DEFAULT_RANGE_OPTIONS = RANGE_PRESET_OPTIONS.filter((o) => o.value !== "custom");
const PREVIEW_TEXT = "BBT · Yard Branch is trending 4% more accurate this week.";

// Demonstrates the setting live instead of describing it in prose — toggling
// it (or hitting Replay) shows exactly what changes, right where the
// decision is made.
function TypingPreview({ enabled }: { enabled: boolean }) {
  const [replayKey, setReplayKey] = useState(0);
  return (
    <div className="mt-3 flex items-center justify-between gap-2 rounded-lg border border-line bg-page px-3 py-2.5">
      <p key={`${enabled}-${replayKey}`} className="min-h-[1.25rem] flex-1 text-sm text-ink">
        <TypingPreviewText enabled={enabled} />
      </p>
      <button
        type="button"
        onClick={() => setReplayKey((k) => k + 1)}
        className="flex flex-none items-center gap-1 text-xs font-semibold text-muted transition-colors hover:text-green"
      >
        <RefreshCw size={12} /> Replay
      </button>
    </div>
  );
}

function TypingPreviewText({ enabled }: { enabled: boolean }) {
  const { text, done } = useTypewriter(PREVIEW_TEXT, true, !enabled);
  return (
    <>
      {text}
      {!done && <TypeCursor />}
    </>
  );
}

export function AnalyticsSettingsPage() {
  const [settings, setSettings] = useState<AnalyticsSettings>(() => {
    try {
      return loadSettings();
    } catch {
      return DEFAULT_SETTINGS;
    }
  });
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedFlash, setSavedFlash] = useState(false);

  function update(partial: Partial<AnalyticsSettings>) {
    const next = { ...settings, ...partial };
    setSettings(next);
    if (saveSettings(next)) {
      setSaveError(null);
      setSavedFlash(true);
      setTimeout(() => setSavedFlash(false), 1400);
    } else {
      setSaveError("Couldn't save this preference — storage may be unavailable in this browser (private browsing, or full quota).");
    }
  }

  function resetDefaults() {
    setSettings(DEFAULT_SETTINGS);
    if (!saveSettings(DEFAULT_SETTINGS)) {
      setSaveError("Couldn't save the reset preferences to storage, but they're applied for this session.");
    }
  }

  return (
    <div>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="font-display text-lg text-ink">Settings</h2>
          <p className="text-sm text-muted">
            Preferences for this browser only — they don't sync to other devices or admins.
          </p>
        </div>
        {savedFlash && (
          <span className="flex items-center gap-1 text-xs font-semibold text-green">
            <Check size={14} /> Saved
          </span>
        )}
      </div>

      {saveError && (
        <div className="mb-3">
          <Banner tone="bad">{saveError}</Banner>
        </div>
      )}

      <Card className="divide-y divide-line p-4 sm:p-5">
        <div className="pb-4">
          <label className="mb-1 block text-sm font-semibold text-ink">Default date range</label>
          <p className="mb-2 text-xs text-muted">Applied when you open the Analytics section.</p>
          <div className="max-w-xs">
            <Select
              value={settings.defaultRangePreset}
              onChange={(v) => update({ defaultRangePreset: v })}
              options={DEFAULT_RANGE_OPTIONS}
            />
          </div>
        </div>

        <div className="py-4">
          <div className="flex items-center justify-between gap-3">
            <div>
              <div className="text-sm font-semibold text-ink">Typing animation</div>
              <p className="text-xs text-muted">Answers type out like they're being written, instead of appearing all at once.</p>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={settings.typewriterEnabled}
              onClick={() => update({ typewriterEnabled: !settings.typewriterEnabled })}
              className={`relative h-6 w-11 flex-none rounded-full transition-colors ${
                settings.typewriterEnabled ? "bg-green" : "bg-line"
              }`}
            >
              <span
                className={`absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform ${
                  settings.typewriterEnabled ? "translate-x-5" : "translate-x-0"
                }`}
              />
            </button>
          </div>
          <TypingPreview enabled={settings.typewriterEnabled} />
        </div>

        <div className="py-4">
          <label className="mb-1 block text-sm font-semibold text-ink">Max table rows shown</label>
          <p className="mb-2 text-xs text-muted">Caps how many rows render under a chart (10–100).</p>
          <input
            type="number"
            min={10}
            max={100}
            step={5}
            value={settings.maxTableRows}
            onChange={(e) => {
              const n = Number(e.target.value);
              if (Number.isFinite(n)) update({ maxTableRows: Math.min(100, Math.max(10, n)) });
            }}
            className="w-28 rounded-lg border border-line bg-white px-3 py-2 text-sm text-ink focus:border-green focus:outline-none"
          />
        </div>

        <div className="flex items-center justify-between gap-3 pt-4">
          <div>
            <div className="text-sm font-semibold text-ink">Collapse sidebar by default</div>
            <p className="text-xs text-muted">Same toggle as the "Collapse" control in the sidebar.</p>
          </div>
          <button
            type="button"
            role="switch"
            aria-checked={settings.sidebarCollapsed}
            onClick={() => update({ sidebarCollapsed: !settings.sidebarCollapsed })}
            className={`relative h-6 w-11 flex-none rounded-full transition-colors ${
              settings.sidebarCollapsed ? "bg-green" : "bg-line"
            }`}
          >
            <span
              className={`absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform ${
                settings.sidebarCollapsed ? "translate-x-5" : "translate-x-0"
              }`}
            />
          </button>
        </div>
      </Card>

      <div className="mt-4">
        <Button variant="outline" onClick={resetDefaults}>
          <RotateCcw size={14} /> Reset to defaults
        </Button>
      </div>
    </div>
  );
}
