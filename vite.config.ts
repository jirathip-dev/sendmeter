import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";
import { resolveDeployEnv } from "./src/lib/deployEnv";

export default defineConfig({
  // Sentry's `environment` tag (#239). `MODE` is `production` for every build
  // here (plain `vite build`, no `--mode`), so preview deploys and TestFlight
  // would otherwise be indistinguishable from real production traffic.
  // `VERCEL_ENV` is the true signal but isn't `VITE_`-prefixed, so Vite won't
  // forward it — inline it. Resolution order lives in a pure, tested helper.
  define: {
    "import.meta.env.VITE_DEPLOY_ENV": JSON.stringify(resolveDeployEnv(process.env)),
  },
  plugins: [
    react(),
    VitePWA({
      registerType: "autoUpdate",
      manifest: false,
      includeAssets: ["icon-512.png", "splash-cave-background.webp", "splash-kangaroo.webp"],
    }),
  ],
  test: {
    // .claude holds agent worktrees (full repo copies) — without this,
    // `vitest run` picks up their test files too and double-counts the suite.
    exclude: ["**/node_modules/**", "**/dist/**", ".claude/**"],
  },
});
