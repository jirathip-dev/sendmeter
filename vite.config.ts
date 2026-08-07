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
    // #489: a hang detector, NOT a performance budget. Vitest fails any test
    // whose wall-clock elapsed exceeds this — including a synchronous test,
    // checked when it returns — so the default 5s acted as an accidental
    // wall-clock assertion on every test in the suite. On this machine
    // wall-clock is not a proxy for cost: several agents plus xcodebuilds
    // run concurrently (1-minute load 65–133 observed), and a starved worker
    // can stall >5s mid-test, timing out sub-500ms tests (reproduced: 2 of 7
    // runs failed exactly like the #489 report under a SIGSTOP duty cycle
    // standing in for scheduler starvation). Performance is asserted where
    // it belongs — as load-insensitive work counts, e.g. force-curve.test.ts
    // `meanMaxEvaluations` — never as elapsed time. 30s still fails a genuine
    // hang (infinite loop / unresolved promise) promptly; don't lower it back
    // to "catch slow tests" — that reintroduces the flake class.
    testTimeout: 30_000,
  },
});
