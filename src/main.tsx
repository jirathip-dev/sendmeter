import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { initDeepLinks } from "./lib/deepLinks";
import "./index.css";

// Handle auth email links that reopen the native app via its custom scheme.
initDeepLinks();

// Apply the stored theme before first paint; otherwise follow the system.
const storedTheme = localStorage.getItem("theme");
if (storedTheme === "light" || storedTheme === "dark") {
  document.documentElement.dataset.theme = storedTheme;
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
