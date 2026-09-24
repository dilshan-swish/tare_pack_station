import { Component, useEffect, type ErrorInfo, type ReactNode } from "react";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { SessionProvider, useSession } from "./state/session";
import { WeighingProvider } from "./state/weighing";
import { ToastProvider } from "./state/toast";
import { TopBar } from "./components/TopBar";
import { Button, FullScreenMessage, Spinner } from "./components/ui";
import { LoginScreen } from "./screens/LoginScreen";
import { OrdersScreen } from "./screens/OrdersScreen";
import { OrderScreen } from "./screens/OrderScreen";
import { HistoryScreen } from "./screens/HistoryScreen";

export default function App() {
  return (
    <ErrorBoundary>
      <ToastProvider>
        <SessionProvider>
          <Gate />
        </SessionProvider>
      </ToastProvider>
    </ErrorBoundary>
  );
}

function Gate() {
  const { status, signOut, retry } = useSession();
  switch (status.kind) {
    case "config":
      return <FullScreenMessage title="Not set up yet">{status.message}</FullScreenMessage>;
    case "loading":
      return (
        <div className="flex min-h-dvh items-center justify-center text-cream">
          <Spinner className="h-9 w-9" />
        </div>
      );
    case "signed_out":
      return <LoginScreen notice={status.notice} />;
    case "no_branch":
      return (
        <FullScreenMessage title="No branch linked">
          <p>{status.message}</p>
          <Button variant="cream" onClick={() => void signOut()}>
            Sign out
          </Button>
        </FullScreenMessage>
      );
    case "error":
      return (
        <FullScreenMessage title="Couldn't start">
          <p>{status.message}</p>
          <div className="flex justify-center gap-3">
            <Button onClick={retry}>Try again</Button>
            <Button variant="cream" onClick={() => void signOut()}>
              Sign out
            </Button>
          </div>
        </FullScreenMessage>
      );
    case "ready":
      return (
        <WeighingProvider>
          <KeepAwake />
          <BrowserRouter>
            <TopBar />
            <main>
              <Routes>
                <Route path="/" element={<OrdersScreen />} />
                <Route path="/order/:orderId" element={<OrderScreen />} />
                <Route path="/history" element={<HistoryScreen />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            </main>
          </BrowserRouter>
        </WeighingProvider>
      );
  }
}

/** Stops a counter tablet from dimming/locking mid-shift (where supported). */
function KeepAwake() {
  useEffect(() => {
    type Sentinel = { release: () => Promise<void> };
    const wl = (navigator as Navigator & { wakeLock?: { request: (t: "screen") => Promise<Sentinel> } }).wakeLock;
    if (!wl) return;
    let sentinel: Sentinel | null = null;
    const acquire = async () => {
      try {
        if (document.visibilityState === "visible") sentinel = await wl.request("screen");
      } catch {
        // Denied (battery saver, unsupported) — harmless.
      }
    };
    void acquire();
    document.addEventListener("visibilitychange", acquire);
    return () => {
      document.removeEventListener("visibilitychange", acquire);
      void sentinel?.release().catch(() => undefined);
    };
  }, []);
  return null;
}

class ErrorBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("App crashed", error, info.componentStack);
  }
  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <FullScreenMessage title="Something went wrong">
        <p>Unsent weights are kept on this device and will sync after reloading.</p>
        <Button onClick={() => window.location.reload()}>Reload</Button>
      </FullScreenMessage>
    );
  }
}
