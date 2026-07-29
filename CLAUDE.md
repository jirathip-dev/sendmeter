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
npm run dev:local  # DEFAULT dev loop: local Supabase stack (Docker) + vite (port 5173)
npm run dev        # vite against the HOSTED (production) Supabase — only when real data is needed
npm run build      # tsc --noEmit && vite build
npm run typecheck  # tsc --noEmit
npm run lint       # eslint .
npm run sync       # cap sync ios  (copies dist/ into the iOS app, regenerates CapApp-SPM)
```

Web tests use **Vitest** (`npm test` = `vitest run`) — pure logic, tests live
alongside each module (`*.test.ts` in `src/lib` and `src/hooks`). The **Swift** side has tests too:
- `cd native-plugins/sendlog-health-core && swift test` — pure readiness/ACWR math, runs on macOS.
- `cd ios/App/SendLogWatchCore && swift test` — watch pure logic (attempt
  detection, RPE model, Tindeq protocol, ACWR, dates). Runs on the host, no
  simulator. The same files are still compiled into the Xcode test target, so
  `xcodebuild test -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App"
  -only-testing:SendLogWatchTests -destination "platform=watchOS Simulator,..."`
  also runs them locally; in CI the `package-tests` job in `ios-ci.yml` runs
  the same suite on Linux (`swift:6.3` container, #199) and the macOS `swift`
  job is build-only as a result — the Xcode target stays for local runs.

Always run `npm run typecheck && npm run lint && npm test && npm run build` after web changes.

## Local dev environment (issue #95)

**Default to this for all web work** — develop and test against the local stack;
only touch the hosted project when a change specifically needs real data (and
prefer read-only poking there). `npm run dev:local` is the one command: it
starts a **local Supabase stack** (Docker; CLI is a devDependency, so
`npx supabase …` works), writes `.env.development.local` pointing the dev server
at it, and runs vite. Plain `npm run dev` hits the **hosted (production)
project** unless that file exists — delete it to switch back. The file is
dev-mode only: `npm run build` / fastlane / Vercel never read it (verified — the
prod bundle keeps the hosted URL). Note vite reads env files **at startup**: a
dev server started before the file existed keeps serving the hosted config until
restarted. A login that rejects `dev@sendmeter.test` is the tell that the tab is
on the hosted project.

- **Login:** `dev@sendmeter.test` / `devpassword` (use the password toggle on
  the login screen; magic-link emails land in Mailpit at `127.0.0.1:54324`).
- **Seed:** `supabase/seed.sql` — the test user plus ~6 weeks of sessions,
  35 days of health metrics, a watch workout with attempts, and Tindeq
  recordings, all relative to `current_date`. Local-only; never runs remotely.
  It also re-grants table access to the API roles — the current local postgres
  image ships hardened default privileges (no auto-grants on new tables), while
  the hosted project predates that and has them. Without the grants every
  PostgREST query fails `permission denied` locally.
- **Lifecycle:** `npm run db:reset` re-applies all migrations + seed (data is
  disposable); `db:stop` shuts the stack down; `db:status` prints URLs/keys.
  Studio: `127.0.0.1:54323`. Test a new migration here before applying it
  to the remote DB.
- BLE still needs `?fake-tindeq`; native/watch/HealthKit stay on the hosted
  project (their Supabase config is compiled in) — this environment is for the
  web app.

### iOS / watch testing ladder

Work down this ladder — each rung is cheaper than the next, so push logic up it:

1. **Pure logic → unit tests, no simulator.** Readiness/ACWR math lives in
   `sendlog-health-core` (`swift test` on macOS); attempt detection, RPE model,
   Tindeq protocol, ACWR, and date logic live in the `SendLogWatchCore` SwiftPM
   package (`cd ios/App/SendLogWatchCore && swift test`). New native logic
   should land in one of these testable layers first, UI wiring second.
2. **WebView UI → browser against the local stack** (`npm run dev:local` +
   `?fake-tindeq`). Everything React is fully exercisable here.
3. **Capacitor shell + watch UI → simulators.** `npm run sync:local` (web
   bundle + health plugin + watch all hit the local stack), then run the App
   scheme (paired iPhone+watch simulators for the companion); log in with
   `dev@sendmeter.test` / `devpassword`. Good for layout, navigation,
   WatchConnectivity relays, and the watch UI. HealthKit sample data can be
   added by hand in the simulator's Health app, but background delivery is
   unreliable there.
4. **Device / TestFlight — the only truth for:** HealthKit runtime + background
   delivery, real HRV/sleep data, Bluetooth (Tindeq), attempt detection (real
   motion sensors), Live Activities, complications/Smart Stack, passkeys, and
   signing. Flag these as device-only rather than claiming them verified.

**Simulator loop (rung 3), learned the hard way:**

```bash
npm run sync:local        # local-config web bundle → ios/App/App/public
# Xcode Run (App scheme, Debug) is the easy path — it installs fresh automatically.
# Headless equivalent:
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' build
# then install + launch onto the booted sims (products live under
# ~/Library/Developer/Xcode/DerivedData/App-<hash>/Build/Products/):
xcrun simctl install booted <...>/Debug-iphonesimulator/App.app
xcrun simctl launch booted com.jirathip.sendlog
xcrun simctl install booted "<...>/Debug-watchsimulator/SendLogWatch Watch App.app"
xcrun simctl launch booted com.jirathip.sendlog.watchkitapp
```

- **Never run two xcodebuilds on this project concurrently** — they corrupt
  each other's SPM checkouts in shared DerivedData ("couldn't be removed /
  File exists" resolve errors). Build sequentially; a failed resolve just
  needs a rerun.
- **Stale installs are the #1 trap.** Launching a simulator does NOT update
  the app in it — an old install keeps the old (hosted-project) config and
  login as `dev@sendmeter.test` fails "wrong email or password". The tell on
  BOTH phone and watch: pre-rename "SEND LOG" branding on the sign-in screen
  = stale build (current source says Sendmeter everywhere). When in doubt,
  reinstall via simctl. The watch app is a
  separate install on the watch sim: rebuilding/reinstalling the phone app
  does NOT refresh it.
- **Watch sign-in:** the watch gets its access token relayed from the running,
  signed-in phone app over WatchConnectivity (works between *paired* sims —
  `simctl pair <watch> <phone>` first; `updateApplicationContext` is delivered,
  `transferUserInfo` was NOT observed being delivered watch-ward in the sim).
  There is no manual sign-in on the watch any more (#265) — a watch running
  alone waits on the "Waiting for iPhone" screen, which is expected, not a bug.
  For a sim experiment you can mint a token directly:
  `curl -X POST "http://127.0.0.1:54321/auth/v1/token?grant_type=password"`.

**Caveat for rung 4:** device builds still have the hosted Supabase config
**compiled in** (localhost is meaningless on a physical device) — a Debug
device build writes to **production**. When testing native flows on-device,
sign in with a throwaway dev account, never the real account.

**Warning:** `sync:local` leaves a local-config web bundle in
`ios/App/App/public` — run `npm run sync` (or let fastlane's lane rebuild)
before archiving; fastlane runs its own `npm run build` so TestFlight builds
are safe regardless.

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
- **Routine engine** — `src/lib/routine.ts` (pure, vitest-covered):
  `expandRoutine(steps, {prepareS})` mirrors `protocol.ts`'s `buildTimeline`,
  expanding a `RoutineStep[]` into flat timed segments (prepare/work/rest,
  each step repeating ×reps with a rest between reps). `routineRun.ts` holds
  the persisted, wall-clock-derived run state (`presetId`, `startedMs`,
  pause bookkeeping) so `elapsedS()` can resume a run exactly after a
  refresh/relaunch; `shouldLog()` gates logging a partial session on ≥60s
  elapsed. Consumed by `src/components/RoutineCard.tsx` (preset CRUD + run
  launch, on the Workout tab) and `RoutineFullscreen.tsx` (the running
  countdown UI), wired into `WorkoutView.tsx`.
- **Dynamometer layer** — `src/lib/dynamometer/` (#173): a device-agnostic
  `DynamometerDriver` interface (connect/disconnect, `{us, kg}` sample stream,
  tare, start/stop, device info, and a `capabilities` flag set for what a
  device *lacks*) plus the Tindeq driver that implements it (`tindeq.ts` =
  BLE transport, `tindeq-protocol.ts` = the pure packet parsing, unchanged and
  still mirroring `SendLogWatchCore/TindeqProtocol.swift`). `registry.ts` is
  the one place a driver is registered; `useTindeq` resolves
  `activeDynamometerDriver()` at module load and never sees a UUID or a
  command byte. `contract.ts` is the conformance suite a new driver must pass
  — it runs against the real Tindeq driver (BLE mocked) *and* stub drivers, so
  the seam is proven without hardware. Two things are honestly NOT behind the
  seam and say so in comments: `?fake-tindeq` FAKE_MODE (a property of the
  hook, not a driver) and the Force tab's Tindeq-specific UI copy. Adding a
  real second device is still blocked on owning one.
- **`src/`** — the React app. `lib/` = data/logic (`repo/` = all Supabase
  queries, metrics.ts = ACWR/EWMA + exported `ewma()`, force-curve.ts =
  critical-force fit + `ZONE_PROTOCOLS`, protocol.ts = guided Tindeq
  timelines, routine.ts/routineRun.ts = guided routine-timer timelines +
  resumable run state, healthSync.ts + watchAuthRelay.ts = native bridges).
  `components/` = UI (`InfoDot.tsx` = the "?" explainer sheets). `hooks/` =
  data hooks.
- **`ios/App/App.xcodeproj`** — four product targets: the Capacitor iOS **App**,
  the **SendLogWatch Watch App** companion (SwiftUI; workout/attempt tracking,
  force gauge, readiness display), **SendmeterWidgets** (WidgetKit app
  extension = the phone Live Activities), and **SendLogWatchWidgets** (WidgetKit
  extension embedded in the watch app = watch-face complications + Smart-Stack
  widgets). Plus a `SendLogWatchTests` unit-test target.
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
  - **`SendLogWatchWidgets`** (watch complications + Smart-Stack widgets) is a
    separate process from the watch app, so it **needs an App Group**
    (`group.com.jirathip.sendlog`) to share data. The watch app is the source of
    truth: `WidgetBridge` writes a `WidgetSnapshot` (readiness + on-watch-computed
    ACWR + live-workout state) to the App Group and calls
    `WidgetCenter.reloadAllTimelines()` on sync/foreground/workout-start/boulder-
    toggle/end. `WidgetShared.swift` is **duplicated** (watch-app copy + widget
    copy, KEEP-IN-SYNC) since each target is its own synced group. Created by
    `scripts/add_watch_widget_target.rb` (min watchOS 10, bundle id
    `…watchkitapp.widgets`, `SendLogWatchWidgets-Info.plist` outside the synced
    dir). Quick-launch complications deep-link via `sendmeter://workout|force`
    → `RootView.onOpenURL` → the `NavigationStack` path.
    - **One-time manual portal step (App Group):** the App Group must exist and
      be enabled on the `…watchkitapp` **and** `…watchkitapp.widgets` App IDs in
      developer.apple.com → Certificates, IDs & Profiles, or `fastlane beta`'s
      `get_provisioning_profile` fails for the widget appex. The Fastfile
      registers the widget App ID + fetches its profile but can't toggle the
      capability. Device-only to verify (complications/Smart-Stack don't run in
      the simulator gallery here).
- **`native-plugins/`** — local Swift/Capacitor plugins (npm `file:` deps):
  - `sendlog-health` + `sendlog-health-core` — HealthKit read on the **iPhone**,
    readiness compute, `health_metrics` upsert, background delivery. `-core` is
    pure Foundation (unit-tested); the plugin adds HealthKit + Supabase.
  - `sendlog-auth-bridge` — relays the Supabase session from the WebView to the
    watch over WatchConnectivity; also **receives** watch→phone live-workout
    beats (`didReceiveMessage`) and forwards them to the WebView via
    `notifyListeners("liveWorkout")` (the Bluetooth-fast mirror path — works even
    while the WebView is suspended). It also records the **watch's build**
    (#228): every watch→phone message carries `watch_app_version` /
    `watch_app_build` (see "watch build report" below), which the plugin
    stores in `UserDefaults` and reports via `getWatchInfo()`. It depends on
    `ios/App/SendLogWatchCore` for that contract — same shape as
    `sendlog-health` → `sendlog-health-core`.
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
- **`supabase/migrations/`** — Tables: `sessions` (incl.
  `workout_source` = immutable auto/phone badge that survives type edits),
  `user_settings`, `phase_periods`, `tindeq_recordings`, `tindeq_presets`
  (hold/reps/sets/rests + target kg or %-of-PR + per-set % step + alternate
  sides), `routine_presets` (user-defined guided routine steps, drives the
  Workout tab's routine timer), `climb_workouts`/`climb_attempts` (both with
  `source` provenance), `health_metrics`, `live_workouts` (one row per user,
  watch-heartbeat for the live workout mirror), `tindeq_tags` (per-user tag
  registry for rename/hide metadata; tags themselves stay denormalized on
  `tindeq_recordings.tag`). RLS scopes everything to `auth.uid()`; realtime
  publishes the watch-writable tables + `live_workouts`.

## Non-obvious things that will bite you

- **iOS min is 16.0**, not 15. The Supabase Swift SDK floors at 16; Capacitor
  derives `CapApp-SPM`'s platform from the *first* `IPHONEOS_DEPLOYMENT_TARGET` in
  the pbxproj (the **project-level** one), so it must be 16 for `cap sync` to
  regenerate SPM correctly.
- **`@capacitor-community/apple-sign-in`'s SPM pin is patched, not upstream.**
  It has no Capacitor-8 release; the npm-published 7.1.0 pins
  `capacitor-swift-pm` to `7.0.0..<8.0.0`, disjoint with
  `native-plugins/sendlog-passkey`'s `8.0.0..<9.0.0` — with the pristine
  package NO scheme in `ios/App/App.xcodeproj` resolves its SPM graph.
  `patch-package` re-pins it to `from: "8.0.0"` on `postinstall` from
  `patches/@capacitor-community+apple-sign-in+7.1.0.patch`. Never remove the
  `postinstall` script or the patch file — a clean `npm ci` without them
  silently reverts the pin and breaks SPM resolution project-wide.
- **Dates must be Gregorian.** A Thai-region device defaults `Calendar.current` to
  the Buddhist calendar (year + 543), which once corrupted every stored date. Use
  `Calendar.gregorianLocal` / `Date.localDateString` (Swift) and the web
  `src/lib/dates.ts`. There's a DB `check` constraint bounding dates as a backstop.
- **Health ingestion is iPhone-only.** The iPhone is the *sole* writer of
  `health_metrics` (it sees the merged HealthKit store incl. third-party wearables).
  The watch only *reads* the computed score back for display — it no longer reads
  HealthKit or writes health rows. Don't reintroduce watch-side health writes.
- **Only supabase-js holds a refresh token. The relays carry access tokens only**
  (#265). The web (supabase-js), the watch and the iPhone health plugin all share
  the user's session, but the two native consumers are handed a short-lived
  **access token** and nothing else, re-relayed on every auth event + app
  foreground (the `useAuth` visibilitychange listener). Refresh tokens are
  single-use with reuse detection ON: a second holder presenting one the phone
  has since rotated makes Supabase revoke the entire session family, signing the
  phone out too. That is not prevented by discipline any more — the credential is
  simply not on the wire (`SendLogAuthBridge.setSession` / `SendLogHealth.setSession`
  have no `refreshToken` field) and not on the device (both native clients are a
  single `SupabaseClient` with an `accessToken` provider and no `AuthClient`;
  `WatchSessionStore` / `HealthSessionStore` keep the bearer token in the Keychain
  and purge supabase-swift's own item on every launch).
  - **Two earlier attempts failed by convention.** #196 split each native side
    into an `auth` + `data` client and forbade every refreshing accessor; the
    rules were right and a twelve-hour-stale token was replayed in production
    anyway. `src/lib/nativeAuthInvariants.test.ts` now pins the structural
    property from vitest, because the `quality` job never compiles the Swift.
  - **The watch cannot sign itself in, by design** — no email/password form. It
    consumes what the phone relays; when the token expires it asks
    (`requestSession`) and waits, staying `signedIn` with `tokenFresh: false` so
    the offline queues keep their account stamp. Don't reintroduce a watch-native
    login: it would create a second rotating session on the wrist.
  - **Relayed payloads must always differ.** Verified in paired simulators
    (2026-07-27): `updateApplicationContext` does **not** deliver a payload
    identical to the one already set, which is why answering a watch's pull while
    the phone's token was still valid landed nothing (#266). The plugin stamps
    every relay with a fresh `relayId` + `relayedAt`; a pull is additionally sent
    via `transferUserInfo`. Never relay a payload whose content could repeat.
- **Every watch→phone WC message carries the watch's build** (#228) — the watch
  app updates from TestFlight on its own schedule, so a phone on the fixed
  build can be paired with a pre-#208 watch that is still revoking the session
  family, and the phone had no way to see it. `WatchBuild.stamp(...)` adds
  `watch_app_version` / `watch_app_build` to the live-workout beat, the
  live-force beat and `requestSession`; **stamp any new watch→phone message
  the same way** — the account sheet reads whatever last arrived. The phone
  plugin `WatchBuildReport.stripped(...)`s them back off before forwarding, so
  `LiveWorkoutMessage` / `LiveForceMessage` keep their exact shape. The verdict
  (behind / ahead / differs / never reported) lives in `SendLogWatchCore` so
  it's tested on Linux CI; the sheet only renders it.
  - **…and its offline-queue depth** (#21, `watch_pending_sync`). Same channel,
    same rules: unknown values are left off, `stripped(...)` removes all three
    keys, the verdict (empty / pending / backed-up / never reported, plus
    staleness) lives in Core. The non-obvious part is the *read*:
    `OfflineQueue` / `PendingSessionQueue` are actors, so their counts can't be
    awaited on the synchronous WC send paths — each publishes into
    `PendingSyncCache` (sync-readable, process-wide) whenever it counts,
    persists or drains, and `WatchBuild.stamp` reads the cached sum. **Any new
    queue whose depth should show up on the phone has to publish there too**,
    and nil (never counted) must keep reading as "not reported", never as an
    empty queue.
- **Migrations auto-apply on merge, to BOTH remote projects (#130).** `.github/workflows/deploy-migrations.yml`
  runs on any push touching `supabase/migrations/**`: `staging` → the **dev/preview**
  project (`mjkndfhjnipomjjhgsxv`, issue #121 — hosted on a second Supabase account),
  `main` → the **prod** project (`zznsqmcewtzlnfoiefkk`). It calls
  `scripts/apply-migrations.mjs --target dev|prod`, which applies pending migrations
  **by name** (append-only — see below) via the Management API and records the name
  + version in `supabase_migrations.schema_migrations`. There is no required-reviewer
  gate on this plan, so **the merge itself is the human gate**: merging to `main`
  applies DDL to production (`deploy-migrations.yml`'s own warning comment says the
  same). Check parity any time with `npm run migration:status`.
  - **Manual path (fallback / verification only)**, for backfills or incident
    response when you can't wait for a merge: `POST /v1/projects/{ref}/database/query`
    (or `npm run migration:apply -- --target dev|prod` locally), same by-name
    semantics as the workflow. **One Management API token reaches both projects**
    (`~/.supabase/access-token`): the main account is only a *Developer* on the dev
    project, but Developer is sufficient for the Management API — verified
    2026-07-25. (The older `~/.supabase/dev-account-token` is no longer needed; the
    token that was there had expired, which presents as `401 JWT could not be
    decoded` — a dead token, not a rights problem.)
  - Drift still happens if the automated flow is bypassed or a project falls behind:
    the `health_metrics` delete policy + date-sanity constraints once sat unapplied
    for a while (with no DELETE policy, a delete silently matches zero rows, so
    "Clear health data" looked broken while succeeding). Run `npm run
    migration:status` after any manual intervention to confirm dev and prod agree.
    The dev project is free-tier and auto-pauses after ~7 idle days — unpause it
    (second account's dashboard or its token) before it needs to receive a push or
    before verifying a release.
- **CI secrets live on GitHub *environments*, not the repo (#130).** The
  two Supabase projects are on two different accounts, but **one main-account token
  reaches both** (Developer role suffices for the Management API), so the same
  `SUPABASE_ACCESS_TOKEN` value can go in both environments:

  | GitHub environment | project ref | deployable from |
  |---|---|---|
  | `Preview` | `mjkndfhjnipomjjhgsxv` | `staging` only |
  | `Production` | `zznsqmcewtzlnfoiefkk` | `main` only |

  The branch restriction is the real guard: prod secrets are unreachable from any
  branch but `main`, so a mis-wired job cannot touch prod. (Required *reviewers*
  would be better still, but need a paid plan on a private repo.) A workflow picks
  an environment with
  `environment: ${{ github.ref == 'refs/heads/main' && 'Production' || 'Preview' }}`.
  **Match that capitalisation exactly** — GitHub silently *creates* an environment
  when the name doesn't match an existing one, so a lowercase `production` would run
  with no secrets and no error. This repo's environments are `Preview`, `Production`
  and `testflight` (that last one lowercase).
- **Automated migrations must apply by NAME, not version.** Prod's
  `schema_migrations` carries apply-time versions from the MCP `apply_migration`
  era while local files carry file timestamps, so the same migration legitimately
  has different versions on the two projects. `supabase db push` diffs by version
  and would re-apply recorded history. Use the Management API
  (`POST /v1/projects/{ref}/database/query`) — access token only, no DB password,
  no `supabase link`, so `supabase/config.toml`'s hardcoded prod ref can't misfire.
  This repo's `scripts/apply-migrations.mjs` (append-only, fails on an unrecorded
  *older* migration; also the engine behind `deploy-migrations.yml`) and
  `scripts/migration-status.mjs` (dev/prod parity table; `npm run
  migration:status`) are the reference implementations — ported from
  `synergy-costing`, which hit this problem first. The ledger records only what
  was *reported* applied — it is not proof the objects exist.

- **`autoRefreshToken: false` does NOT stop supabase-swift refreshing.** It only
  disables the background *timer*. Two accessors refresh anyway, and both were
  live in shipped builds: `auth.session` (refreshes whenever the stored access
  token is expired — the #196 finding) and **`auth.setSession(accessToken:
  refreshToken:)`, which calls `refreshSession` outright when the access token it
  is handed has already expired** — the #265 finding, and the one #196's guards
  were left standing in front of. Neither native client has an `AuthClient` any
  more (#265): each is a single `SupabaseClient` whose `accessToken` provider
  returns the relayed bearer token, so there is nothing to refresh, recover or
  rotate. `SupabaseClientOptions.AuthOptions` enforces argument order —
  `autoRefreshToken` must precede `accessToken` — and the main
  `SupabaseClientOptions` init is `(db:auth:global:functions:realtime:storage:)`,
  so `auth:` must precede `global:`.
- **The `Preview` GitHub environment must stay unrestricted.** Vercel's
  integration deploys *PR branches* to it, so adding a deployment-branch policy
  (e.g. "staging only") makes every PR-branch deployment be rejected and the
  workflow runs on those branches fail with `startup_failure` — with no error
  that points at the environment. Cost ~25 min of broken CI on 2026-07-25.
  `Production` → `main` only is fine and is set, because prod only ever deploys
  from `main`. (Required *reviewers* would be better but need a paid plan on a
  private repo.)
- **`public` Swift types lose implicit `Sendable`.** Swift infers it for internal
  structs but never for public ones, so moving a value type into a package
  (`SendLogWatchCore`, #191) silently drops the conformance — the compiler stays
  quiet until something turns on strict concurrency checking. Declare it
  explicitly on pure-data types when making them public.
- **A green `quality` check says nothing about Swift.** `ci.yml` is lint /
  typecheck / vitest / vite build — all web. Only the `swift` job in `ios-ci.yml`
  (#178, `paths: ios/**`) compiles the watch and phone targets. An iOS-only PR
  with `quality=SUCCESS` and no `swift` result is **unverified**; #162 reached
  staging exactly that way, and a missing-argument-order error nearly did again
  in #196. If the macOS runner is queued, compile locally rather than merge:
  `xcodebuild build -project ios/App/App.xcodeproj -scheme "SendLogWatch Watch App" -destination "id=<sim udid>" CODE_SIGNING_ALLOWED=NO`.

- **Tindeq capture flow (intentional).** Both the in-app gauge and the watch set
  **tag + side before Start** and **auto-save on Stop** — no post-stop discard/save
  prompt (in-app has an Undo; the watch hides tag/side/session controls *while
  measuring* so the live gauge fits one screen). Ending the session (phone
  Finish, watch, or a disconnect) **auto-logs to history with no confirm
  step** (#295, mirrors the watch's `TindeqManager.logSessionNow()`) — RPE is
  the #280 W'-depletion prediction (or its fallback), always banked
  `rpe_confirmed = false` since nobody reviewed it, and duration is the
  recordings' actual span. Reviewing/editing RPE (or duration) happens
  post-hoc via History's `EditSessionSheet`. Don't reintroduce the end-of-
  session RPE prompt or an editable duration at log time.
- **The recording queue is TWO stores, and the split is load-bearing** (#269).
  **IndexedDB** (`src/lib/recordingDb.ts`) is the main queue — every path that
  can await (ForceView's failed-insert handler, the drain, the manual retry)
  uses `persistRecordingDurable`. **localStorage** keeps only a *synchronous
  emergency lane*, written by exactly one caller: `useTindeq`'s
  salvage-on-unmount cleanup, which is a React cleanup function and **cannot
  await** — an async write there doesn't finish later, it loses the buffer.
  `absorbSyncLane` moves the lane into IndexedDB on the next drain/foreground,
  and that same function IS the one-time migration of pre-#269
  `sendmeter:pending-recordings` entries (same shape, so no migration flag
  exists to get out of step). The migration is **interrupt-safe by
  construction**: the copy is one transaction, the lane is cleared only after
  it commits, and the store's keyPath is the entry `id`, so re-copying after a
  kill overwrites instead of duplicating. Don't collapse the two stores, and
  don't "simplify" the salvage path onto the async one. IndexedDB unavailable
  (private mode, storage disabled, a blocked open) degrades to the lane —
  `openRecordingDb` resolves `null`, never throws.
- **Sign-out is ONE function, and it is the only thing that may delete a queued
  recording** (#273). `signOutUser` in `src/lib/signOut.ts` is the single
  implementation behind both `useAuth().signOut` and `deleteAccount` — those
  two used to hold a copy each of `markUserSignOut()` + `supabase.auth.signOut()`.
  A **user-initiated** sign-out drains the offline queue first (it needs a live
  token, so the drain must finish BEFORE `signOut()`, deadlined by
  `DRAIN_TIMEOUT_MS` so a dead network can't hang it), clears what uploaded,
  and asks about any remainder — never an unconditional confirm, which would
  fire mostly on an empty queue. A **forced or revoked** sign-out (#265 —
  it really happened) **discards nothing**: the two paths are told apart by
  `markUserSignOut()`'s marker, and `clearRecordingQueue` is reachable only via
  `discardQueueOnUserSignOut`, which checks it. `signOutInvariants.test.ts`
  pins "one implementation, one deletion site" structurally, because the cost
  of the paths drifting is the user's training data. Accepted residual, on
  purpose: kept-but-undrainable entries live on the device until the same
  account signs back in. Full reasoning: the "#273" section of the policy block
  in `recordingQueue.ts`.
- **A recording that can't be persisted is reported, never swallowed** (#264).
  The queue's last line of defence is a storage write, and that write can
  itself fail (quota exhausted, storage disabled) — the failure the queue
  exists to protect against, at the one moment it can't. The decided policy
  lives in full above `persistRecording` in `src/lib/recordingQueue.ts`; the
  short version: **the new recording wins** (a refused write retries after
  dropping the oldest queued entry, repeatedly, down to the new entry alone),
  and if the lone entry still won't write, the loss is real and gets said out
  loud — `reportPersistFailure` (`src/lib/lostRecordings.ts`) is the single
  reporting path for both call sites, emitting a Sentry `data-loss:` event
  plus a durable one-shot notice that `App.tsx` surfaces on the next
  mount/foreground. `useTindeq`'s salvage-on-unmount can only report (no UI is
  reachable from a cleanup); `ForceView` additionally holds the samples in
  memory behind a Retry/Discard banner. **Never phrase a `persisted: false`
  outcome as "queued" or "will sync"** — nothing is holding it. Eviction
  survives #269 as a *backstop* (`MAX_IDB_QUEUE_BYTES` = 64 MB, ~20 heavy
  offline sessions) and still reports to monitoring — a non-zero `evicted` on
  the IndexedDB path is now a finding, not routine degradation.
- **Queue depth is ambient, never an interrupt** (#269). `usePendingUploads` →
  a muted line on the Force tab and a "This iPhone · N recordings pending sync"
  row in the account sheet, next to the watch's own queue line (#21). A toast
  or alert per failed upload fires exactly when the user is mid-outage and can
  do nothing, and then repeats per rep — don't add one. Same honest-states rule
  as `watchSyncLine`: "not read yet" must not render as "empty".
- **Recording samples store `t` in milliseconds.** `tindeq_recordings.samples`
  time is ms — charts must divide by 1000 to show seconds (a mislabeled axis once
  showed "25152.0s").
- **`?fake-tindeq`** query param puts the web Force view in fake mode (simulated
  BLE + force stream) — the only way to exercise the connect→measure→save flow in
  a browser (real Web Bluetooth needs a device).
- **`?fake-weather[=hot|prime|bad|no-hist]`** puts Send Conditions in fake mode
  (`src/lib/weather.ts`) — a synthesized reading + 30-day history, skipping
  geolocation, both live Open-Meteo calls, and both localStorage caches — so
  the card/sheet are browser-testable in local dev without a device's location.
- **Never add `live_workouts` to `WATCHED_TABLES`** in
  `RealtimeVersionProvider.tsx` — the watch heartbeats it every ~5s, which
  would refetch every card in the app every 5s. The Workout tab subscribes to
  it on its own payload-reading channel (`useLiveWorkout`).
- **Haptics are delegated, not per-call-site** (#171). `installTapHaptics()` in
  `main.tsx` puts ONE capture-phase pointer listener set on `document`; every
  `<button>`, toggle label, checkbox and `.card.tappable` ticks for free, so
  don't add a haptic call to a new button. Non-button tappables opt in with
  `data-haptic="light" | "medium"`; `data-haptic="off"` (and `.chart-scrub`) is
  a **mute boundary** — `closest()` nearest-match-wins, so the boundary silences
  everything under it that isn't itself interactive. Three rules that will bite:
  (1) the tick resolves on **pointerup** with a 10px slop, never pointerdown, or
  every scroll that starts on a button buzzes; (2) `aria-disabled` (the #222
  refused-but-clickable Start controls) fires the **warning** pattern, never the
  accepted one, while a real `disabled` fires nothing — a refused tap must not
  feel like an accepted one; (3) one tick per gesture, so a button inside a
  tappable card, an explicit `tapHaptic()` and a sheet's mount effect on the
  same tap collapse to one. `selectionHaptic()` is the deliberate exception —
  unguarded, for per-value-change ticks (chart scrub, the #172 slider), which is
  why those controls are muted for the delegated path.
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
  `theme`, `auth-events` (bounded ring of null-session diagnostics, #194/#202).
- **Auth diagnostics don't live in localStorage on native.** `auth-events`,
  `auth-heartbeat`, `webview-canary` and `auth-events-flushed` go through
  `authEventStore.ts`: Capacitor **Preferences** (NSUserDefaults) on native,
  `localStorage` on web — because the WebView store is exactly what may be
  getting wiped, and evidence stored next to the session dies with it. The
  seam is synchronous by contract (write-behind cache + serialized async
  writes) so the auth path never awaits a disk write and a failed write can't
  throw into it. `webview-canary` is written to BOTH stores: present in
  Preferences but gone from `localStorage` = the WebView's data was purged.
  The ring is pushed to `auth_events` on the next sign-in
  (`authEventFlush.ts`, upsert on `(user_id, reason, first_at)` — idempotent,
  never blocks sign-in).
- **Sentry only ever sees an allow-listed event** (#227, `src/lib/monitoring.ts`).
  It initializes *only* when a build-time `VITE_SENTRY_DSN` is present — no DSN
  (dev, tests, any un-configured build) and the SDK is dead-code-eliminated
  entirely. `beforeSend`/`beforeBreadcrumb` rebuild the event from allow-lists:
  the auth uuid as the only identity, no query strings, no console breadcrumbs,
  and every `HealthMetric` field name/value dropped — `monitoring.test.ts`
  proves that on an event deliberately built carrying all of them, so **add any
  new health field to `HEALTH_TERMS`**. It catches things that *throw* (render
  crashes, unhandled rejections); it would NOT have caught the #202 logout,
  which fails silently — that's what the auth diagnostics above are for. Setup
  + the device-verification checklist: `docs/error-monitoring.md`.
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

- **Release flow: TestFlight builds from `staging`, by default.** TestFlight is
  the rung-4 device-verification channel, so build it from `staging` *before*
  promoting: staging → `bundle exec fastlane beta` → verify on device →
  promotion PR staging → main (which triggers the Vercel production web
  deploy). Promoting first would ship native code to the release branch
  before it's ever been device-verifiable, and couples "I need a build on my
  phone" to a web prod deploy. Exception: builds for **external testers /
  App Store submission** cut from `main` so the promoted branch is exactly
  what ships. Note the branch is only a *code-state* distinction for native
  builds — the compiled-in Supabase config means every device build
  reads/writes **production** data.
- **CI TestFlight builds are opt-in, not per-merge (#150).**
  `.github/workflows/testflight.yml` runs `fastlane beta` on a Blacksmith
  **6vCPU** macOS runner (`blacksmith-6vcpu-macos-26`, $0.08/min — macOS
  minutes burn the free tier at 20x the Ubuntu rate and were the dominant CI
  cost, ~$0.5+ per build on the old always-on 12vCPU trigger). A staging push
  only builds when the pushed commit message contains **`[testflight]`** (for
  a squash-merged PR that's the PR title); untagged pushes show as skipped
  runs. For an on-demand build use
  `gh workflow run TestFlight --ref staging` (a `runner` input overrides the
  label, e.g. back to 12vCPU for a rush build). The workflow's `concurrency`
  queues and never cancels — build numbers come from
  `latest_testflight_build_number + 1`, so parallel runs would race the same
  number. Failed uploads (Apple 500s happen) still bill the full build —
  rerun via workflow_dispatch rather than re-pushing.
- **`fastlane beta` runs fully headless via the ASC API key** — `cd` to repo root
  (or `ios/`) and run `LANG=en_US.UTF-8 bundle exec fastlane beta` (always via
  `bundle exec`, never bare `fastlane beta` — the Ruby toolchain is pinned in
  `.mise.toml` and the fastlane version in `Gemfile.lock`; a bare invocation
  can pick up a different globally-installed fastlane). It works from a
  spawned/non-interactive shell, no signed-in Xcode account required. The lane
  (`fastlane/Fastfile`) does everything: `npm run build && cap sync ios`, then
  `get_certificates` (installs/creates the Apple Distribution cert via the API key),
  `get_provisioning_profile force:true` for the app + `.watchkitapp` + `.widgets`
  (regenerated so they carry the current cert; the lane first creates the
  `.widgets` App ID via `Spaceship::ConnectAPI::BundleId.create` since sigh won't),
  `latest_testflight_build_number + 1` (so **never hand-bump
  `CURRENT_PROJECT_VERSION`** — the lane injects it via `xcargs` at archive time
  into app + watch + widget), then `build_app` with **manual** signing on both
  the archive and the export, then `upload_to_testflight`. Config lives in
  `fastlane/.env` (`ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH`) +
  `fastlane/asc_api_key.p8` (git-ignored) — fastlane auto-loads `.env`.
  - **The archive signs manually via a runtime pbxproj edit (#263), and
    `-allowProvisioningUpdates` is export-only.** gym runs two xcodebuild
    invocations and `export_options` governs only the second one; the archive
    obeys `project.pbxproj`, where every target is `CODE_SIGN_STYLE = Automatic`
    for local Xcode dev on a personal team. On a fresh CI runner that meant
    automatic signing found no Development identity and — authorised by the API
    key plus `-allowProvisioningUpdates` — **minted a new "Created via API"
    Apple Development certificate on every run** until the account hit Apple's
    cap. The lane now flips the four archived targets' *Release* configs to
    Manual + `Apple Distribution` + the profile sigh just fetched
    (`update_code_signing_settings`, reverted in an `ensure`), and the auth
    flags moved from `xcargs` to `export_xcargs`. That split is load-bearing:
    gym appends `xcargs` to **both** invocations but `export_xcargs` to the
    export only, so this is the only way to keep the export's API-key access
    (the original `exportArchive "No Accounts"` fix) while denying the archive
    any authority to create signing assets. Putting the flags in both is what
    trips `-authenticationKeyID may only be provided once`. **Never commit
    Manual signing into `project.pbxproj`** — it would break local Xcode
    builds — and never hardcode a `PROVISIONING_PROFILE_SPECIFIER` there; the
    names come from `SharedValues::SIGH_NAME` at runtime. See
    `ios/COMPANION_SETUP.md` → "Why the archive signs manually".
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
- **Vercel previews (issue #121):** `vercel.json` enables git deploys only for
  `main` (production) and `staging` (preview) — task branches never deploy.
  Promotion PRs (staging → main) get a preview URL that must point at the **dev**
  Supabase backend via Preview-scoped `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`
  env vars in the Vercel project settings (`src/lib/supabase.ts` falls back to the
  committed prod config when they're absent, so Production needs no vars). The dev
  project's auth allow-list must include the preview wildcard **origin-only**
  (no trailing `/**`): `https://climbing-tracker-*-jirathip-kunkanjanathorn-s-projects.vercel.app`.
  Vercel hashes the staging branch alias to `climbing-tracker-git-ea1530-…` (the
  literal `git-staging-…` name would exceed the 63-char DNS label limit) — that
  alias is the stable staging-preview URL and the dev project's auth Site URL.
  Previews sit behind Vercel SSO (fine when logged in; mint a bypass link via the
  Vercel MCP `get_access_to_vercel_url` for curl/fetch).

## Working style here

- This is a solo project moving fast. Match the surrounding code's style.
- Commit only when asked; branch off `main` first. The iPhone health-sync + rename
  work (`feature/iphone-health-sync`) is **merged to `main`**; on-device TestFlight
  verification of the HealthKit runtime + watch UX is still pending.
- Backlog lives in **GitHub Issues** on this repo (migrated from Notion
  2026-07-21; each issue title is prefixed `SL-N` carrying over the old Notion
  auto-increment ID, so commit-message references like "SL-91" still resolve —
  search `SL-91` in Issues). Labels mirror the old Notion schema: `type: *`
  (bug/idea/refactor/performance/security/chore), `area: *` (dashboard,
  tindeq-ble, watch-app, etc.), `priority: *` (urgent/high/medium/low), plus
  `blocks-release`. Closed issues use `--reason completed` for shipped work and
  `--reason "not planned"` for dropped ideas — the Notion reason string is
  `"not planned"` with a space, not `not_planned` (the latter silently fails).
  Planning docs still live in `~/.claude/plans/`. Native/HealthKit runtime
  behavior can't be verified in the simulator — flag device-only work rather
  than claiming it verified.
- App Store submission state is tracked in `docs/app-store-checklist.md` and
  `ios/COMPANION_SETUP.md` (signing troubleshooting + the health device-test checklist).
