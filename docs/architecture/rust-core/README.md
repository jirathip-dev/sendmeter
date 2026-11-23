# Rust core for the iPhone app (#1059)

## Summary

Decision: one Rust core holds the data and its rules, the SQLite store, the sync rules, the stats, the force-gauge and board protocols, the file readers and every Blocks screen. Swift keeps Apple's parts (Health, the Bluetooth radio, the iCloud link, the live session and force views) and the whole Watch app. The core is plain synchronous Rust on one background queue. Sync is native iCloud only, encrypted as #1045 approved. There is no web app. The new app is built beside today's and replaces it in one step. Every live session and force screen fits one screen with no scrolling, on iPhone and Watch. Rust is gated as strictly as cooee from its first crate.
Slices: 53 issues in 10 groups: foundation and gates (2), ported maths (4), store (5), sync (3), new shell (2), screens (7), live views (3), boards (16), the rewritten #1048 and #1056 (2), switch-over and Supabase removal (9). The four Blocks issues have landed; one Blocks bug is left to file and nothing waits on it.
Open questions: (1) The Watch app stays Swift and gets its data through the phone, because stable Rust ships no ready-built library for watches before Series 9. Accept that (recommended), or drop those watches? (2) The line cap must count Rust, and rise while both apps exist side by side (estimate: a peak near 145,000 lines, about 80,000 after the old app is deleted). Approve a cap issue before the first Rust PR?

## Read in this order

| File | What |
|---|---|
| `adr.md` | The question, what was found, the nine decisions with their options, the consequences, the owner's actions, the open questions, the `arch.toml` lines |
| `usage.md` | How the calling code reads: a screen, a query and its test, the phone's host, a live view, the iCloud link |
| `shapes.md` | Events and effects, the Bluetooth contract, every synced record, what crosses the transport |
| `sync.md` | Who does what, one sync turn, the statechart, how the transport is held honest, what protects the data |
| `boundaries.md` | The nine crates, the Swift modules, what moves, stays and goes, the dependencies |
| `blocks.md` | The run on iOS, where Blocks stands, the one bug to file |
| `supersedes.md` | #1045, #1046 and #1047 line by line: kept, changed, replaced; what the amendments withdrew from this issue; #1048 and #1056 rewritten |
| `migration.md` | The issues to file, in order |

## The shape in one picture

```
                    iPhone                                         Apple Watch
 ┌────────────────────────────────────────────┐        ┌──────────────────────────────┐
 │ SwiftUI: tabs, ScreenHost (BlocksUI),      │        │ Swift, as today, no Rust:    │
 │ live session and force views (one screen)  │        │ SendLogWatchCore,            │
 │ HealthKit · CoreBluetooth · CKSyncEngine   │◀──────▶│ SendLogHealthCore,           │
 │ WatchLink                                  │ records│ live views (one screen)      │
 │──── CoreHost: one queue, in order ─────────│ and a  └──────────────────────────────┘
 │──── UniFFI ────────────────────────────────│ snapshot
 │  open(config)                              │
 │  handle(event, time) → effects             │
 │        the Rust core (synchronous)         │
 │  screens · stats · sync rules              │
 │  force · boards · store                    │
 │  SQLite file                               │
 └──────────────────────┬─────────────────────┘
                        │
        the user's private iCloud database
     (encrypted fields; optional; no server of ours)
```

## What was run

Read on staging `d99394f2`. Blocks at staging `976cf0f6` (the probe ran at `73adae31`). Host: macOS 27.2,
Xcode 27.2, Rust 1.100.0. Detail and findings in `blocks.md`.

| Claim | Command | Exit |
|---|---|---|
| The probe core (SQLite store, Blocks screen, ops) passes on the host | `cargo test -p sm-probe` | 0 |
| It builds for iOS and links with BlocksUI into a simulator app | `cargo build --target aarch64-apple-ios-sim`, `uniffi-bindgen generate`, `swift build --triple arm64-apple-ios26.0-simulator` | 0 |
| A Blocks screen built in Rust is drawn by BlocksUI on iOS; Rust's ops applied in Swift give Rust's next screen; the store survives a relaunch | install and launch in an iOS 27.2 simulator (iPhone 17e), then read the app's own report: 6 checks, run twice | 0 |
| BlocksUI's `apply` changes an app block's `rows` field | the first iOS run, before the prop was renamed: 1 of 6 checks failed on exactly that field | 1 |
| The UniFFI bridge compiles with `unsafe_code` forbidden | `RUSTFLAGS="-F unsafe-code" cargo check -p sm-probe` | 0 |
| The watch cannot use ready-built Rust | `rustup target list`: no `arm64_32-apple-watchos` | 0 |
| Today's counted lines are under the cap | `./.gatekeeper/run check --gate core/cap` | 0 |

Not run, and not claimed: CloudKit and `CKSyncEngine`, Advanced Data Protection, HealthKit, CoreBluetooth with
real hardware, a real iPhone or Watch, WatchConnectivity, the live views at their smallest sizes. Each slice
that touches one says so in `migration.md`.
