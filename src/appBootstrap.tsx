import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import ErrorBoundary from "./components/ErrorBoundary";
import { initDeepLinks } from "./lib/deepLinks";
import { installTapHaptics } from "./lib/haptics";
import { initMonitoring } from "./lib/monitoring";

// Error monitoring (#227) — first, so a crash in anything below is reported.
// No-op unless the build carries a Sentry DSN.
initMonitoring();

// Handle auth email links that reopen the native app via its custom scheme.
initDeepLinks();

// App-wide tap feedback (#171) — one delegated listener set, outside React so
// it covers every surface including the portalled fullscreens. No-op on web.
installTapHaptics();

/** Mount the unchanged production tree after its bootstrap side effects run. */
export function mountProductionApp(root: HTMLElement): void {
  createRoot(root).render(
    <StrictMode>
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </StrictMode>,
  );
}
