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
- Free pulls with a dedicated live fullscreen, static guided protocols, alternating sides, Reverse Action cadence, per-set holds, fixed/%PR/%CF/Hill-curve targets, selected target bands on Force history/duration charts, and complete protocol metadata
- Account-scoped atomic on-device queue with stable IDs, retry backoff, durable failure diagnostics, and pending session/manual-workout delete barriers
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
phone retains a bounded, persisted inbox keyed by `(account_user_id,
sessionID, workoutID)`, quarantines ownerless legacy payloads, and adopts each
valid completion into the cache as a server-origin pending session,
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

The regular Force fullscreen is a viewport over those same `TindeqBluetooth`
and `AppModel` owners: minimizing leaves the stream, keep-awake hold, locked
recording attribution, disconnect salvage, and durable save path untouched.
Guided protocols remain the only other stream owner; an armed-but-idle
hands-free stream is handed back synchronously before a guided run starts, and
an active pull is refused. The selected target plan is resolved once for the
current exercise/side/protocol and its set-1 band is shared by the live gauge,
fullscreen coach, progress detail, and Force duration/trend charts.

### Account isolation and conflict contract (#747)

Every native read/write boundary carries both the owning `account_user_id` and
the current `accountEpoch`. A normal sign-out, token expiry, or account switch
advances the epoch and clears the visible in-memory snapshot immediately, but
keeps that account's valid cache rows, queued writes, and stamped watch
completions on disk. The next sign-in can restore only its own namespace; an
older async result is rejected even after the same user signs back in. Account
deletion is different: its epoch barrier is installed before the first await,
and the exact account's queue/cache is purged only after the server deletion
has succeeded. Auth or network failure parks data instead of destroying it.

Watch completion summaries, live beats, and account-owned queue telemetry
require an owner stamp. Pre-stamp/unstamped legacy payloads remain in a
separately bounded diagnostic bucket (`watch_unscoped_sync`) and are visible as
legacy items needing review, but are never attributed to or retried for the
currently signed-in user.
`live_workouts` is intentionally not cached, so it cannot become a cold-launch
cross-account row; it is accepted only from the current realtime/WC owner.

Conflict resolution is deliberately narrow and testable: a pending local
upsert or tombstone wins over a stale full refresh; a server acknowledgement
can clear a local pending row only when its origin and captured local revision
still match; authoritative deltas win for non-pending server rows; and a
cursor advances only after the corresponding cache writes and tombstone
reconciliation complete. Watch placeholders are server-origin pending rows,
are replaced by authoritative deltas/full refreshes, and are tombstoned after
their bounded seven-day absence window. This is client-side LWW and ownership
protection, not a replacement for Supabase RLS or a guarantee that background
tasks and WatchConnectivity delivery will run.

Acceptance coverage is split explicitly:

- Automated Core/store tests cover cold-cache/account separation, optimistic
  local writes, queue/cache separation, epoch-invalidated completions, watch
  owner stamps including unstamped legacy quarantine, LWW acknowledgements,
  placeholder convergence, cursor ordering, and exact-account purge races.
  AppModel deletion/auth wiring is additionally covered by structural checks;
  its end-to-end ordering still needs a device/integration run.
- Device/E2E verification remains necessary for real HealthKit ingestion,
  Bluetooth, WatchConnectivity delivery, background scheduling/suspension,
  realtime reconnects, passkeys, and signed account-switch behavior.

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

## Native Swift source quality

The native source is linted with a vendored copy of
[sawfwair/anti-slop-swift](https://github.com/sawfwair/anti-slop-swift), pinned
at upstream revision `259e1a32dd9a41e65478513ab3b902a1cb8036e0`. The pre-fix
baseline on Swift 6.3.3 was **53 violations across 134 files and four rule
types**: 21 `no-any-dictionary-value`, 14 `no-force-unwrap`, 10
`no-any-parameters`, and 8 `no-swallowed-errors`.

The committed `.anti-slop.json` disables exactly `no-any-dictionary-value` and
`no-any-parameters`. WatchConnectivity's system API requires `[String: Any]`
payload bridges and `Any?` callback parameters, so those two rules are
intentional exceptions while the remaining rules stay enabled. The CI step is
advisory for findings: it annotates violations as GitHub warnings without
blocking this first pass, while missing paths/configuration or a tool-build
failure remains a real CI failure.

Run the same pinned executable locally from the repository root:

```bash
bash scripts/anti-slop-swift.sh native/SendmeterNative/Sources
```

The native workflow also runs the cold-build regression, which removes the
vendored tool's debug products before invoking the wrapper and requires both a
successful rebuild and its positive scanned-file signal. Run it locally with:

```bash
bash scripts/validate-anti-slop-cold.sh
```

When a force unwrap, cast, try, or process-termination primitive is genuinely
required, put a specific `// SAFETY:` explanation in the contiguous comment
block immediately above it. Prefer an explicit unwrap or error path whenever
the invariant is not independently guaranteed.

## Verification

The no-Xcode source gate can be run from the repository root:

```bash
bash scripts/validate-native-static.sh
```

It parses every native application, widget, Core, and test Swift file with
`swiftc -parse`, generates a temporary XcodeGen project, checks that the Force
files are present in the app target, and verifies the recording-context and
fullscreen accessibility invariants. This is a local supplemental gate; PR CI
separately runs:

1. Pure Swift Core tests.
2. XcodeGen project generation and Swift package resolution.
3. Generated-project assertions for watch/widget source and resource
   membership, entitlements exclusion, package links, and embed destinations
   (`scripts/assert-native-watch-project.rb`).
4. A complete iOS Simulator compile with code signing disabled.
5. Existing repository quality checks where applicable.

`swift test` does not typecheck the SwiftUI application target: the package
target intentionally contains only `Sources/Core` plus `ChartTheme.swift`.
The static gate therefore proves parsing and generated-project inclusion, not
app-target type correctness. A clean Xcode project compile remains required
when the serialized Xcode lane is available; the regular Force fullscreen,
hands-free trigger/re-arm loop, disconnect salvage, and protocol handoff also
remain device-only with a real Progressor.

Automated checks do not replace the physical-device gates for real Bluetooth,
HealthKit, WatchConnectivity, passkeys, background/suspension behavior, or a
multi-day authentication soak.

The Debug watch/widget graph and unsigned generic iOS Simulator Debug build
are green. Fresh-derived-data Swift 6.3.3 Release archives reproduce the same
`swift-frontend` `SILDeserializer` crash with both WMO and the attempted
`singlefile` mode; no compiler-mode workaround is retained. Release and signed
archive verification remain a #768 shipping blocker.

The regular Force fullscreen, hands-free trigger/re-arm loop, disconnect
salvage, and protocol handoff need a real Progressor on a device for end-to-end
verification; simulator/static checks do not prove BLE behavior.
