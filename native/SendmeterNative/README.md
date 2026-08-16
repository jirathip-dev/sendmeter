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

## Architecture

```text
SwiftUI application
├── Sources/Core       Pure models, metrics, force curve, protocol, queue, and state engines
├── Sources/Data       Supabase auth and typed PostgREST repositories
├── Sources/Platform   CoreBluetooth, HealthKit, and WatchConnectivity
├── Sources/Features   Native product screens
└── Sources/App        App lifecycle, orchestration, design system, and optimistic reconciliation
```

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
scheme. The bundle identifier deliberately matches the existing app, so the two
clients cannot be installed simultaneously on one device.

## Verification

The pull request runs:

1. Pure Swift unit tests.
2. XcodeGen project generation.
3. A complete iOS Simulator compile with code signing disabled.
4. Existing repository quality checks where applicable.

Automated checks do not replace the physical-device gates for real Bluetooth,
HealthKit, WatchConnectivity, passkeys, background/suspension behavior, or a
multi-day authentication soak.
