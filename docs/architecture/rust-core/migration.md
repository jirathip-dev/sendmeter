# Migration order: the issues to file

One PR each. What landed with #1045 to #1047 is documents and mockups, and #1049 added the gates, so the
starting point is today's app on staging `d99394f2`: Swift, Supabase, gatekeeper, no Rust.

"Proof" is what the PR must run, as gates of `./.gatekeeper/run check`:

- **rust**: the rust pack and the `local/rust-*` gates (`adr.md`, decision 8). Linux, no simulator.
- **app**: `local/app` (the iOS build, the app-target tests, the UI smoke suite). macOS.
- **watch**: `local/watch`. **swift**: `local/coverage` (the three Swift packages).

"Device" marks what only a device can show: the PR says so and does not claim it.

Today's app keeps shipping from `main` until X3. Nothing before group X changes what a user sees: the new app
is reached only with the launch argument `-newCore` in debug builds.

## Before R1 (not lanes' work)

| # | What | Who |
|---|---|---|
| P1 | `cap:` issue: `ci/cap.toml` counts `crates/*/src/**/*.rs`; the cap covers the overlap (`adr.md`, open question 2) | the owner, through an orchestrator |
| P2 | Blocks: file G2 (`blocks.md`). Nothing waits on it | an orchestrator |

Blocks #351 to #354 have merged; N1 pins Blocks at `976cf0f6` or later, so no screen slice waits on Blocks.

## R. Foundation (no behaviour change)

| # | Issue | Scope | Proof |
|---|---|---|---|
| R1 | rust: the workspace and its gates | Root `Cargo.toml` with the lint floor, `rust-toolchain.toml` (1.99.1, the two iOS targets), `deny.toml`, `crates/sm-domain` (ids, `Stamp`, days, units, grades). In the same PR: `packs = ["core", "swift", "rust"]`, the `stable` and `msrv` legs, the six `local/rust-*` gate files, the `[cargo]` reasons in `.gatekeeper/deps.toml`, the Rust lines of `.drover/rules.md`, the R1 bans in `.drover/arch.toml`, the repo-map line and gate rows in `CLAUDE.md` | `./.gatekeeper/run list` shows every gate of decision 8; `./.gatekeeper/run check` passes |
| R2 | rust: the door and the Swift bridge | `sm-app` (`open`, `handle` answering `Tick`), `sm-ffi-swift`, `scripts/rust-ios.sh` (the XCFramework and bindings, built for iOS 26, arm64 device and simulator), `project.yml` links it and runs the script before compiling, the iOS floor rises to 26, the `app` leg and the TestFlight lane set up Rust | rust, app: an app-target test calls the core in the simulator |

## D. Ported maths (pure; side by side with R2 and A)

Each port lands with vectors in `fixtures/<area>/` that the Rust tests and the existing Swift suite both read.
The Swift code is not removed here: the old app and the watch still use it.

| # | Issue | From | Proof |
|---|---|---|---|
| D1 | stats: load, ACWR and its projection, zone mix, phases, training-block guidance | `Metrics`, `TrainingLoad`, `AcwrProjection`, `ZoneMix`, `PhaseManager`, `SendLogHealthCore/Acwr` | rust, swift, on the same vectors |
| D2 | stats: readiness (baseline, recovery engine, tunables) and the health precedence rule | `SendLogHealthCore`, `HealthMetricPrecedence` | rust, swift |
| D3 | force: Tindeq byte format, recording limit, force engine, curve fit, guided protocol, hands-free control | `SendLogWatchCore`, `ForceEngine`, `ForceCurveEngine`, `HandsFreeForceController` | rust, swift |
| D4 | stats: workout and attempt summaries, the RPE model, history derivations, grade pyramid, box-plot summary | `WorkoutStats`, `RPEModel`, `RPEDepletion`, `HistoryDerivedData`, `BoxPlot` | rust, swift |

## A. The store

Every slice that adds a statement adds its file in `queries/` and its test in `tests/queries/`.

| # | Issue | Scope | Proof |
|---|---|---|---|
| A1 | store: schema, migrations and the query rule | `sm-store`: one `.sql` per step, the 12 tables of #1045 and the local-only tables, the change-log triggers, `sm_now` and `sm_remote`; the build script that collects migrations and queries, the `Query` type, the "no query without a test" check, the prepare-everything test | rust: a recorded PostgREST row per table round-trips; a query file without a test fails the build |
| A2 | store: reads and plain writes | Every table: create, update, soft delete, restore; the read models the screens need | rust |
| A3 | store: the eight former RPCs as transactions | Purge session, purge recording, health upsert with precedence, link recordings, merge sessions, rename tag, phone workout, erase all | rust: the cases of `supabase/tests/*.sql` as Rust tests |
| A4 | store: the export bundle | `data.json` and the per-recording files as `Effect::Save`s, byte for byte from a seeded store, in steps | rust |
| A5 | store: the legacy-import mapping | Rows by column name, `ON CONFLICT DO NOTHING`, per-family state, the old queue's items as local writes | rust: twice equals once; a local edit survives |

## S. Sync

| # | Issue | Scope | Proof |
|---|---|---|---|
| S1 | sync: the core | `sm-sync`: `CloudRecord`, the rules, the phase repair, `SyncState` and `reduce`, batches, a fake transport, `fixtures/cloud/` | rust: two stores converge under each rule and every edge of the statechart |
| S2 | sync: the iCloud link | `Data/CloudKit` over `CKSyncEngine`: `encryptedValues`, the asset files, entitlements; `fixtures/cloud/` through `CKRecord` and back | app. Device: two phones, one Apple ID. Owner: container, schema |
| S3 | sync: the edges | Account changed, quota full, the cloud copy deleted, "Delete iCloud copy", an encrypted-data reset, a migration that asks for a full fetch | rust for the states. Device: each edge with a throwaway Apple ID |

## N. The new shell

| # | Issue | Scope | Proof |
|---|---|---|---|
| N1 | screens: the runtime | `sm-screens` (the route table from the folder, the look's tokens, the tab layout), `Open`, `Act` and `Close` in `sm-app`, shown screens answered with ops, the test that the Cargo and SwiftPM pins of Blocks agree; first screen: Settings, with its rows only | rust: the screen equals the approved JSON; an action returns ops that `apply` to the next screen |
| N2 | native: the host | `CoreHost` and its queue, `Shown`, `ScreenHost`, the tab view from the core's layout, the look from tokens, `Features/Kinds` with `MascotKind`, the `-newCore` launch argument | app; a 390 screenshot of Settings; a test that events sent from many threads are handled in the order sent |

## U. Screens (after N; each is one Rust file, its actions, and its test against the approved JSON)

Every slice proves by rust, app, and 390 and 1440 screenshots. The expected JSON is the newest approved
design's (#1046's, or #1060's once approved).

| # | Issue | Waits on |
|---|---|---|
| U1 | Today: readiness tiles, session kind, Start, this week, last ticks | D1, D2, A2 |
| U2 | Log · Sessions: weekly load (heat map), sessions by week, filters | D1, D4, A2 |
| U3 | Session detail: heart rate and effort (plot, box plot), attempts, edit, delete, merge | D4, A3 |
| U4 | Log · Logbook: totals, the grade pyramid, the tick list, a tick's detail | D4, A2 |
| U5 | Settings in full: grades, units, phases, the tag manager, export, erase; the sync row in every state | A3, A4, S1 |
| U6 | Force: analysis cards, the curve per tag (plot, box plot), presets, recordings list and detail | D3, A2 |
| U7 | Session: the start screen, a session logged by hand, routines and their preview | A2 |

## L. Live (SwiftUI on the phone, fed by the core)

L2 and L3 carry decision 5: the screen fits 375 × 667 points with the fullest content and never scrolls. Each
PR has the layout test and a screenshot at that size.

| # | Issue | Scope | Proof |
|---|---|---|---|
| L1 | native: Apple Health into the core | `HealthKitService` sends `Health` events; the core applies precedence and readiness; the widget payload comes back as an effect | rust, app. Device: HealthKit, background delivery |
| L2 | native: the live force view on the core | `TindeqBluetooth` on the `ble` contract; the force-measure view draws `LiveFrame` on one screen; recordings saved by the core; the `ScrollView` ban | rust, app with the layout test. Device: a Tindeq |
| L3 | native: the live session and the routine runner on the core | Fell and Sent, rest, the phone-recorded workout, each on one screen; Live Activity content from `LiveFrame` | rust, app with the layout tests. Device: Live Activity |

## B. Boards (#1047's fifteen steps, in Rust; B1 to B6 need nothing above but R1)

| # | Issue | Scope | Proof |
|---|---|---|---|
| B1 | boards: the crate and its types | `sm-boards`: board, layout, hold, route, setup, send; the six MoonBoard layouts, one file each | rust |
| B2 | boards: MoonBoard lighting | Grid to LED index, the ASCII message, flags, 20-byte chunks, #1047's vectors | rust |
| B3 | boards: Aurora-wire lighting | Level from the name, level 2 and 3 encoding, the power budget, framing, vectors | rust |
| B4 | boards: the link machine | The pure reducer on the `ble` contract: scan, connect, the write queue, drops | rust |
| B5 | boards: wiring rules and the wiring check | `WiringRule`, `LEDMap`, `Lighting::plan`, the check's reducer; the five Tension Board 2 layouts | rust |
| B6 | boards: Kilter layouts | One file per layout from its handbook; no rule where the map cannot be read | rust |
| B7 | boards: records | Tables `board_setups`, `routes`, `sends`; the logbook commands; their sync rows | rust; two stores converge |
| B8 | boards: the radio | `BoardBluetooth` (CoreBluetooth) on the `ble` contract; the Bluetooth purpose string; a debug route that lights one LED by index | app. Device: #1047's checklist |
| B9 | boards: the tab | Add a wall, the route list with its filters, route detail, the route editor; the `board` app kind | rust, app, screenshots |
| B10 | boards: the wiring check screen | Probe, fit and teach on the drawn board | rust. Device: a real wall |
| B11 | boards: light a route | Light, clear, every reason it cannot; the lit route kept in the live session | rust. Device |
| B12 | boards: log a send | The send sheet, ticks in the logbook, the link to the live session | rust, app |
| B13 | boards: the Aurora export reader | As #1047's issue 12, starting from a real file | rust. Waits on #1047's open question 2 |
| B14 | boards: the Moon logbook reader | As #1047's issue 13 | rust. Same |
| B15 | boards: the import screen | How to ask each maker, the picker, the preview, apply; marking holds on a name-only route | rust, app |
| B16 | release: board paperwork | As #1047's issue 15 | `local/docs` |

Then the two rewritten issues (`supersedes.md`): **#1048** (attempt to route) after B11, L3 and X5; **#1056**
(route from a screenshot) after B9 and B12.

## X. The switch and the removal (queued `--serial`; no promotion to `main` between X3 and X7)

| # | Issue | Scope | Proof |
|---|---|---|---|
| X1 | watch-core: the handoff types | `WatchSnapshot`, `WatchRecord`, `WatchRecordAck`, the outbox rule (#1045 W1); the core's serde mirror; `fixtures/watch/` | swift, rust |
| X2 | native: the import | The PostgREST reader and sign-ins in Swift (#1045 A5), rows to the core, the import screens | rust; app: simulator tests against a stubbed `URLProtocol` |
| X3 | native: the switch | The new shell is the app; the import is offered when an old session is found; the old root view is unreachable | every gate; a release note |
| X4 | watch: reads the snapshot | The phone publishes the core's snapshot; the watch's seven table reads go (#1045 W2) | watch. Device: context delivery |
| X5 | watch: sends records | The outbox over `transferFile`, the ack after the core has stored; the old upload queue's items move to the outbox; Supabase leaves the watch target (#1045 W3) | watch. Device: delivery, phone out of reach |
| X6 | native: delete the old app | `AppModel.swift`, the old `Features`, `Data/Repositories`, the Supabase and realtime services, the cache and GRDB, the ported and dead `Core` files and their tests; the coverage floors shrink to what is left; the X6 lines of `arch.toml`; the Swift rules that no longer apply leave `.drover/rules.md` | every gate |
| X7 | repo: remove Supabase | `supabase/`, two workflows, the scripts, the secret-scan entries; `CLAUDE.md`, the README, the App Store and review notes rewritten (the notes name rule 5.1.3) | every gate |
| X8 | mcp: read the export | `createExportStore`; auth, the Supabase transport and its dependency deleted (#1045 E2) | `cd mcp && npm test`, `npm run typecheck`, `npm run dry-run` |
| X9 | watch: views on Blocks' kit | The watch's views on BlocksUI's watch kit, in Swift (#1045 U9); the session and force-measure views move to `Views/Live`, each fits a 40 mm watch with no scrolling; the `ScrollView` ban | watch with the layout tests; 40 mm screenshots. Device |

After X6, P1's second half: a `cap:` issue lowers the cap to what is left plus a margin.

## Later, dated

| # | Issue | When |
|---|---|---|
| Z1 | Delete the importer, its screens and the Sign in with Apple entitlement (#1045 L1) | 90 days after the first TestFlight build that contains X3 |

## Order at a glance

```
P1 → R1 → R2 ─┬→ D1 D2 D3 D4 ───────────────┐
              ├→ A1 → A2 → A3, A4, A5 ──────┼→ N1 → N2 → U1 … U7 ─┐
              │        └→ S1 ───────────────┘→ S2 → S3 ───────────┼→ X2 → X3 → X4 → X5 → X6 → X7 → X8, X9
              │                               L1 L2 L3 (after N2) ┘
        R1 → B1 → B2 … B6 → B7 (after A1, S1) → B8 → B9 … B12 → B13 B14 → B15 → B16 → #1048, #1056
        X1 (any time after R1)
```

Fifty-three issues, the two rewritten ones among them, and one dated clean-up. The shortest path to a first
screen drawn from real data is R1, R2, A1, A2, N1, N2, U1.
