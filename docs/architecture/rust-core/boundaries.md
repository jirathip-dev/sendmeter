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
                    ▲    ▲
          sm-ffi-swift  sm-ffi-web
                ▲            ▲
   iPhone app (Swift)     web/ (TypeScript)        Watch app ──▶ SendLogWatchCore, SendLogHealthCore
   mcp/ ──▶ the export folder                       (no Rust, no Blocks screens, no CloudKit)
```

## Crates

| Crate | Owns | May depend on | Must not |
|---|---|---|---|
| `sm-domain` | Ids, `Stamp` and days, units, grades, the row types, the `ble` contract, validation at the edges | serde | everything else of ours |
| `sm-stats` | Load, ACWR and its projection, zone mix, readiness (baseline, recovery engine, health precedence), grade pyramid, box-plot and curve summaries | `sm-domain` | SQLite, Blocks |
| `sm-force` | Tindeq byte format and link machine, the force engine, the curve fit, the guided protocol, hands-free control | `sm-domain` | SQLite, Blocks |
| `sm-boards` | #1047's `BoardCore`: layouts, routes, the LED map, both lighting encoders, the link machine, the wiring check, the two file readers, the screenshot reader (#1056) | `sm-domain` | SQLite, Blocks, any network |
| `sm-store` | The SQLite file, the migrations, reads, write commands, the eight former RPCs, the change log, the export bundle, the legacy-import mapping | `sm-domain`, `sm-boards` (types), rusqlite | Blocks, `sm-sync` |
| `sm-sync` | `CloudRecord`, the conflict rules, `SyncState` and `reduce`, batches, the web's poll engine, the CloudKit schema writer | `sm-store`, `sm-domain` | Blocks, any network or CloudKit type |
| `sm-screens` | One file per screen: input → `Block`, action → intent; the look's tokens; the tab layout | `blocks`, `sm-domain`, `sm-stats`, `sm-boards` | SQLite, `sm-store`, `sm-sync` |
| `sm-app` | `open`, `handle`: loads a screen's input, runs intents as store commands, keeps shown screens and answers with ops, runs the live sessions | every crate above | UniFFI, wasm-bindgen, any OS call |
| `sm-ffi-swift` | The UniFFI surface: `open`, `handle`, the event and effect types | `sm-app`, uniffi | logic |
| `sm-ffi-web` | The wasm-bindgen surface: `open`, `handle` over JSON; installs the browser file layer | `sm-app`, wasm-bindgen, the SQLite WASM file layer | logic |

`sm-screens` is pure on purpose: a screen test builds a value and compares it with the approved design's JSON,
with no store. `sm-app` is the only crate that sees both data and screens.

## The iPhone app (Swift)

| Module | Owns | May import | Must not |
|---|---|---|---|
| `App` | Lifecycle, `CoreHost` (the actor that owns the core and carries out effects), the tab view | `SendmeterRust`, Features, Platform, Data | CloudKit, CoreBluetooth, SQLite |
| `Features/ScreenHost` | One generic view: `BlocksView`, ops, actions, navigation, sheets, the look from tokens | BlocksUI, `SendmeterRust` | any screen's content |
| `Features/Kinds` | `BoardKind`, `MascotKind`: one file per app kind | BlocksUI, SwiftUI | the core |
| `Features/Live` | The live recording, force and routine views (SwiftUI), drawn from `LiveFrame` | SwiftUI, BlocksUI | deciding anything: reps, peaks and targets come from the core |
| `Platform` | `HealthKitService`, `TindeqBluetooth`, `BoardBluetooth`, `WatchLink`, weather: each turns OS callbacks into events and commands into OS calls | the OS frameworks, `SendmeterRust` types | each other, CloudKit |
| `Data/CloudKit` | `CloudKitTransport` over `CKSyncEngine` | CloudKit, `SendmeterRust` types | any rule |
| `Data/LegacyImport` | The PostgREST reader and sign-ins (#1045, kept); rows go to the core as `LegacyRows` | Foundation, AuthenticationServices | any Supabase package |
| `Shared`, `Widgets` | ActivityKit types, the widgets | `SendLogHealthCore` (the widget contract) | the core |
| Watch app | Everything it has today, minus Supabase (#1045) | `SendLogWatchCore`, `SendLogHealthCore` | Rust, CloudKit |

Enforcers: the `[[ban]]` lines in `adr.md` (`drover arch-check`), and linking: the watch and widget targets do
not link `SendmeterRust`.

## The web app (TypeScript, no framework)

| File | Owns | Must not |
|---|---|---|
| `web/src/main.ts` | Boot, the device's abilities, Blocks' shell on the core as its local source | hold data; decide anything |
| `web/src/worker.ts` | Loads the WASM, hands it the browser file system, relays events and effects; the one-tab lock | anything else |
| `web/src/cloud.ts` | CloudKit JS: sign-in, fetch zone changes, save, delete; `CloudRecord` ↔ CloudKit's record object | any rule |
| `web/src/ble.ts` | Web Bluetooth: `BleCommand` → browser calls, browser events → `BleEvent` | any byte format |
| `web/src/files.ts` | File picker, download, an image to pixels | parsing |
| `web/src/kinds/*.ts` | `board`, `mascot`, `apple-sign-in`: one file per app kind | the core |
| `web/src/sw.ts` | The offline cache of the built files | data |

## What Swift keeps, and what goes

| | |
|---|---|
| **Stays Swift** | HealthKit, CoreBluetooth, `CKSyncEngine`, WatchConnectivity, ActivityKit and the widgets, weather, the watch app, the live SwiftUI views and their presentation helpers (haptics, keep-awake, the splash, plot geometry), the legacy-import reader |
| **Stays Swift for the watch and widgets only** | `SendLogWatchCore` (attempt detection, the watch's RPE model, its Tindeq and force code, the handoff types, the palette) and `SendLogHealthCore` (the watch's readiness, the widget contract). The phone app stops calling their maths |
| **Moves to Rust** | From `Sources/Core`: models, metrics, training load, ACWR, phases, tags, history and dashboard derivations, the force and workout engines, the guided protocol, unit and mass formatting, validation. From #1045: the store, the sync rules, the export, the import mapping. From #1047: all of `BoardCore`. From #1045 and #1046: every screen |
| **Deleted, never ported** | Everything `local-first/boundaries.md` lists under "Deleted", plus `LocalCacheStore` and GRDB, `Data/Repositories.swift`, `AppModel.swift`, today's `Features/Dashboard`, `History`, `Phases`, `Settings`, `Workout` and `Force` screens, and `DesignSystem.swift` where the live views do not need it |

## New dependencies (open question 3)

| What | Where | Why |
|---|---|---|
| `blocks` (git, pinned commit; the Swift package and the web files at the same commit, checked by `just pins`) | `sm-screens`, the app, `web/` | Screens |
| `serde`, `serde_json` | all crates | Rows, Blocks, events on the web |
| `rusqlite` (its own SQLite), `sqlite-wasm-rs`, `sqlite-wasm-vfs` | `sm-store`, `sm-ffi-web` | The store; the browser file layer |
| `uniffi` | `sm-ffi-swift` | The Swift bridge |
| `wasm-bindgen`, `wasm-bindgen-futures`, and `wasm-bindgen-cli` at the same version | `sm-ffi-web`, the build | The web bridge |
| `uuid` | `sm-domain` | Ids on both platforms |
| `ts-rs` (build only) | `sm-app` | `web/src/gen/core.d.ts` |
| `esbuild`, `typescript`, `playwright` (dev only) | `web/` | Bundle, type-check, headless tests |
| Apple's CloudKit JS, loaded from Apple at sign-in | `web/` | Sign-in and the private database |
| Vercel's CLI | `web.yml` only | Uploading the built files |
| A pinned Rust toolchain with the iOS and WASM targets (`rust-toolchain.toml`), `cargo-deny` | repo, CI | Build; licence and advisory check |

Removed: GRDB, the Supabase Swift package, `@supabase/supabase-js` in `mcp/`.
