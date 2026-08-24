# Sendmeter Native

A full, parallel SwiftUI implementation of the Sendmeter iPhone application.
It uses the same Supabase project and database schema as the existing
React/Capacitor client while keeping the currently shipped target unchanged.

## Why this lives in a parallel target

The native rewrite is intentionally additive. `native/SendmeterNative` can be
built, tested, and exercised on TestFlight without replacing or destabilizing
the production Capacitor target. Promotion should happen only after the native
target passes the physical iPhone/Apple Watch soak and latency gates described
in `docs/native-swift-rewrite.md`.

## Implemented product surfaces

- Password, magic-link, recovery-link, and passkey authentication
- Native tab/navigation, sheets, alerts, safe areas, Dynamic Type, and VoiceOver
- Dashboard readiness, ACWR, Training Block context, recent sessions, and load
- Phone climbing workouts with atomic Supabase persistence and optimistic History
- Guided routines compatible with the existing TypeScript JSON schema
- Direct CoreBluetooth Tindeq Progressor connection, tare, battery, disconnect recovery, and live SwiftUI Canvas trace
- Free pulls, static guided protocols, alternating sides, Reverse Action cadence, per-set holds, fixed/%PR/%CF/Hill-curve targets, and complete protocol metadata
- Account-scoped atomic on-device queue with stable IDs, retry backoff, and bounded diagnostic breadcrumbs
- Combined session + force History timeline (#630): filter chips, loose-recording multi-select → new session, per-rep force charts, editing, linking, soft-delete Trash, restore, and confirmed permanent deletion
- Training Block transitions with same-day undo semantics
- Apple Health readiness through the repository's existing `SendLogHealthCore`
- Direct WatchConnectivity mirroring, access-token-only relay, and pending workout reconciliation
- Account, passkey, device, queue, and destructive account-management settings
- Lock-screen Live Activity mirror for guided Force protocols (#674): the
  current segment counts down natively, the Dynamic Island tap deep-links to
  the Force tab, and the card is kept in sync through stage changes, Skip
  Stage, hold-end peaks, and run completion
- Lock-screen Live Activity mirror for manual phone workouts (#763): the
  CLIMBING/RESTING timer ticks natively, the Dynamic Island tap deep-links to
  the Workout tab, Stop/Boulder actions route back into the engine, and the
  card ends on finish, cancel, or relaunch

## Architecture

```text
SwiftUI application
├── Sources/Core       Pure models, metrics, force curve, protocol, queue, state engines, and account-scoped local read cache (GRDB/SQLite with local/server write-origin LWW and monotonic revision-guarded server confirmation, #747)
├── Sources/Data       Supabase auth and typed PostgREST repositories
├── Sources/Platform   CoreBluetooth, HealthKit, and WatchConnectivity
├── Sources/Features   Native product screens
├── Sources/Shared     ActivityKit wire type shared verbatim with the widget appex (#674)
├── Sources/Widgets    The WidgetKit app-extension target's rendering code (#674)
└── Sources/App        App lifecycle, orchestration, design system, and optimistic reconciliation
```

`AppModel` hydrates its published lists from the account-scoped cache before
any remote fetch, so a cold start renders the last-known sessions, recordings,
workouts, presets, routines, phase periods, health rows, settings, and tag
metadata immediately. Successful full and realtime-slice refreshes reconcile
through the same cache. Foreground refreshes ask each cache entity for only the
rows changed after its persisted `updated_at` cursor, apply active changes and
soft-delete tombstones as a single batch, and advance the cursor only after the
cache write succeeds; the first sync after install or cache rebuild still does
a full hydration so a missing or reset cursor can never strand older rows.
Realtime slices continue through the same reconcile path before the published
state changes, so a watch/other-device edit survives a relaunch without waiting
for the next foreground pull. When the app backgrounds, a `BGAppRefreshTask`
drains the durable queue and pulls the same cursor-bounded deltas for all nine
read entities, then re-arms itself; the account/epoch guard is re-checked after
every await and task expiration cancels before a cache write starts. BGTask
timing is device-only to verify (simulators do not run scheduled refresh tasks).
User-initiated creates/edits/deletes are written optimistically and confirmed
only when the matching server revision still wins; a cache open/read failure
degrades to the existing network-only path and is reported in the auth
diagnostics ring.

`Sources/Shared` + `Sources/Widgets` compile into a second product target —
`SendmeterNativeWidgets`, a WidgetKit app-extension embedded in the app
bundle — in the same XcodeGen project. The extension renders the guided
protocol and manual-workout lock-screen Live Activities; it shares
`GuidedProtocolActivityAttributes` and `ManualWorkoutActivityAttributes` (from
`Sources/Shared`) with the app and intentionally has no SendmeterCore
dependency: the app pushes the `ContentState` and the widget renders it
(`Sources/App/GuidedProtocolActivityManager.swift` and
`Sources/App/ManualWorkoutActivityManager.swift` own the activities).

The reusable `SendmeterCore` package has no iOS UI dependency and is tested on
Linux and macOS. The application target uses local packages already maintained
in the repository for Watch and recovery-domain parity.

## Generate and build

Requirements:

- Xcode 16 or newer
- XcodeGen 2.40 or newer
- Swift 5.9 or newer

```bash
cd native/SendmeterNative
swift test
xcodegen generate
xcodebuild \
  -project SendmeterNative.xcodeproj \
  -scheme SendmeterNative \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a physical device, open `SendmeterNative.xcodeproj`, select the existing
Sendmeter development team and signing profile, then run the `SendmeterNative`
scheme. The bundle identifier is the distinct `com.jirathip.sendlog.native`
(#637) so the two clients ship side-by-side on TestFlight without one replacing
the other's builds — a consequence is that the native iOS app does not pair
with the watch companion (WCSession pairing is bundle-ID-prefix-based), so the
live-workout mirror falls back to the realtime server path. Promotion to the
shipped `com.jirathip.sendlog` is a separate decision.

## Verification

The pull request runs:

1. Pure Swift unit tests.
2. XcodeGen project generation.
3. A complete iOS Simulator compile with code signing disabled.
4. Existing repository quality checks where applicable.

Automated checks do not replace the physical-device gates for real Bluetooth,
HealthKit, WatchConnectivity, passkeys, background/suspension behavior, or a
multi-day authentication soak.
