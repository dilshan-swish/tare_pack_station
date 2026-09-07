import { useEffect, useState } from "react";
import { Modal, Button } from "./ui";

// A themed, in-app replacement for the browser's native window.confirm() —
// that dialog renders as a bare, unstyled "localhost:5173 says" OS prompt
// that doesn't fit the rest of the portal (and can't be restyled at all,
// same limitation as a native <select>'s dropdown panel or <input
// type="date">). This is a singleton "confirm host", mounted once at the
// app root: any component anywhere calls the plain async `askConfirm()`
// function below — no context/provider wiring needed at each call site —
// and gets back a real Promise<boolean>, same call shape as
// `if (!confirm(msg)) return;` just with `await` in front of it.

export interface ConfirmOptions {
  title?: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  /// "danger" renders the confirm button in the destructive red/coral style
  /// (removing something, clearing history) instead of the primary green —
  /// mirrors the app's existing Button `danger` variant, used the same way
  /// a native confirm's OS-default red action button hinted at severity.
  tone?: "default" | "danger";
}

interface PendingConfirm extends ConfirmOptions {
  resolve: (value: boolean) => void;
}

let notify: ((state: PendingConfirm | null) => void) | null = null;

export function askConfirm(options: ConfirmOptions | string): Promise<boolean> {
  const opts: ConfirmOptions = typeof options === "string" ? { message: options } : options;
  return new Promise((resolve) => {
    if (!notify) {
      // Defensive fallback only — ConfirmHost is mounted once at the app
      // root for the app's whole lifetime, so this should never actually
      // run; if it somehow does (e.g. a call fired before mount), falling
      // back to the native dialog keeps the action working rather than
      // silently hanging forever on an unresolved promise.
      resolve(window.confirm(opts.message));
      return;
    }
    notify({ ...opts, resolve });
  });
}

export function ConfirmHost() {
  const [pending, setPending] = useState<PendingConfirm | null>(null);

  useEffect(() => {
    notify = setPending;
    return () => {
      notify = null;
    };
  }, []);

  function respond(value: boolean) {
    pending?.resolve(value);
    setPending(null);
  }

  return (
    <Modal open={!!pending} onClose={() => respond(false)} title={pending?.title ?? "Are you sure?"}>
      {pending && (
        <>
          <p className="text-sm leading-relaxed text-ink/80">{pending.message}</p>
          <div className="mt-5 flex flex-wrap justify-end gap-2">
            <Button variant="ghost" onClick={() => respond(false)}>
              {pending.cancelLabel ?? "Cancel"}
            </Button>
            <Button
              variant={pending.tone === "danger" ? "danger" : "primary"}
              onClick={() => respond(true)}
              autoFocus
            >
              {pending.confirmLabel ?? "Confirm"}
            </Button>
          </div>
        </>
      )}
    </Modal>
  );
}
