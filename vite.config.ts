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
    // #484: a signal that changes on every `vite build`, used to gate a
    // stuck-upload retry on "a deploy happened" rather than wall-clock time —
    // see `appVersion.ts#currentAppVersion` and the policy block in
    // `recordingQueue.ts`. `VERCEL_GIT_COMMIT_SHA` is what Vercel sets for
    // both the staging preview and production builds (exactly the deploys
    // that can carry a migration, per CLAUDE.md's release flow); the
    // timestamp fallback still changes on every OTHER invocation of
    // `vite build`, including fastlane's (which runs `npm run build` before
    // `cap sync` — the same bundle ships to the native/watch app).
    "import.meta.env.VITE_BUILD_ID": JSON.stringify(
      process.env.VERCEL_GIT_COMMIT_SHA ?? new Date().toISOString(),
    ),
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
