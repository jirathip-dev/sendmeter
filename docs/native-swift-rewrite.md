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
