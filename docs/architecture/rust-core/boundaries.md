# Module boundaries

An arrow reads "may depend on". Nothing depends upward. Between crates the compiler is the enforcer: a crate
cannot use what its `Cargo.toml` does not list.

```
                       blocks (pinned commit)
                            ▲
sm-domain ◀── sm-stats      │
    ▲   ▲──── sm-force      │
    │   ▲──── sm-boards ◀── sm-screens ──▶ sm-stats
    │            ▲              ▲
    └── sm-store ┘              │
           ▲                    │
        sm-sync                 │
           ▲                    │
           └────── sm-app ──────┘──▶ sm-force, sm-stats
                     ▲
               sm-ffi-swift
                     ▲
            iPhone app (Swift)          Watch app ──▶ SendLogWatchCore, SendLogHealthCore
```

## Crates

| Crate | Owns | May depend on | Must not |
|---|---|---|---|
| `sm-domain` | Ids, `Stamp` and days, units, grades, the row types, the `ble` contract, validation at the edges | serde, uuid | everything else of ours |
| `sm-stats` | Load, ACWR and its projection, zone mix, readiness (baseline, recovery engine, health precedence), the send-conditions score, grade pyramid, box-plot summaries, the force curve fit, and the personal force model (#1065 designs it) | `sm-domain` | SQLite, Blocks |
| `sm-force` | Tindeq byte format and link machine, the force engine, the guided protocol, hands-free control | `sm-domain` | SQLite, Blocks |
| `sm-boards` | #1047's `BoardCore`: layouts, routes, the LED map, both lighting encoders, the link machine, the wiring check, the two file readers, the screenshot reader (#1056) | `sm-domain` | SQLite, Blocks, any network |
| `sm-store` | The SQLite file, the migrations, the queries, write commands, the eight former RPCs, the change log, the export bundle | `sm-domain`, `sm-boards` (types), rusqlite | Blocks, `sm-sync` |
| `sm-sync` | `CloudRecord`, the conflict rules, `SyncState` and `reduce`, batches | `sm-store`, `sm-domain` | Blocks, any network or CloudKit type |
| `sm-screens` | One file per screen: input → `Block`, action → intent; the look (a scheme per mode and a style file, in `look/`); the tab layout | `blocks`, `sm-domain`, `sm-stats`, `sm-boards` | SQLite, `sm-store`, `sm-sync` |
| `sm-app` | `open`, `handle`: loads a screen's input, runs intents as store commands, keeps shown screens and answers with ops, runs the live sessions | every crate above | UniFFI, any OS call |
| `sm-ffi-swift` | The UniFFI surface: `open`, `handle`, the event and effect types | `sm-app`, uniffi | logic |

`sm-screens` is pure on purpose: a screen test builds a value and compares it with the approved design's JSON,
with no store. `sm-app` is the only crate that sees both data and screens.

No crate is async, reads a clock, or starts a thread (enforcers: the `async fn` and `std::time` bans in
`adr.md`; `core/deps` lists every dependency, and no runtime is on the list).

## The iPhone app (Swift)

| Module | Owns | May import | Must not |
|---|---|---|---|
| `App` | Lifecycle; `CoreHost`, the actor that owns the core, orders events and hands out effects; `Shown`, what the views read; the tab view | `SendmeterRust`, Features, Platform, Data | CloudKit, CoreBluetooth, SQLite |
| `Features/ScreenHost` | One generic view: `BlocksView`, ops, actions, navigation, sheets, the look from tokens | BlocksUI, `SendmeterRust` | any screen's content |
| `Features/Kinds` | `BoardKind`, `MascotKind`: one file per app kind | BlocksUI, SwiftUI | the core |
| `Features/Live` | The live recording, force and routine views (SwiftUI), drawn from `LiveFrame`; each fits one screen | SwiftUI, BlocksUI | deciding anything (reps, peaks and targets come from the core); `ScrollView` |
| `Platform` | `HealthKitService`, `TindeqBluetooth`, `BoardBluetooth`, `WatchLink`, weather: each turns OS callbacks into events and commands into OS calls | the OS frameworks, `SendmeterRust` types | each other, CloudKit |
| `Data/CloudKit` | `CloudKitTransport` over `CKSyncEngine` | CloudKit, `SendmeterRust` types | any rule |
| `Shared`, `Widgets` | ActivityKit types, the widgets | `SendLogHealthCore` (the widget contract) | the core |
| Watch app | What `ports.md` keeps of it: no Supabase, no upload queues; its live views in `Views/Live` | `SendLogWatchCore`, `SendLogHealthCore` | Rust, CloudKit, `ScrollView` in `Views/Live` |

Enforcers: the `[[ban]]` lines in `.drover/arch.toml` (#1049's and this ADR's, checked by `core/arch`), and
linking: the watch and widget targets do not link `SendmeterRust`.

## What Swift keeps, and what goes

File by file, with the slice that ports or reworks each: `ports.md`.

| | |
|---|---|
| **Stays Swift** | HealthKit, CoreBluetooth, `CKSyncEngine`, WatchConnectivity, ActivityKit and the widgets, weather, the watch app, the live SwiftUI views and their presentation helpers (haptics, keep-awake, the splash, plot geometry) |
| **Stays Swift for the watch and widgets only** | `SendLogWatchCore` (attempt detection, the watch's RPE model, its Tindeq and force code, the handoff types, the palette) and `SendLogHealthCore` (the watch's readiness, the widget contract). The phone app stops calling their maths |
| **Moves to Rust** | From `Sources/Core`: models, metrics, training load, ACWR, phases, tags, history and dashboard derivations, the force and workout engines, the guided protocol, unit and mass formatting, validation. From #1045: the store, the sync rules, the export. From #1047: all of `BoardCore`. From #1045 and #1046: every screen |
| **Deleted by #1066, never ported** | Everything `ports.md` does not list: what `local-first/boundaries.md` lists under "Deleted", `LocalCacheStore` and GRDB, all of `Sources/Data`, `AppModel.swift`, every screen in `Sources/Features`, `DesignSystem.swift`, the app-target and UI tests, `supabase/` but the files A3 ports, `mcp/`. And #1045's import: no reader, no mapping, no sign-in |

## Dependencies (approved by the owner, q3124; nothing else without asking)

| What | Where | Why |
|---|---|---|
| `blocks` (git, pinned commit; the Swift package at the same commit, held equal by a test) | `sm-screens`, the app | Screens |
| `serde`, `serde_json` | all crates | Rows, Blocks screens and ops, the watch's JSON |
| `rusqlite` (bundled SQLite) | `sm-store` | The store |
| `uniffi` (its binding generator is the same crate) | `sm-ffi-swift` | The Swift bridge |
| `uuid` | `sm-domain` | Ids |
| A pinned Rust toolchain with `aarch64-apple-ios` and `aarch64-apple-ios-sim` (`rust-toolchain.toml`) | repo, CI | Build |
| `cargo-deny` | `rust/deny` | Advisory, licence and source check |

Each is listed with its reason in `.gatekeeper/deps.toml` by the slice that first uses it. Where a slice grows
`Cargo.lock` by more than that file's limit of 10 packages (R2 with UniFFI, A1 with rusqlite, N1 with Blocks),
its commit message carries `Deps: #1059` and the owner's answer q3124, as `core/deps` asks. Errors are plain
enums written by hand; tests use an in-memory store, so no test helper crate is needed.

Removed by #1066: GRDB, the Supabase Swift package, and `@supabase/supabase-js` with `mcp/`.

Not a dependency: swag. The look is the app's own scheme and style files, which Blocks takes directly. The
design recipe's swag pin (`.drover/design.md`) is a design lane's tool, not part of the app.
