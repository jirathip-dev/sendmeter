# Native Swift rewrite

## Scope

`native/SendmeterNative` is a feature-complete parallel iPhone client written in
SwiftUI. It shares the production data model and the existing Watch app, but it
does not modify the shipped Capacitor target. This isolation is the primary
regression-control mechanism: the rewrite can fail validation without changing
the current release.

## Compatibility contracts

The native client preserves the existing product contracts rather than creating
new equivalents:

- Existing Supabase tables, RPCs, RLS ownership, stable UUIDs, and snake-case JSON
- Existing session, phase, health, Tindeq, preset, routine, workout, Trash, and account semantics
- `supabase-swift` is the only phone refresh-token owner; Watch receives access tokens only
- WatchConnectivity is the low-latency mirror, while Supabase and durable queues remain authoritative recovery paths
- Optimistic rows appear only after an atomic local queue write succeeds
- Queued data is account-scoped and cannot be cleared with an unresolved user
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

The branch adds only a new directory and workflow. Reverting the native commit
removes the experimental target without altering the current app, database, or
Watch target.

## TestFlight distribution (#637)

The native app gets its own CI distribution path so it can be installed on a
real iPhone without touching the shipped app's release channel.

**Bundle-ID decision: `com.jirathip.sendlog.native` — a distinct app, never
the shipped ID.** Evidence:

- TestFlight allows one app per bundle ID. Uploading the native build under
  `com.jirathip.sendlog` would land it in the *shipped* app's slot — replacing
  the Capacitor app's TestFlight builds, consuming its build-number train, and
  pushing the current release candidate off testers' phones. The native target
  is pre-promotion (the promotion gates above), and the project's core rule is
  "keep the production target untouched", so the same-ID path is rejected.
- The distinct ID does break one thing, deliberately: **the direct
  WatchConnectivity mirror**. WCSession pairs an iOS app with the watch app
  whose bundle ID derives from the iOS app's ID (Apple's own Watch
  Connectivity sample: `com.YourCompany.ProductName` ↔
  `com.YourCompany.ProductName.watchkitapp`). The watch app is
  `com.jirathip.sendlog.watchkitapp`; `com.jirathip.sendlog.native` is not a
  prefix of it, so the native phone app's `WCSession.isWatchAppInstalled` is
  false and the low-latency mirror is inactive. The native app's
  `LiveWorkoutMirror` already has a `server-fallback` (realtime) path, so the
  app stays fully usable; watch-mirror validation is a promotion gate anyway
  and happens when the native app takes over the real bundle ID. The watch
  keeps working with the shipped app, unchanged.
- Coexistence: both apps install side-by-side on one device (different bundle
  IDs). One caveat: both declare the `com.jirathip.sendlog://` URL scheme
  (static in `Resources/Info.plist`, which is not bundle-ID-derived), so with
  both installed the scheme resolves to whichever app was installed last.
  Supabase auth redirects and passkeys keep working — the scheme itself never
  changes.

**What ships it (dispatch-only workflow `native-testflight.yml` →
`bundle exec fastlane native_beta`):**

1. API key + cert setup — same CI-safe discipline as `beta` (`setup_ci` +
   import `IOS_DIST_CERT_P12` into a temp keychain on CI; `get_certificates`
   locally).
2. `xcodegen generate` the project (only `project.yml` is committed).
3. Idempotently create the App ID, enable the capabilities the entitlements
   need (HealthKit, Sign in with Apple, Associated Domains — via the Connect
   API, so there is **no manual portal step**), and create the ASC app record
   (SKU `SENDMETER-NATIVE`).
4. `get_provisioning_profile` (force) for the new App ID.
5. Build number = latest TestFlight build of *this* app + 1 (its own train —
   never races `beta`), injected via `CURRENT_PROJECT_VERSION` xcargs; never
   hand-bump `project.yml`.
6. Archive with manual signing pinned on the generated project (single
   target, so no pbxproj-restore dance is needed — the project is regenerated
   each run); the auth flags stay export-only, same as `beta`, so the archive
   can never mint signing assets.
7. `upload_to_testflight`.

**One-time manual steps (first upload only):** add the tester (Guy) as an
internal tester of the *new* "Sendmeter Native" app in App Store Connect —
internal testers are per-app, so the shipped app's tester list does not carry
over. Everything else (App ID, capabilities, app record, profile, build
number) is automated by the lane.

**Workflow:** `native-testflight.yml` is dispatch-only (macOS runner minutes
are the dominant CI cost), uses the same `testflight` GitHub environment as
the shipped lane (match the capitalisation exactly), the same
`blacksmith-6vcpu-macos-26` runner input, a `native-testflight` concurrency
group (queue, never cancel — parallel runs would race the same build number),
and a cheap Ubuntu gate that refuses refs without
`native/SendmeterNative/project.yml` (the native target is not on `main`
yet). No node/npm steps — the native app is pure Swift.

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
  decisive retest is: delete Sendmeter Native → reinstall the same build → first
  open cold → try Sign in with Apple. If it passes, close the issue as
  resolved-on-device (install state); only if it *still* fails on a clean
  install is it a genuine regression to investigate (capture the exact GoTrue
  error — `aud`/`nonce`/`rp`/`audience` — from the device console, don't guess).
- The server-side AASA fix is permanent; once the device cache is refreshed it
  will not recur on normal TestFlight updates. It only recurs if a future auth
  change ships without clearing/re-fetching the device association.
