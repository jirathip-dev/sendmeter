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

- **Four tabs, one job each** (ViewIds in `src/types.ts`; labels in
  `src/constants.ts` — the "tindeq" ViewId displays as **Force**):
  - **Home** (`Dashboard.tsx`) = status: phase banner, ACWR + full load detail
    inline (weekly bars, daily heatmap), readiness. No logging here.
  - **Workout** (`WorkoutView.tsx`) = do: live watch mirror (`useLiveWorkout`,
    dedicated realtime channel), phone-only fullscreen timer
    (`PhoneWorkoutFullscreen`, reducer in `lib/phoneWorkout.ts` persisted to
    localStorage), and the manual + Log Session sheet.
  - **Force** (`ForceView.tsx`) = measure: global Exercise&Side card drives
    everything below it (recording labels, zone targets, trend, curve);
    `ForceFullscreen` auto-opens on connect and runs guided protocols.
  - **History** (`HistoryView.tsx`) = review: the single combined timeline —
    sessions (workouts expand to HR chart, tindeq sessions to recording
    charts) + loose recordings interleaved with multi-select → create session.
- **Guided protocol engine** — `src/lib/protocol.ts` (pure, vitest-covered):
  `buildTimeline(preset, {switchS, prepareS})` expands a preset into flat
  timed segments (prepare/hold/switch/rest/setRest, alternating L/R pairs
  with auto-extended rests); the fullscreen countdown AND the per-rep
  recorder in ForceView walk the same segments. Each hold saves as its own
  recording (sliced from `samplesRef`) with the correct side.
  `presetTargetKg` resolves %-of-PR targets with per-set ramps.
- **`src/`** — the React app. `lib/` = data/logic (repo.ts = all Supabase queries,
  metrics.ts = ACWR/EWMA + exported `ewma()`, force-curve.ts = critical-force
  fit + `ZONE_PROTOCOLS`, protocol.ts = guided timelines, healthSync.ts +
  watchAuthRelay.ts = native bridges). `components/` = UI (`InfoDot.tsx` =
  the "?" explainer sheets). `hooks/` = data hooks.
- **`ios/App/App.xcodeproj`** — three product targets: the Capacitor iOS **App**,
  the **SendLogWatch Watch App** companion (SwiftUI; workout/attempt tracking,
  force gauge, readiness display), and **SendmeterWidgets** (WidgetKit app
  extension = the Live Activities). Plus a `SendLogWatchTests` unit-test target.
  - The watch AND widget targets are `PBXFileSystemSynchronizedRootGroup`s: files
    are included by **filesystem presence**, so add/remove Swift files by touching
    the dir, not the pbxproj. The test target is a normal target (edit pbxproj to
    add files there — use the `xcodeproj` Ruby gem, available via cocoapods:
    `GEM_PATH=/opt/homebrew/Cellar/cocoapods/*/libexec /opt/homebrew/opt/ruby/bin/ruby`).
    The widget target itself was created by `scripts/add_widget_target.rb` (same
    gem); re-running is a no-op. `SendmeterWidgets-Info.plist` sits *outside* the
    synced `SendmeterWidgets/` dir (watch-target convention) so it isn't compiled.
  - **Live Activities need iOS 17** (interactive `Button(intent:)`); the widget
    target is min iOS 17 while the App stays 16.0 (the appex is simply inert
    below 17). `LiveActivityIntent.perform()` runs in the **App process**, so the
    intent implementations live in `ios/App/App/LiveActivityIntents.swift` (App
    target) and the widget only has no-op stubs so `Button(intent:)` compiles —
    no App Group is needed (the pending-action queue is `UserDefaults.standard`,
    shared because it's the same process).
- **`native-plugins/`** — local Swift/Capacitor plugins (npm `file:` deps):
  - `sendlog-health` + `sendlog-health-core` — HealthKit read on the **iPhone**,
    readiness compute, `health_metrics` upsert, background delivery. `-core` is
    pure Foundation (unit-tested); the plugin adds HealthKit + Supabase.
  - `sendlog-auth-bridge` — relays the Supabase session from the WebView to the
    watch over WatchConnectivity; also **receives** watch→phone live-workout
    beats (`didReceiveMessage`) and forwards them to the WebView via
    `notifyListeners("liveWorkout")` (the Bluetooth-fast mirror path — works even
    while the WebView is suspended).
  - `sendlog-live-activity` — lock-screen **Live Activities** (ActivityKit) for
    the phone workout (CLIMBING/RESTING timers + tappable Boulder/Stop) and the
    Tindeq guided protocol (per-segment countdown). `LiveActivityManager` owns
    activity start/update/end, the pending-action queue, the rest-over
    `UNUserNotificationCenter` alert, and the Tindeq segment stepper. Timers
    render natively via `Text(timerInterval:)` (no per-tick updates). Lock-screen
    Boulder/Stop → App-process intents queue `{type,at}` into
    `UserDefaults.standard`; `src/hooks/usePhoneWorkout.ts` drains + replays them
    into the reducer (its phase guards make replay idempotent) on mount /
    `appStateChange` / the plugin's `liveActivityAction` event.
    `ActivityModels.swift` is **duplicated** (widget copy + plugin copy, KEEP-IN-
    SYNC comment) — ActivityKit matches by type name + Codable shape, so drift
    makes the card render as a placeholder. iOS-17-gated; device-only to verify.
  - `sendlog-passkey` — runs the WebAuthn passkey ceremony natively via
    `ASAuthorization` (Face ID). Needed because the WebView origin is
    `capacitor://localhost`, which the browser WebAuthn API won't accept for the
    `sendmeter.app` RP ID (and Capacitor rejects `iosScheme: "https"` — WKWebView
    reserves that scheme — so you can't give the WebView a real https origin).
    `src/lib/passkeys.ts` branches: web uses supabase-js's browser flow; native
    drives the **two-step** Supabase flow itself (`passkey.startRegistration` →
    plugin `register` → `passkey.verifyRegistration`, and the auth equivalent),
    passing all binary fields as base64url. Relies on the already-configured
    `webcredentials:sendmeter.app` associated domain + AASA. Device-only to verify.
- **`supabase/migrations/`** — 18 migrations. Tables: `sessions` (incl.
  `workout_source` = immutable auto/phone badge that survives type edits),
  `user_settings`, `phase_periods`, `tindeq_recordings`, `tindeq_presets`
  (hold/reps/sets/rests + target kg or %-of-PR + per-set % step + alternate
  sides), `climb_workouts`/`climb_attempts` (both with `source` provenance),
  `health_metrics`, `live_workouts` (one row per user, watch-heartbeat for
  the live workout mirror). RLS scopes everything to `auth.uid()`; realtime
  publishes the watch-writable tables + `live_workouts`.

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
  - The refresh trap is **indirect too**: `receivedApplicationContext` is
    persisted, so on a cold watch launch the last relayed payload may be hours
    old — `auth.setSession` with an expired access token *refreshes* with the
    (long-rotated) relayed refresh token → family revoked → watch logged out
    (this bit after a TestFlight update). AuthManager therefore ignores relays
    whose `expiresAt` is past and reads the Keychain fallback via the
    non-refreshing `auth.currentSession` only. Keep both guards.
- **Migrations aren't auto-applied.** Files in `supabase/migrations/` are just SQL
  on disk — apply them to the remote DB via the Supabase MCP (`apply_migration`) or
  the CLI, or the schema drifts from the code. (The `health_metrics` delete policy +
  date-sanity constraints sat unapplied for a while: with no DELETE policy, a delete
  silently matches zero rows, so "Clear health data" looked broken while succeeding.)
- **Tindeq capture flow (intentional).** Both the in-app gauge and the watch set
  **tag + side before Start** and **auto-save on Stop** — no post-stop discard/save
  prompt (in-app has an Undo; the watch hides tag/side/session controls *while
  measuring* so the live gauge fits one screen). End-session logs the **actual
  wall-clock duration** (read-only); only RPE is asked. Don't reintroduce the
  discard/save prompt or an editable duration.
- **Recording samples store `t` in milliseconds.** `tindeq_recordings.samples`
  time is ms — charts must divide by 1000 to show seconds (a mislabeled axis once
  showed "25152.0s").
- **`?fake-tindeq`** query param puts the web Force view in fake mode (simulated
  BLE + force stream) — the only way to exercise the connect→measure→save flow in
  a browser (real Web Bluetooth needs a device).
- **Never add `live_workouts` to `WATCHED_TABLES`** in
  `RealtimeVersionProvider.tsx` — the watch heartbeats it every ~5s, which
  would refetch every card in the app every 5s. The Workout tab subscribes to
  it on its own payload-reading channel (`useLiveWorkout`).
- **React-compiler lint is strict**: no `Date.now()`/impure calls in render
  (hold `now` in state ticked by an interval), no synchronous `setState` in
  effect bodies (derive instead, or write state only inside async callbacks —
  see the curve auto-compute in `ForceView` for the pattern), manual
  `useMemo` that the compiler can't preserve gets rejected (just compute).
- **Guided protocols save PER REP** — during a protocol, `handleStop` and the
  autosave effect in `ForceView` slice each hold out of the live buffer as
  its own recording (side per rep when alternating); the whole-session
  recording is only saved for free holds. Don't re-add a full-session insert
  to the protocol path or every rep gets double-counted.
- **InfoDot must swallow clicks** — it renders inside tappable cards
  (ReadinessCard opens its detail sheet on card click); the
  `display:contents` wrapper with `stopPropagation` is load-bearing, as is
  the `textTransform: none` reset (the dot lives inside uppercase eyebrow
  labels).
- **Design tokens live in `index.css`**: semantic colors are deliberately
  desaturated (no stock iOS neons), `--iris` is the shared iridescent
  hairline gradient (cards get it via a masked `::before` ring — suppressed
  inside `.modal-sheet`), `--shadow-card` is layered + has an inset top
  highlight, and floating chrome (`.bottom-nav`, `.account-fab`,
  `.glass-bar`) shares the translucent blur-glass recipe.
- **localStorage keys** are prefixed `sendmeter:` — `phone-workout` (resumable
  workout state machine), `rest-target-s`, `gauge-prepare`, `passkey-prompt`,
  `theme`.
- **Chrome animates transform/opacity on the compositor**, so `getComputedStyle`
  returns the *base* value mid-animation — you can't measure a ripple's scale or a
  hidden bar's transform from JS in the browser tools; verify animations visually
  (screenshot) instead of by reading computed style.
- **`.card + .card` margin leaks into grid cells.** The stacked-card sibling rule
  (`margin-top: 10px`) makes the 2nd card in a `.grid-2` shorter than its
  stretched row; `.grid-2 > .card + .card { margin-top: 0 }` fixes equal heights.
- **Auto-hiding chrome must overlay, not flex.** The floating header/nav are
  `position: absolute` with the scroll area padded to clear them — translating a
  flex-reserved bar off-screen leaves a blank strip. See `DESIGN.md` → Floating
  glass chrome for the shell model.
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

- **`fastlane beta` runs fully headless via the ASC API key** — `cd` to repo root
  (or `ios/`) and run `LANG=en_US.UTF-8 fastlane beta`; it works from a
  spawned/non-interactive shell, no signed-in Xcode account required. The lane
  (`fastlane/Fastfile`) does everything: `npm run build && cap sync ios`, then
  `get_certificates` (installs/creates the Apple Distribution cert via the API key),
  `get_provisioning_profile force:true` for the app + `.watchkitapp` + `.widgets`
  (regenerated so they carry the current cert; the lane first creates the
  `.widgets` App ID via `Spaceship::ConnectAPI::BundleId.create` since sigh won't),
  `latest_testflight_build_number + 1` (so **never hand-bump
  `CURRENT_PROJECT_VERSION`** — the lane injects it via `xcargs` at archive time
  into app + watch + widget), then `build_app` with **manual** signing +
  `-allowProvisioningUpdates` (the auth-key flags go in `xcargs` only, not
  `export_xcargs`), then `upload_to_testflight`. Config lives in `fastlane/.env`
  (`ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH`) + `fastlane/asc_api_key.p8`
  (git-ignored) — fastlane auto-loads `.env`.
  - **Two hard requirements:** (1) the Apple Distribution cert must be installable —
    `get_certificates` reuses it if already in the login keychain, else creates it
    via the API key (a key with Admin/App Manager access); (2) `LANG=en_US.UTF-8`,
    or in a `C`-locale shell fastlane's xcpretty formatter crashes on non-ASCII output.
  - The old "must run from an interactive Terminal / `exportArchive No Accounts`"
    failure predates this API-key rewrite — that was manual/automatic-signing export
    needing a signed-in Xcode account. The current lane sidesteps it. Deeper signing
    troubleshooting still lives in `ios/COMPANION_SETUP.md`.
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
