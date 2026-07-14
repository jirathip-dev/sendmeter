# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

**Sendmeter** — a climbing training tracker. Web app (React 19 + Vite 8 +
TypeScript) wrapped with **Capacitor 8** into an iOS app, plus a native
**watchOS companion** target, backed by **Supabase** (auth + Postgres + realtime).
It's a PWA (`vite-plugin-pwa`). Core value is numbers: a daily recovery/readiness
score (from HRV, resting HR, sleep, weight) and finger-strength force curves from
a **Tindeq Progressor** strain gauge over Bluetooth LE.

> Note: the app was renamed from "Send Log" → **Sendmeter** (App Store name was
> taken). The rename is display-name only — internal identifiers still say
> `sendlog` / `SendLog` (see "Names" below).

## Commands

```bash
npm run dev        # vite dev server (port 5173)
npm run build      # tsc --noEmit && vite build
npm run typecheck  # tsc --noEmit
npm run lint       # eslint .
npm run sync       # cap sync ios  (copies dist/ into the iOS app, regenerates CapApp-SPM)
```

Web tests use **Vitest** (`npm test` = `vitest run`) — pure logic only
(metrics/ACWR, force-curve, dates). The **Swift** side has tests too:
- `cd native-plugins/sendlog-health-core && swift test` — pure readiness/ACWR math, runs on macOS.
- `xcodebuild test -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -only-testing:SendLogWatchTests -destination "platform=watchOS Simulator,..."` — watch logic (attempt detection, RPE model, Tindeq protocol, dates).

Always run `npm run typecheck && npm run lint && npm test && npm run build` after web changes.

## Architecture

- **`src/`** — the React app. `lib/` = data/logic (repo.ts = all Supabase queries,
  metrics.ts = ACWR/EWMA, force-curve.ts = critical-force fit, healthSync.ts +
  watchAuthRelay.ts = native bridges). `components/` = UI. `hooks/` = data hooks.
- **`ios/App/App.xcodeproj`** — two targets: the Capacitor iOS **App** and the
  **SendLogWatch Watch App** companion (SwiftUI; workout/attempt tracking, force
  gauge, readiness display). Plus a `SendLogWatchTests` unit-test target.
  - The watch target is a `PBXFileSystemSynchronizedRootGroup`: files are included
    by **filesystem presence**, so add/remove Swift files by touching the dir, not
    the pbxproj. The test target is a normal target (edit pbxproj to add files there
    — use the `xcodeproj` Ruby gem, available via cocoapods: `GEM_PATH=/opt/homebrew/Cellar/cocoapods/*/libexec /opt/homebrew/opt/ruby/bin/ruby`).
- **`native-plugins/`** — local Swift/Capacitor plugins (npm `file:` deps):
  - `sendlog-health` + `sendlog-health-core` — HealthKit read on the **iPhone**,
    readiness compute, `health_metrics` upsert, background delivery. `-core` is
    pure Foundation (unit-tested); the plugin adds HealthKit + Supabase.
  - `sendlog-auth-bridge` — relays the Supabase session from the WebView to the
    watch over WatchConnectivity.
- **`supabase/migrations/`** — 14 migrations. Tables: `sessions`, `user_settings`,
  `phase_periods`, `tindeq_recordings`, `climb_workouts`, `climb_attempts`,
  `health_metrics`. RLS scopes everything to `auth.uid()`; realtime publishes the
  watch-writable tables.

## Non-obvious things that will bite you

- **iOS min is 16.0**, not 15. The Supabase Swift SDK floors at 16; Capacitor
  derives `CapApp-SPM`'s platform from the *first* `IPHONEOS_DEPLOYMENT_TARGET` in
  the pbxproj (the **project-level** one), so it must be 16 for `cap sync` to
  regenerate SPM correctly.
- **Dates must be Gregorian.** A Thai-region device defaults `Calendar.current` to
  the Buddhist calendar (year + 543), which once corrupted every stored date. Use
  `Calendar.gregorianLocal` / `Date.localDateString` (Swift) and the web
  `src/lib/dates.ts`. There's a DB `check` constraint bounding dates as a backstop.
- **Health ingestion is iPhone-only.** The iPhone is the *sole* writer of
  `health_metrics` (it sees the merged HealthKit store incl. third-party wearables).
  The watch only *reads* the computed score back for display — it no longer reads
  HealthKit or writes health rows. Don't reintroduce watch-side health writes.
- **One Supabase session, three clients — only supabase-js refreshes it.** The web
  (supabase-js), the watch, and the iPhone health plugin all share the user's
  session via relays. The watch + plugin clients set `autoRefreshToken: false` and
  only *consume* tokens re-relayed on every auth event + app foreground (the
  `useAuth` visibilitychange listener). With refresh-token rotation on, a second
  client refreshing the shared token trips Supabase's replay detection and revokes
  the whole session family — writes then fail RLS as anon. Don't re-enable
  auto-refresh on the watch/plugin clients.
- **Migrations aren't auto-applied.** Files in `supabase/migrations/` are just SQL
  on disk — apply them to the remote DB via the Supabase MCP (`apply_migration`) or
  the CLI, or the schema drifts from the code. (The `health_metrics` delete policy +
  date-sanity constraints sat unapplied for a while: with no DELETE policy, a delete
  silently matches zero rows, so "Clear health data" looked broken while succeeding.)
- **Tindeq capture asymmetry (intentional).** The in-app gauge requires a **tag
  before Start** and **auto-saves on Stop** (with an Undo); the watch Force Gauge is
  a stripped one-tap page that **always saves untagged** on Stop. Don't restore the
  old discard/save prompt or the watch tag/side/tare controls.
- **`cap sync` before archiving.** The iOS archive bundles `ios/App/App/public`,
  which only updates on `npm run build && npm run sync`. Forgetting this ships stale UI.
- **`CapApp-SPM/Package.swift` is Capacitor-managed** — never hand-edit; it's
  regenerated by `cap sync`.
- **Supabase URL + anon key are committed** (publishable key; RLS is the security
  boundary) — in `src/lib/supabase.ts`, the plugins, and the watch's SupabaseConfig.

## Names (display vs. internal — keep the split)

- **User-facing name is "Sendmeter"** (topbar, login, `CFBundleDisplayName`,
  Capacitor `appName`, PWA manifest, privacy page). The App Store *display* name is
  independent of the bundle ID.
- **Internal identifiers stay `sendlog`/`SendLog`** and should NOT be renamed:
  bundle IDs `com.jirathip.sendlog*`, Xcode target/scheme names (`SendLogWatch Watch App`),
  plugin modules (`SendLogHealth`, `SendLogAuthBridge`), Swift file/dir names.

## Deploy (TestFlight + Vercel)

- **`fastlane beta` must run from an interactive Terminal.** The App Store export
  needs an **Apple Distribution certificate + a signed-in Xcode account** in the
  login keychain; the ASC API key only covers build-number lookup + the upload, not
  the export signing cert. An automated/spawned shell that lacks the cert fails with
  `exportArchive No Accounts` / `No signing certificate "iOS Distribution" found`.
  Also run it with `LANG=en_US.UTF-8` — in a `C`-locale shell fastlane's xcpretty
  formatter crashes on non-ASCII output. Signing troubleshooting: `ios/COMPANION_SETUP.md`.
- **Commit as `jirathip.ku@gmail.com`** (`git config user.email`). Pushing `main`
  triggers the Vercel web deploy, which **rejects commits from unrecognized authors**
  — a machine-default `user@host` email silently blocks it. Redeploy the current
  HEAD from the Vercel dashboard if it was pushed under the wrong identity.

## Working style here

- This is a solo project moving fast. Match the surrounding code's style.
- Commit only when asked; branch off `main` first. The iPhone health-sync + rename
  work (`feature/iphone-health-sync`) is **merged to `main`**; on-device TestFlight
  verification of the HealthKit runtime + watch UX is still pending.
- Backlog + planning live in Notion (the "Sendmeter" page → Backlog database) and
  in `~/.claude/plans/`. Native/HealthKit runtime behavior can't be verified in the
  simulator — flag device-only work rather than claiming it verified.
- App Store submission state is tracked in `docs/app-store-checklist.md` and
  `ios/COMPANION_SETUP.md` (signing troubleshooting + the health device-test checklist).
