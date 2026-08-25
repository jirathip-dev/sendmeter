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
      // Keep the documented public manifest authoritative. Vite copies this
      // exact file into dist; the PWA plugin only generates the service worker.
      manifest: false,
      includeAssets: ["icon-512.png", "splash-cave-background.webp", "splash-kangaroo.webp"],
      // Default globPatterns is js/css/html only — without woff2 the
      // self-hosted Inter file (#505) would be the one shell asset missing
      // from the offline precache, and without txt the service worker's
      // navigation fallback would serve the APP SHELL for a direct link to
      // /fonts/OFL.txt (any non-precached navigation falls through to
      // index.html — there is no denylist). This list is an allow-list: a
      // new asset type emitted into dist/ is silently absent from the
      // precache — and, if it is ever a link target, shell-hijacked — until
      // its extension is added here. That exact trap caught the licence
      // file one commit after this comment was first written.
      workbox: { globPatterns: ["**/*.{js,css,html,txt,woff2}"] },
    }),
  ],
  test: {
    // .claude holds agent worktrees (full repo copies) — without this,
    // `vitest run` picks up their test files too and double-counts the suite.
    // mcp/ is a separate package (own lockfile + own vitest) — its tests
    // need @modelcontextprotocol/sdk, which root `npm ci` never installs
    // (root has no workspaces field), so root vitest must not collect them;
    // the mcp job in .github/workflows/ci.yml runs the package's own gates.
    exclude: ["**/node_modules/**", "**/dist/**", ".claude/**", "mcp/**"],
    // #489: a hang detector, NOT a performance budget. Vitest fails any test
    // whose wall-clock elapsed exceeds this — including a synchronous test,
    // checked when it returns — so the default 5s acted as an accidental
    // wall-clock assertion on every test in the suite. On this machine
    // wall-clock is not a proxy for cost: several agents plus xcodebuilds
    // run concurrently (1-minute load 65–190 observed), and a starved worker
    // can stall >5s mid-test, timing out sub-500ms tests. Measured under a
    // SIGSTOP duty cycle standing in for scheduler starvation (implementer,
    // then reproduced independently in the #489 review): at 5s, 6/6 runs
    // failed with the reported "Test timed out in 5000ms" signature; 10s
    // failed 3/5; 15s and 30s failed 0/5+. The worst legitimate test in the
    // suite is ~1.1s, so 15s keeps ~13x headroom with the same measured
    // starvation immunity as 30s at half the cost of a genuine hang
    // (infinite loop / unresolved promise — the only thing this exists to
    // catch). Performance is asserted as load-insensitive WORK COUNTS, never
    // elapsed time: force-curve.test.ts pins the grid-search invocation
    // count (1 + bootstrapSamples, the dominant cost — the guard the old 5s
    // provided only by accident) alongside `meanMaxEvaluations` (signal
    // preprocessing; invariant to bootstrapSamples, so it alone was never a
    // cost guard). Don't lower this back to "catch slow tests" — that
    // reintroduces the flake class.
    testTimeout: 15_000,
    // Same reasoning: the vitest default (10s) is one more wall-clock budget
    // exposed to the same starvation, just with fewer chances to trip
    // (hooks here are trivial). Kept consistent with testTimeout.
    hookTimeout: 15_000,
    coverage: {
      provider: "v8",
      reporter: ["text", "text-summary", "json", "html", "lcov"],
      reportsDirectory: "coverage",
      // This gate covers the dependency-free logic seam, not React components,
      // hooks, Supabase repositories, or platform/build adapters. The latter
      // need browser/device integration tests and would make this host-only
      // gate measure wiring rather than the tested calculations and policies.
      include: ["src/lib/**/*.ts"],
      exclude: [
        "**/*.test.ts",
        "src/lib/repo/**",
        "src/lib/supabase.ts",
        "src/lib/appVersion.ts",
        "src/lib/appleAuth.ts",
        "src/lib/authEventStore.ts",
        "src/lib/authRedirect.ts",
        "src/lib/deepLinks.ts",
        "src/lib/devAuth.ts",
        "src/lib/forceConnection.ts",
        "src/lib/forceLatency.ts",
        "src/lib/forcePresetStorage.ts",
        "src/lib/foregroundSignals.ts",
        "src/lib/healthSync.ts",
        "src/lib/liveActivity.ts",
        "src/lib/monitoring.ts",
        "src/lib/passkeys.ts",
        "src/lib/pendingRecording.ts",
        "src/lib/recordingDb.ts",
        "src/lib/signOut.ts",
        "src/lib/weather.ts",
        "src/lib/watchAuthRelay.ts",
        "src/lib/dynamometer/contract.ts",
        "src/lib/dynamometer/index.ts",
        "src/lib/dynamometer/tindeq.ts",
      ],
      thresholds: {
        lines: 95,
        functions: 93,
        // Branches/statements remain visible in the report but are not floors
        // yet; this issue establishes only the requested line/function gate.
        branches: 0,
        statements: 0,
      },
    },
  },
});
