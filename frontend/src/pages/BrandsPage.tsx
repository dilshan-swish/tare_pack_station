import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { api, ApiError } from "../api";
import type { BrandSummary, ModelMeta } from "../types";
import { Card, Button, Badge, Banner, Spinner, Coverage, ButtonSpinner, Modal } from "../ui";
import { askConfirm } from "../confirmDialog";

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function formatDate(iso: string): string {
  return new Date(iso.endsWith("Z") ? iso : iso + "Z").toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

// Publishing/replacing a brand's ML weight-prediction model — every scale on
// this brand picks it up automatically within ~20s, no app update needed.
// See docs/AI_MODEL_CONTRACT.md for the exact shape a model must implement.
function ModelModal({ brand, onClose }: { brand: BrandSummary; onClose: () => void }) {
  // `meta` alone can't distinguish "still loading" from "loaded, no model
  // published" — the backend reports "no model" as an empty (204) response,
  // which resolves to the same `undefined` a not-yet-loaded state would also
  // start from. A separate `loading` flag keeps the two unambiguous.
  const [meta, setMeta] = useState<ModelMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<"upload" | "delete" | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  async function load() {
    setError(null);
    try {
      setMeta((await api.modelMeta(brand.brandId)) ?? null);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Failed to load model status.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [brand.brandId]);

  async function upload(file: File) {
    if (!file.name.toLowerCase().endsWith(".tflite")) {
      setError("Only .tflite files are accepted.");
      return;
    }
    setBusy("upload");
    setError(null);
    try {
      setMeta(await api.uploadModel(brand.brandId, file));
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Upload failed.");
    } finally {
      setBusy(null);
      if (fileInput.current) fileInput.current.value = "";
    }
  }

  async function remove() {
    if (
      !(await askConfirm({
        message: `Remove the published model for ${brand.name}? Every scale on this brand falls back to the built-in formula immediately.`,
        confirmLabel: "Remove",
        tone: "danger",
      }))
    )
      return;
    setBusy("delete");
    setError(null);
    try {
      await api.deleteModel(brand.brandId);
      setMeta(null);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Could not remove the model.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <Modal open onClose={onClose} title={`AI model — ${brand.name}`}>
      <p className="mb-4 text-sm text-muted">
        An optional model that refines the expected weight for orders with no exact Min/Max
        standard. Every scale on this brand downloads it automatically — no app update needed.
      </p>

      {error && <div className="mb-3"><Banner tone="bad">{error}</Banner></div>}

      {loading ? (
        <Spinner />
      ) : (
        <>
          {meta ? (
            <div className="mb-4 rounded-xl border border-line bg-black/[0.02] p-4 text-sm">
              <div className="flex items-center justify-between">
                <span className="font-bold text-ink">Version {meta.version}</span>
                <Badge tone="ok">Published</Badge>
              </div>
              <div className="mt-2 space-y-1 font-mono text-xs text-muted">
                <div>{meta.fileName} · {formatBytes(meta.sizeBytes)}</div>
                <div>Uploaded {formatDate(meta.uploadedAt)}</div>
                <div title={meta.sha256Hash}>sha256 {meta.sha256Hash.slice(0, 16)}…</div>
              </div>
            </div>
          ) : (
            <div className="mb-4">
              <Banner tone="warn">
                No model published yet — every order on this brand uses the built-in tolerance
                formula.
              </Banner>
            </div>
          )}

          <input
            ref={fileInput}
            type="file"
            accept=".tflite"
            className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0];
              if (file) void upload(file);
            }}
          />
          <div className="flex flex-wrap justify-end gap-2">
            {meta && (
              <Button variant="ghost" onClick={() => void remove()} disabled={busy !== null}>
                {busy === "delete" ? <ButtonSpinner /> : "Remove model"}
              </Button>
            )}
            <Button
              variant="outline"
              onClick={() => fileInput.current?.click()}
              disabled={busy !== null}
            >
              {busy === "upload" ? (
                <>
                  <ButtonSpinner /> Uploading…
                </>
              ) : meta ? (
                "Replace model (.tflite)"
              ) : (
                "Upload model (.tflite)"
              )}
            </Button>
            <Button onClick={onClose}>Done</Button>
          </div>
        </>
      )}
    </Modal>
  );
}

export function BrandsPage() {
  const [brands, setBrands] = useState<BrandSummary[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [busyAction, setBusyAction] = useState<"sync" | "publish" | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [modelBrand, setModelBrand] = useState<BrandSummary | null>(null);

  async function load() {
    setError(null);
    try {
      setBrands(await api.brands());
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load brands.");
    }
  }

  useEffect(() => {
    void load();
  }, []);

  async function sync(b: BrandSummary) {
    setBusyId(b.brandId);
    setBusyAction("sync");
    setNote(null);
    setError(null);
    try {
      const r = await api.sync(b.brandId);
      setNote(
        `${b.name}: synced — ${r.itemsAdded} new, ${r.itemsUpdated} updated, ${r.missingWeights} still need weights.`,
      );
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Sync failed.");
    } finally {
      setBusyId(null);
      setBusyAction(null);
    }
  }

  async function publish(b: BrandSummary) {
    if (
      b.missingWeights > 0 &&
      !(await askConfirm(`${b.name} still has ${b.missingWeights} item(s) without weights. Publish anyway?`))
    )
      return;
    setBusyId(b.brandId);
    setBusyAction("publish");
    setNote(null);
    setError(null);
    try {
      const r = await api.publish(b.brandId);
      setNote(`${b.name}: published version ${r.publishedVersion}.`);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Publish failed.");
    } finally {
      setBusyId(null);
      setBusyAction(null);
    }
  }

  if (error && !brands)
    return (
      <div className="space-y-3">
        <Banner tone="bad">{error}</Banner>
        <Button onClick={() => void load()}>Retry</Button>
      </div>
    );
  if (!brands) return <Spinner />;

  return (
    <div className="animate-fade-up">
      <h1 className="font-display text-2xl text-ink">Brands</h1>
      <p className="mb-6 mt-1 text-sm text-muted">
        Configure item weights per brand, then publish for the stores.
      </p>

      {note && <div className="mb-4"><Banner tone="ok">{note}</Banner></div>}
      {error && <div className="mb-4"><Banner tone="bad">{error}</Banner></div>}

      {brands.length === 0 ? (
        <Banner tone="warn">No brands yet — add rows to the Brands table.</Banner>
      ) : (
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {brands.map((b, i) => (
            <Card
              key={b.brandId}
              hover
              className="animate-fade-up flex flex-col p-5"
              style={{ animationDelay: `${Math.min(i, 8) * 40}ms` }}
            >
              <div className="mb-4 flex items-start justify-between gap-2">
                <div>
                  <div className="text-lg font-extrabold tracking-tight text-ink">{b.name}</div>
                  <div className="font-mono text-xs text-muted">{b.code}</div>
                </div>
                {b.missingWeights > 0 ? (
                  <Badge tone="bad">{b.missingWeights} missing</Badge>
                ) : b.totalItems > 0 ? (
                  <Badge tone="ok">✓ Complete</Badge>
                ) : (
                  <Badge tone="warn">No menu</Badge>
                )}
              </div>

              <Coverage total={b.totalItems} missing={b.missingWeights} />

              <div className="mb-4 mt-3 font-mono text-xs text-muted">
                {b.totalItems} items · published v{b.publishedVersion}
              </div>

              <div className="mt-auto flex flex-wrap gap-2">
                <Link to={`/brands/${b.brandId}/weights`} className="grow">
                  <Button className="w-full">Configure weights</Button>
                </Link>
                <Button variant="outline" onClick={() => void sync(b)} disabled={busyId === b.brandId}>
                  {busyId === b.brandId && busyAction === "sync" ? <ButtonSpinner /> : "Sync"}
                </Button>
                <Button
                  variant="outline"
                  onClick={() => void publish(b)}
                  disabled={busyId === b.brandId || b.totalItems === 0}
                >
                  {busyId === b.brandId && busyAction === "publish" ? <ButtonSpinner /> : "Publish"}
                </Button>
                <Button variant="ghost" onClick={() => setModelBrand(b)} title="AI weight-prediction model">
                  AI model
                </Button>
              </div>
            </Card>
          ))}
        </div>
      )}

      {modelBrand && <ModelModal brand={modelBrand} onClose={() => setModelBrand(null)} />}
    </div>
  );
}
