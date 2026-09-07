import { useState, type FormEvent } from "react";
import { setConfig, getConfig } from "../api";
import { Card, Button, Banner } from "../ui";

export function LoginPage({
  onConnected,
  onCancel,
}: {
  onConnected: () => void;
  onCancel?: () => void;
}) {
  const cfg = getConfig();
  const [baseUrl, setBaseUrl] = useState(cfg?.baseUrl ?? "http://localhost:5025");
  const [apiKey, setApiKey] = useState(cfg?.apiKey ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function connect(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const clean = baseUrl.replace(/\/$/, "");
    try {
      const res = await fetch(clean + "/api/brands", {
        headers: { "X-Api-Key": apiKey },
      });
      if (res.status === 401) throw new Error("That API key was rejected.");
      if (!res.ok) throw new Error(`API returned ${res.status}.`);
      // Only persist once it actually works, so a bad attempt never sticks.
      setConfig({ baseUrl: clean, apiKey });
      onConnected();
    } catch (err) {
      setError(
        err instanceof TypeError
          ? "Can't reach the API. Check the base URL and that it's running."
          : err instanceof Error
            ? err.message
            : "Could not connect.",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-md p-7">
        <div className="mb-1 flex items-center gap-2">
          <span className="font-display text-2xl text-ink">SWiSH</span>
          <span className="rounded-full bg-amber px-2 py-0.5 text-xs font-bold text-ink">
            Weighing
          </span>
        </div>
        <p className="mb-6 text-sm text-ink/70">
          {onCancel
            ? "Connection settings — where the portal reaches the API."
            : "Head-office weight configuration portal."}
        </p>

        <form onSubmit={connect} className="space-y-4">
          <label className="block">
            <span className="mb-1 block text-sm font-semibold">API base URL</span>
            <input
              value={baseUrl}
              onChange={(e) => setBaseUrl(e.target.value)}
              className="w-full rounded-lg border-2 border-ink bg-white px-3 py-2 font-mono text-sm outline-none focus:ring-2 focus:ring-amber"
              placeholder="http://localhost:5025"
            />
          </label>
          <label className="block">
            <span className="mb-1 block text-sm font-semibold">API key</span>
            <input
              value={apiKey}
              onChange={(e) => setApiKey(e.target.value)}
              type="password"
              className="w-full rounded-lg border-2 border-ink bg-white px-3 py-2 font-mono text-sm outline-none focus:ring-2 focus:ring-amber"
              placeholder="X-Api-Key"
            />
          </label>

          {error && <Banner tone="bad">{error}</Banner>}

          <div className="flex gap-2">
            {onCancel && (
              <Button type="button" variant="outline" onClick={onCancel} className="w-full">
                Cancel
              </Button>
            )}
            <Button type="submit" disabled={busy || !apiKey} className="w-full">
              {busy ? "Connecting…" : "Connect"}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  );
}
