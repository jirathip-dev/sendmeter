import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import ErrorBoundary from "./components/ErrorBoundary";
import { initDeepLinks } from "./lib/deepLinks";
import { installTapHaptics } from "./lib/haptics";
import { initMonitoring } from "./lib/monitoring";
import { initializeTheme } from "./lib/theme";
import "./index.css";

// Apply the stored theme before React mounts and before the first app paint.
// This also sets browser/PWA theme-color metas, so explicit Light/Dark choices
// do not briefly inherit the operating system's chrome.
initializeTheme();

// Error monitoring (#227) — first, so a crash in anything below is reported.
// No-op unless the build carries a Sentry DSN.
initMonitoring();

// Handle auth email links that reopen the native app via its custom scheme.
initDeepLinks();

// App-wide tap feedback (#171) — one delegated listener set, outside React so
// it covers every surface including the portalled fullscreens. No-op on web.
installTapHaptics();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>,
);
