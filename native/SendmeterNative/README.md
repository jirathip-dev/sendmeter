# Sendmeter Native

A full, parallel SwiftUI implementation of the Sendmeter iPhone application.
It uses the same Supabase project and database schema as the existing
React/Capacitor client while keeping the currently shipped target unchanged.

## Why this lives in a parallel target

The native rewrite is intentionally additive. `native/SendmeterNative` can be
built, tested, and exercised on TestFlight without replacing or destabilizing
the production Capacitor target. The native rewrite currently requires iOS 17
because its per-property Swift Observation model uses `@Observable`; the
reusable `SendmeterCore` package remains iOS 16-compatible. Promotion should
happen only after the native
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

The generated project also has a `SendLogWatch Watch App` watchOS target. It
reuses the existing companion sources from `ios/App/SendLogWatch Watch App`,
links the same `SendLogWatchCore` and Supabase packages used by the Capacitor
target, and embeds the existing `SendLogWatchWidgets` target without copying
its sources or rendering logic. The watch app is automatically copied into
`SendmeterNative.app/Watch` by the native app's `Embed Watch Content` phase,
and the watch-widget appex is copied into the watch app's foundation-extension
destination. The Release phone bundle ID is `com.jirathip.sendlog`, matching
the watch Info.plist's `WKCompanionAppBundleIdentifier`; this is the bundle
relationship intended for WatchConnectivity pairing.

`AppModel` hydrates its observable lists from the account-scoped cache before
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

`TindeqBluetooth` keeps a stable `ForceSampleBuffer` while a display-rate
flush observes only the visible index range. The live Canvas chart reads that
range directly from the buffer, so BLE notifications append samples without
allocating a new visible-window array. The force accumulator still owns the
monotonic clock handling, running peak/sum, and bounded recording history.

Watch `workoutCompleted` summaries follow the same account-scoped boundary: the
phone retains a bounded, persisted inbox keyed by `(sessionID, workoutID)`,
adopts each valid completion into the cache as a server-origin pending session,
and publishes that History row immediately after reading it back durably.
Repeated direct and `transferUserInfo` deliveries therefore stay one row, and
the persisted inbox entry is acknowledged only after adoption succeeds. If
the cache is unavailable or its row is corrupt, the same summary remains a
visible in-memory pending row and the inbox is retried on foreground; it is
never acknowledged without durable adoption. A later session delta replaces
the placeholder with the authoritative server row, while an authoritative full
session refresh retires an absent placeholder after seven days via a tombstone
so a permanent phantom cannot count toward training load. `live_workouts`
remains a separate realtime mirror and is not cached.

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
scheme. Release/TestFlight builds use the shipped `com.jirathip.sendlog` bundle
ID and include `com.jirathip.sendlog.watchkitapp` inside the archive, so
installing the phone app also installs the companion on a paired Apple Watch.
The Debug configuration uses the native-only IDs
`com.jirathip.sendlog.native`, `com.jirathip.sendlog.native.watchkitapp`, and
`com.jirathip.sendlog.native.watchkitapp.widgets`; the Debug companion points
back to the Debug phone, so the native trio can be installed side-by-side
without colliding with the shipped IDs. Direct live-workout mirroring and the
absence of a realtime fallback are device-only checks on a signed Release
build.

## Verification

The pull request runs:

1. Pure Swift unit tests.
2. XcodeGen project generation.
3. Generated-project assertions for watch/widget source and resource
   membership, entitlements exclusion, package links, and embed destinations
   (`scripts/assert-native-watch-project.rb`).
4. A complete iOS Simulator compile with code signing disabled.
5. Existing repository quality checks where applicable.

Automated checks do not replace the physical-device gates for real Bluetooth,
HealthKit, WatchConnectivity, passkeys, background/suspension behavior, or a
multi-day authentication soak.
