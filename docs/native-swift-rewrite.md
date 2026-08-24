# Native Swift rewrite

## Scope

`native/SendmeterNative` is a feature-complete parallel iPhone client written in
SwiftUI. It shares the production data model and reuses the existing Watch app;
the generated native project embeds that watch target in Release builds while
leaving the shipped Capacitor target untouched. This isolation is the primary
regression-control mechanism: the rewrite can fail validation without changing
the current release. The native app target currently requires iOS 17 because
its per-property `@Observable` models and typed SwiftUI environment are iOS 17
APIs; the reusable `SendmeterCore` package remains iOS 16-compatible.

## Compatibility contracts

The native client preserves the existing product contracts rather than creating
new equivalents:

- Existing Supabase tables, RPCs, RLS ownership, stable UUIDs, and snake-case JSON
- Existing session, phase, health, Tindeq, preset, routine, workout, Trash, and account semantics
- `supabase-swift` is the only phone refresh-token owner; Watch receives access tokens only
- WatchConnectivity is the low-latency mirror, while Supabase and durable queues remain authoritative recovery paths
- Optimistic rows appear only after an atomic local queue write succeeds
- Queued data is account-scoped and cannot be cleared with an unresolved user
- Active queue failures retain their rejection class, last error, attempts, and
  backoff across relaunch; explicit Retry waits for an in-flight owner and
  bypasses automatic backoff. Same-account auth recovery also immediately
  revalidates that account's parked auth failures without spending quarantine
  budget; permanently quarantined items remain excluded. Deleting a pending
  session or phone manual workout atomically cancels its upsert and retains a
  separate delete intent until the server mutation completes.
- Reverse Action stores one continuous row per set with honest cadence-clock completion, markers, and time-weighted metrics
- Existing TypeScript-created routines and force presets remain readable

## Regression strategy

1. Keep the production target untouched.
2. Pin external Swift dependencies to exact revisions.
3. Put calculations and state machines in `SendmeterCore` with deterministic tests.
4. Make every user-created session, workout, or force recording durable locally before claiming it is saved.
5. Use stable client IDs so retries and realtime reconciliation remain idempotent.
6. Confirm permanent deletion and explicit discarding of an unsaved force capture.
7. Build the complete iOS target in CI, not only the platform-independent package.
8. Require real-device verification before promotion.

## Data refresh & convergence (#673)

The app's authoritative list state (sessions, recordings, workouts, health
metrics, settings, phase periods, presets, routine presets, tag metadata) is
fetched by `refreshAll()`, which fans out 9 parallel full-table PostgREST
requests. It used to run on **every** scenePhase → `.active` transition — a
radio + battery + latency cost on each app switch.

**Chosen cursor scheme: a monotonic time cursor.** `refreshAll` records the
`systemUptime` at which the last **successful, still-current-account** sweep
published (`lastListRefreshAt`). A foreground refreshes fully only when
`ForegroundRefreshPolicy` (pure, unit-tested in `SendmeterCore`) says the data
is stale:

- The account has never loaded its lists (cold launch / account switch) — no
  baseline to trust.
- Realtime is **not** connected — a dropped socket degrades to foreground
  refetch (the documented convergence fallback).
- The last full refresh is older than the staleness window (60s) — the safety
  net for the tables realtime does **not** watch (settings, phase periods,
  presets, routine presets, tags) and for a long background gap.

Otherwise a "no-change" foreground issues **0** full-table fetches. The
realtime-watched tables (sessions, recordings, workouts, health metrics)
converge through the per-slice `RealtimeListReconciler`; `refreshAll` is
reserved for the explicit pull-to-refresh and the stale/fallback cases above.

An `updated_at`-per-row cursor (fetch only rows changed since last sync) is the
heavier alternative from the audit and is intentionally **not** what ships
here: while realtime already converges the watched tables with targeted
refetches, a 60s bounded window is sufficient and far less invasive.

## Promotion gates

A native target should replace the Capacitor phone target only after all of the
following pass on the same paired physical iPhone and Apple Watch builds:

| Workflow | Gate |
|---|---|
| iPhone authentication | No unintended logout across a minimum seven-day TestFlight soak |
| Watch token recovery | Expiry receives a fresh phone-owned access token without phone sign-out/sign-in |
| Reachable Workout mirror | p95 under 1 second for start, count/phase transitions, and end |
| Reachable Force mirror | p95 under 1 second with no unexplained gap longer than two 2 Hz intervals |
| Force local durability | p95 under 250 ms |
| Force History visibility | p95 under 1 second |
| Phone workout History visibility | p95 under 500 ms after Stop |
| Watch pending workout visibility | p95 under 2 seconds after the Watch queue commit |
| Server reconciliation | p95 under 7 seconds, reported separately from local visibility |

Also verify real Tindeq reconnects, lock/background transitions, passkeys,
HealthKit authorization/background delivery, accessibility sizes, VoiceOver,
small/large iPhone layouts, offline capture, process termination, duplicate
realtime events, account switching, and TestFlight signing/entitlements.

## Rollback

Revert the native project/workflow changes to remove the native app's embedded
watch dependency and restore the prior native distribution behavior. The
Capacitor app, database, and shared Watch target remain separate and are not
altered by that rollback.

## TestFlight distribution (#637)

The native app's Release configuration uses the shipped bundle ID and the
existing App Store Connect record. `SendmeterNative` embeds the existing
`SendLogWatch Watch App` target, whose product is
`com.jirathip.sendlog.watchkitapp`, and that watch target embeds the existing
`SendLogWatchWidgets` product as
`com.jirathip.sendlog.watchkitapp.widgets`. The watch Info.plist points back
to `com.jirathip.sendlog`. The Debug configuration uses the separate native
family `com.jirathip.sendlog.native`,
`com.jirathip.sendlog.native.watchkitapp`, and
`com.jirathip.sendlog.native.watchkitapp.widgets`; the Debug watch companion
points back to the Debug phone ID, so the native trio can be installed
side-by-side without colliding with the shipped IDs.

The direct mirror's live-workout behavior and the fact that it does not need
the realtime fallback are device-only promotion checks. An unsigned simulator
build can verify the target, bundle metadata, and Embed Watch Content phase,
but cannot prove installation on a physical paired watch.

**What ships it (dispatch-only workflow `native-testflight.yml` →
`bundle exec fastlane native_beta`):**

1. API key + cert setup — same CI-safe discipline as `beta` (`setup_ci` +
   import `IOS_DIST_CERT_P12` into a temp keychain on CI; `get_certificates`
   locally).
2. `xcodegen generate` the project (the generated `.xcodeproj` is ignored;
   the project spec and native resource inputs are committed).
3. Idempotently create the shipped phone, watch, phone-widget, and
   watch-widget App IDs, and enable the native phone capabilities.
4. Verify that the watch App ID has HealthKit + App Groups and that the
   watch-widget App ID has App Groups, with
   `group.com.jirathip.sendlog` attached to both in the Apple Developer portal.
   For signed Debug device builds, also manually create/enable
   `com.jirathip.sendlog.native.watchkitapp` with HealthKit + App Groups and
   `com.jirathip.sendlog.native.watchkitapp.widgets` with App Groups, attaching
   the same group to both Debug IDs. An unsigned simulator Debug build does not
   need portal profiles, but these capabilities are still required for a
   code-signed Debug device build. This is a manual prerequisite: the lane does
   not pretend the Connect API can toggle App Groups or attach the group
   container, and it fails before profile fetch if the capability flags are
   absent.
5. Fetch distribution profiles for the phone app, embedded watch app, phone
   widget appex, and embedded watch-widget appex.
6. Build number = latest TestFlight build of the shipped app + 1 (the native
   and Capacitor lanes share this train), injected via
   `CURRENT_PROJECT_VERSION` xcargs; never hand-bump `project.yml`.
7. Archive with manual signing pinned on all four generated targets (the
   project is regenerated each run); the auth flags stay export-only, same as
   `beta`, so the archive can never mint signing assets.
8. `upload_to_testflight`.

There is no separate native App Store record or tester list: the Release build
uses the existing Sendmeter app record. The lane creates or reuses the shipped
phone, watch, and widget App IDs and fetches the profiles needed for the
embedded bundles only after the manually managed watch entitlements are
present on the team's Apple Developer identifiers.

### Release compiler status and verification blocker

The native phone Release configuration restores the prior Swift
`SWIFT_COMPILATION_MODE=wholemodule` setting and retains `-O`. The two
fresh-derived-data Release archive attempts made with WMO and the subsequent
fresh-derived-data attempt made with `singlefile` all reproduced the same
Swift 6.3.3 `swift-frontend` `SILDeserializer` crash while compiling the
phone target. No compiler-mode workaround is retained; the project is back on
WMO and the optimizer remains `-O`.

The Debug watch/widget graph is green: XcodeGen/static generated-project
assertions pass, and the unsigned generic iOS Simulator Debug build succeeds.
Release and signed-archive verification remain unverified and are a #768
shipping blocker; no archive or embedded-watch inspection is claimed until a
new serialized Release lane validates the toolchain and archive structure.

**Workflow:** `native-testflight.yml` is dispatch-only (macOS runner minutes
are the dominant CI cost), uses the same `testflight` GitHub environment as
the shipped lane (match the capitalisation exactly), the same
`blacksmith-6vcpu-macos-26` runner input, a `native-testflight` concurrency
group (queue, never cancel — parallel native runs would race the shared build
number; do not run it concurrently with the shipped `beta` lane), and a cheap
Ubuntu gate that refuses refs without `native/SendmeterNative/project.yml`.
No node/npm steps — the native app is pure Swift.

### Sign in with Apple / AASA retest rule (learned the hard way)

**A TestFlight retest after any auth/Associated-Domains (`apple-app-site-association`)
change MUST be uninstall → install, never an update over the previous install.**

- Apple **caches** the AASA ("this app may sign in for sendmeter.app") **on the
  device** between builds — it re-fetches the association on *delete + fresh
  install*, not on a normal update. An update keeps the device's cached
  association.
- If the installed build predates a server-side AASA / Supabase
  `external_apple_client_id` / `uri_allow_list` fix, the device keeps checking
  the **old** association and the newer correct build fails at the
  Sign-in-with-Apple / passkey sheet with a JWT / "not associated with domain"
  error — even though the server fix is live. This is an **install-state /
  device-cache false positive, not a code bug** (verified 2026-08-22: live AASA
  serves both `com.jirathip.sendlog` and `com.jirathip.sendlog.native` in both
  `applinks` and `webcredentials`; clean install passes sign-in).
- **Deleting the app** is what throws the stale cached association away; the
  decisive retest is: delete Sendmeter → reinstall the same build → first
  open cold → try Sign in with Apple. If it passes, close the issue as
  resolved-on-device (install state); only if it *still* fails on a clean
  install is it a genuine regression to investigate (capture the exact GoTrue
  error — `aud`/`nonce`/`rp`/`audience` — from the device console, don't guess).
- The server-side AASA fix is permanent; once the device cache is refreshed it
  will not recur on normal TestFlight updates. It only recurs if a future auth
  change ships without clearing/re-fetching the device association.
