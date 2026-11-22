# Rust core for iOS and web (#1059)

## Summary

Decision: one Rust core holds the data and its rules, the SQLite store, the sync rules, the stats, the force-gauge and board protocols, the file readers and every Blocks screen. The iPhone app links it through UniFFI and keeps only Apple's parts (Health, the Bluetooth radio, the iCloud link, the watch, the live views). A new web app on sendmeter.app runs the same core as WASM, saves in the browser, works with no Apple ID, and syncs to the same private iCloud database through CloudKit JS. Synced fields are plain CloudKit fields so the web can read them; the recovery inputs from Apple Health stay end-to-end encrypted and phone-only. The new app is built beside today's app and replaces it in one step.
Slices: 6 Blocks issues first (4 filed, 2 new), then 60 issues in 11 groups: foundation (3), ported maths (4), store (5), sync (5), new shell (3), screens (7), live views (5), boards (16), the rewritten #1048 and #1056 (2), switch-over and Supabase removal (9), web deploy (1). A screen is one Rust file drawn on both platforms.
Open questions: (1) May Apple Health values sit unencrypted in iCloud? Recommended: only the readiness score and workout heart rate; HRV, resting heart rate, sleep and weight stay encrypted and off the web. (2) An Apple ID with Advanced Data Protection may be refused web sign-in whatever the user turns on (one public test says so; Apple documents nothing): is "web stays local-only for those users" acceptable? (3) Approving this ADR approves the new dependencies listed in `boundaries.md`.

## Read in this order

| File | What |
|---|---|
| `adr.md` | The question, what was found, the eight decisions with their options, the consequences, the owner's actions, the open questions, the `arch.toml` lines |
| `usage.md` | How the calling code reads: a screen in Rust, the phone, the iCloud link, the web, a write |
| `shapes.md` | Events and effects, the Bluetooth contract, every synced record, what crosses a transport |
| `sync.md` | Who does what on each platform, how the two transports stay consistent, the web's statechart, what protects the data |
| `boundaries.md` | The ten crates, the Swift and web modules, what moves, stays and goes, the new dependencies |
| `blocks.md` | The run on iOS and in a browser, what Sendmeter needs from blocks #354, the two new Blocks issues |
| `supersedes.md` | #1045, #1046 and #1047 line by line: kept, changed, replaced; #1048 and #1056 rewritten |
| `migration.md` | The issues to file, in order |

## The shape in one picture

```
            iPhone                                    Browser (sendmeter.app, static files)
 ┌──────────────────────────────┐           ┌──────────────────────────────────────┐
 │ SwiftUI: tabs, ScreenHost,   │           │ page: Blocks' HTML renderer and shell│
 │ live views, BlocksUI         │           │ app kinds, CloudKit JS, Web Bluetooth│
 │ HealthKit · CoreBluetooth    │           │──────────── worker ──────────────────│
 │ CKSyncEngine · watch link    │           │                                      │
 │────────── UniFFI ────────────│           │──────────── wasm-bindgen ────────────│
 │  open(config)                │           │  open(config)                        │
 │  handle(event, time) → effects           │  handle(event, time) → effects       │
 │        the Rust core         │  same     │        the Rust core                 │
 │  screens · stats · sync rules│  crates   │  screens · stats · sync rules        │
 │  force · boards · store      │           │  force · boards · store              │
 │  SQLite file                 │           │  SQLite in the browser's file system │
 └──────────────┬───────────────┘           └──────────────────┬───────────────────┘
                └────── the user's private iCloud database ────┘
                         (plain fields; optional; no server of ours)
 Watch ── hands finished records to the phone (Swift, no Rust)
```

## What was run

Read on staging `67150de2`. Blocks at staging `73adae31`. Host: macOS 27.2, Xcode 27.2, Rust 1.100.0. Detail
and findings in `blocks.md`.

| Claim | Command | Exit |
|---|---|---|
| The probe core (SQLite store, Blocks screen, ops) passes on the host | `cargo test -p sm-probe` | 0 |
| It builds to WASM with SQLite inside: 2.54 MB, 0.87 MB gzipped | `cargo build --release --target wasm32-unknown-unknown`, `wasm-bindgen --target web` | 0 |
| A Blocks screen built in Rust is drawn by the HTML renderer from the WASM, takes real clicks, patches by ops, and keeps its data over a reload | `node web/run.mjs` in Chromium and WebKit, 9 checks each, run twice | 0 |
| It builds for iOS and links with BlocksUI into a simulator app | `cargo build --target aarch64-apple-ios-sim`, `uniffi-bindgen generate`, `swift build --triple arm64-apple-ios26.0-simulator` | 0 |
| The same screen is drawn by BlocksUI on iOS; Rust's ops applied in Swift give Rust's next screen; the store survives a relaunch | install and launch in an iOS 27.2 simulator (iPhone 17e), then read the app's own report: 6 checks, run twice | 0 |
| A private browser window gets no saved storage | the WebKit run without a profile: OPFS refused, the memory fallback passed | 0 |
| BlocksUI's `apply` changes an app block's `rows` field | the first iOS run, before the prop was renamed: 1 of 6 checks failed on exactly that field | 1 |
| The watch cannot use ready-built Rust | `rustup target list`: no `arm64_32-apple-watchos` | 0 |

Not run, and not claimed: CloudKit and `CKSyncEngine`, CloudKit JS sign-in and Advanced Data Protection,
HealthKit, CoreBluetooth and Web Bluetooth with real hardware, a real iPhone, real Safari, WatchConnectivity,
Vercel. Each slice that touches one says so in `migration.md`.
