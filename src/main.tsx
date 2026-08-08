import { initializeTheme } from "./lib/theme";
import "./index.css";

// Apply the stored theme before either the DEV lab or production module loads.
// The lab has its own controller for interactive switching; production keeps
// this original pre-paint bootstrap ahead of App/auth/repo evaluation.
initializeTheme();

const root = document.getElementById("root");

if (!root) {
  throw new Error("Sendmeter root element is missing");
}

// Keep this guard compile-time visible to Vite. In a production build the
// whole DEV branch, including the lab's dynamic import, is removed before
// Rollup creates chunks. That keeps the app bootstrap below the only path
// that can evaluate auth, repo, Supabase, or native-facing modules.
if (import.meta.env.DEV && new URLSearchParams(window.location.search).has("ui-qa")) {
  void import("./dev/uiQa").then(({ mountUiQa }) => mountUiQa(root));
} else {
  void import("./appBootstrap").then(({ mountProductionApp }) =>
    mountProductionApp(root),
  );
}
