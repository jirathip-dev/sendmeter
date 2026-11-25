# Migration order: the issues to file

One PR each. What landed with #1045 to #1047 is documents and mockups, and #1049 added the gates. The starting
point is the tree the cleanup (#1066) leaves: no app that builds, the files of `ports.md`, three Swift
packages that still pass, gatekeeper, no Rust. There is no import and no switch-over: both users start over
(owner, 2026-11-24), and the new app is the only app.

"Proof" is what the PR must run, as gates of `./.gatekeeper/run check`:

- **rust**: the rust pack and the `local/rust-*` gates (`adr.md`, decision 8). Linux, no simulator.
- **app**: `local/app` (the iOS build, the app-target tests), back from R2. macOS.
- **watch**: `local/watch`, back from X2. **swift**: `local/coverage` (the three Swift packages).

"Device" marks what only a device can show: the PR says so and does not claim it.

A slice that ports a file of `ports.md` deletes it and its tests in the same PR. Its first commit adds the
vectors in `fixtures/<area>/` and makes the Swift suite read them; the PR body gives that Swift run. Its last
commit deletes the Swift.

## Before R1 (not lanes' work)

| # | What | Who |
|---|---|---|
| P0 | #1066, the cleanup, keeping `ports.md`'s list | its own lane, after this ADR is approved |
| P1 | `cap:` issue: `ci/cap.toml` counts `crates/*/src/**/*.rs`, drops `mcp/`, and the cap comes down (`adr.md`, open question 2) | the owner, through an orchestrator |
| P2 | Blocks: file G2 (`blocks.md`). Nothing waits on it | an orchestrator |

Blocks #351 to #354 have merged; N1 pins Blocks at `976cf0f6` or later, so no screen slice waits on Blocks
for a kind the approved designs use. A screen whose fixture still holds a stand-in waits for that stand-in's
Blocks issue (`adr.md`, decision 4).

## R. Foundation

| # | Issue | Scope | Proof |
|---|---|---|---|
| R1 | rust: the workspace and its gates | Root `Cargo.toml` with the lint floor, `rust-toolchain.toml` (1.99.1, the two iOS targets), `deny.toml`, `crates/sm-domain` (ids, `Stamp`, days, units, grades; ports `DateSupport`, `AppUnits`, `MassFormatting`). In the same PR: `packs = ["core", "swift", "rust"]`, the `stable` and `msrv` legs, the six `local/rust-*` gate files, the `[cargo]` reasons in `.gatekeeper/deps.toml`, the Rust lines of `.drover/rules.md`, the R1 bans in `.drover/arch.toml`, the repo-map line and gate rows in `CLAUDE.md` | `./.gatekeeper/run list` shows every gate of decision 8; `./.gatekeeper/run check` passes |
| R2 | rust: the door, the Swift bridge, and an app that builds again | `sm-app` (`open`, `handle` answering `Tick`), `sm-ffi-swift`, `scripts/rust-ios.sh` (the XCFramework and bindings, built for iOS 26, arm64 device and simulator). `project.yml` is cut down to the phone target: an empty shell that calls the core, no Supabase, no GRDB, no Sign in with Apple, iOS 26. The `local/app` gate returns; the `app` leg and the TestFlight lane set up Rust | rust, app: an app-target test calls the core in the simulator |

## D. Ported maths (pure; side by side with R2 and A)

Phone-side Swift is deleted by its port. The watch's and the widget's own Swift (`SendLogWatchCore`,
`SendLogHealthCore`) stays and keeps reading the same vectors.

| # | Issue | From | Proof |
|---|---|---|---|
| D1 | stats: load, ACWR and its projection, zone mix, phases, training-block guidance | `Metrics`, `TrainingLoad`, `AcwrProjection`, `AcwrStatusCard`, `ZoneMix`, `PhaseManager`, `TrainingBlockGuidance`; equal to `SendLogHealthCore/Acwr` | rust, swift, on the same vectors |
| D2 | stats: readiness (baseline, recovery engine, tunables), the health precedence rule, the send-conditions score | `RecoveryInputs`, `HealthMetricReconciliation`, `DashboardVerdict`, `SendConditions`, `SendConditionsDetails`; equal to `SendLogHealthCore` and the watch's `HealthMetricPrecedence` | rust, swift |
| D3 | force: Tindeq byte format, recording limit, force engine, guided protocol, hands-free control; the curve fit, into `sm-stats` | `ForceEngine`, `ForceCurveEngine`, `HandsFreeForceController`, `TindeqConsistency`, `ForceProgress`, `GaugeSessionRPE`, `ForceProtocolSelection`, `ExerciseSideMode`; equal to the watch's Tindeq and force code | rust, swift |
| D4 | stats: workout and attempt summaries, the RPE model, history derivations, grade pyramid, box-plot summary | `WorkoutStats`, `HistoryDerivedData`, `HistoryFilters`, `HistoryTimeline`, `BoxPlot`, `WorkoutRawTrace`; equal to the watch's `RPEModel` and `RPEDepletion` | rust, swift |

The personal force model is #1065's ADR. Its slices come after D3, in `sm-stats` beside the curve fit, and
are not counted here.

## A. The store

Every slice that adds a statement adds its file in `queries/` and its test in `tests/queries/`.

| # | Issue | Scope | Proof |
|---|---|---|---|
| A1 | store: schema, migrations and the query rule | `sm-store`: one `.sql` per step, the 12 tables of #1045 and the local-only tables, the change-log triggers, `sm_now` and `sm_remote`; the row types (ports `Models`); the build script that collects migrations and queries, the `Query` type, the "no query without a test" check, the prepare-everything test | rust: a row of every table round-trips; a query file without a test fails the build |
| A2 | store: reads and plain writes | Every table: create, update, soft delete, restore; the read models the screens need; ports `TagCatalog` | rust |
| A3 | store: the eight former RPCs as transactions | Purge session, purge recording, health upsert with precedence, link recordings, merge sessions, rename tag, phone workout, erase all; ports `TindeqSessionMerge`, `HistorySelection` and the kept `supabase/` files | rust: the cases of `supabase/tests/*.sql` as Rust tests |
| A4 | store: the export bundle | `data.json` and the per-recording files as `Effect::Save`s, byte for byte from a seeded store, in steps | rust |

## S. Sync

| # | Issue | Scope | Proof |
|---|---|---|---|
| S1 | sync: the core | `sm-sync`: `CloudRecord`, the rules, the phase repair, `SyncState` and `reduce`, batches, a fake transport, `fixtures/cloud/` | rust: two stores converge under each rule and every edge of the statechart |
| S2 | sync: the iCloud link | `Data/CloudKit` over `CKSyncEngine`: `encryptedValues`, the asset files, entitlements; `fixtures/cloud/` through `CKRecord` and back | app. Device: two phones, one Apple ID. Owner: container, schema |
| S3 | sync: the edges | Account changed, quota full, the cloud copy deleted, "Delete iCloud copy", an encrypted-data reset, a migration that asks for a full fetch | rust for the states. Device: each edge with a throwaway Apple ID |

## N. The new shell

| # | Issue | Scope | Proof |
|---|---|---|---|
| N1 | screens: the runtime | `sm-screens` (the route table from the folder, the tab layout), the look as a scheme per mode and a style file in `look/`, `Open`, `Act` and `Close` in `sm-app`, shown screens answered with ops; one Blocks pin: the crate, the Swift package and `.drover/design.md` moved to one commit, with the test that they agree; first screen: Settings, with its rows only | rust: the screen equals the approved JSON; the look parses as Blocks' types and passes Blocks' `gate`; an action returns ops that `apply` to the next screen |
| N2 | native: the host | `CoreHost` and its queue, `Shown`, `ScreenHost`, the tab view from the core's layout, the look from tokens, `Features/Kinds` with `MascotKind`, the splash carried over. On first launch it removes what an old install left behind (the account cache, the saved Supabase session, the old queue files) | app; a 390 screenshot of Settings; a test that events sent from many threads are handled in the order sent |

## U. Screens (after N; each is one Rust file, its actions, and its test against the approved JSON)

Every slice proves by rust, app, and 390 and 1440 screenshots. The expected JSON is the newest approved
design's (#1046's, or #1060's once approved). No slice waits for a look: a new look swaps the fixtures and the
files in `look/`, in its own PR.

| # | Issue | Waits on |
|---|---|---|
| U1 | Today: readiness tiles, session kind, Start, this week, last ticks; weather for send conditions where the approved Today shows them | D1, D2, A2 |
| U2 | Log · Sessions: weekly load (heat map), sessions by week, filters | D1, D4, A2 |
| U3 | Session detail: heart rate and effort (plot, box plot), attempts, edit, delete, merge | D4, A3 |
| U4 | Log · Logbook: totals, the grade pyramid, the tick list, a tick's detail | D4, A2 |
| U5 | Settings in full: grades, units, phases, the tag manager, export, erase; the sync row in every state | A3, A4, S1 |
| U6 | Force: analysis cards, the curve per tag (plot, box plot), presets, recordings list and detail | D3, A2 |
| U7 | Session: the start screen, a session logged by hand, routines and their preview | A2 |

## L. Live (SwiftUI on the phone, fed by the core)

L2 and L3 carry decision 5: the screen fits 375 × 667 points with the fullest content and never scrolls. Each
PR has the layout test and a screenshot at that size. Each ports its row of `ports.md`: what the old policies
decided, the core decides.

| # | Issue | Scope | Proof |
|---|---|---|---|
| L1 | native: Apple Health into the core | `HealthKitService` sends `Health` events; the core applies precedence and readiness; the widget payload comes back as an effect; the widget target returns | rust, app. Device: HealthKit, background delivery |
| L2 | native: the live force view on the core | `TindeqBluetooth` on the `ble` contract; the force-measure view draws `LiveFrame` on one screen; recordings saved by the core; the `ScrollView` ban | rust, app with the layout test. Device: a Tindeq |
| L3 | native: the live session and the routine runner on the core | Fell and Sent, rest, the phone-recorded workout, each on one screen; Live Activity content from `LiveFrame` | rust, app with the layout tests. Device: Live Activity |

## B. Boards (#1047's fifteen steps, in Rust; B1 to B6 need nothing above but R1)

Written new from `docs/architecture/boards/`: no board code exists to port.

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

B13 to B15 read a climber's own logbook from a board maker's export. They are not the Supabase import, which
is gone.

Then the two rewritten issues (`supersedes.md`): **#1048** (attempt to route) after B11, L3 and X3; **#1056**
(route from a screenshot) after B9 and B12.

## X. The Watch, and the release

| # | Issue | Scope | Proof |
|---|---|---|---|
| X1 | watch-core: the handoff types | `WatchSnapshot`, `WatchRecord`, `WatchRecordAck`, the outbox rule (#1045 W1); the core's serde mirror; `fixtures/watch/` | swift, rust |
| X2 | watch: builds again, on the snapshot | The watch and its widget targets return to `project.yml`; the phone publishes the core's snapshot through `WatchLink`; the watch reads it in place of its seven table reads (#1045 W2); the `local/watch` gate returns | watch. Device: context delivery |
| X3 | watch: sends records | The outbox over `transferFile`, the ack after the core has stored (#1045 W3) | watch, rust. Device: delivery, phone out of reach |
| X4 | watch: views on Blocks' kit | The watch's views on BlocksUI's watch kit, in Swift (#1045 U9); the session and force-measure views move to `Views/Live`, each fits a 40 mm watch with no scrolling; the `ScrollView` ban | watch with the layout tests; 40 mm screenshots. Device |
| X5 | release: the new app's paperwork | The App Store copy and the review notes (they name rule 5.1.3), the privacy answers, the release notes, `CLAUDE.md` and the README read against the finished tree | `local/docs` |

## Order at a glance

```
#1066 → P1 → R1 → R2 ─┬→ D1 D2 D3 D4 ─────────────┐
                      ├→ A1 → A2 → A3, A4 ────────┼→ N1 → N2 → U1 … U7
                      │        └→ S1 ─────────────┘→ S2 → S3
                      │                             L1 L2 L3 (after N2)
                      └→ X1 → X2 (after N2) → X3 → X4 → X5 (last)
                R1 → B1 → B2 … B6 → B7 (after A1, S1) → B8 → B9 … B12 → B13 B14 → B15 → B16 → #1048, #1056
```

Forty-eight issues, the two rewritten ones among them. #1066 and #1065's slices are counted in their own
issues. The shortest path to a first screen drawn from real data is R1, R2, A1, A2, N1, N2, U1.
