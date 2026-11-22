# Migration order: the issues to file

One PR each. What lands with #1045 to #1047 is documents and mockups, so the starting point is today's app on
staging `67150de2`: Swift, Supabase, no Rust. "Proof" is what the PR must run. "Device" marks what only a
device or a real browser with hardware can show: the PR says so and does not claim it.

Today's app keeps shipping from `main` until X3. Nothing before group X changes what a user sees: the new app
is reached only with the launch argument `-newCore` (debug builds), and the web only at its preview address.

## Blocks repo, first

| # | Issue | Unblocks |
|---|---|---|
| blocks #354 | Client-built screens from Rust: the crate on wasm32 and iOS, the renderers drawn from local code | N2, N3 and every screen |
| blocks #351 | Live line chart (streamed points, target band, peak line) | U3, U6, L3, L5 |
| blocks #352 | Heat map | The screen slices that draw one (U2) |
| blocks #353 | Box plot | U3, U6 |
| G1, to file | Timer kind: counts up or down on the device, optional bar, an action at zero | L3, L5 |
| G2, to file | BlocksUI's op `apply` rewrites an app block's own `rows` field | Nothing waits: `board` uses `size` |

What Sendmeter needs from #354, and the text of G1 and G2: `blocks.md`.

## R. Foundation (no behaviour change)

| # | Issue | Scope | Proof |
|---|---|---|---|
| R1 | rust: the workspace | Root `Cargo.toml`, `rust-toolchain.toml`, `crates/sm-domain` (ids, `Stamp`, days, units, grades), `just/rust.just` with `just rust` (fmt, clippy, test, cargo-deny), the `justfile` split into `just/`, `.github/workflows/rust.yml` (Linux), `.drover/arch.toml`, one repo-map line in `CLAUDE.md` | `just rust` |
| R2 | rust: the door and the Swift bridge | `sm-app` (`open`, `handle` answering `Tick`), `sm-ffi-swift`, `just rust-ios` (the XCFramework and bindings, built for iOS 26), `project.yml` links it, the iOS floor rises to 26, `native-swift.yml` and the TestFlight lane build Rust first | `just rust`, `just gen`, `just build-ios`; an app-target test calls the core in the simulator |
| R3 | web: the WASM bridge and an empty page | `sm-ffi-web`, `web/` (`main.ts`, `worker.ts`, the bundle), `just web`, `just gen-web-types`, `.github/workflows/web.yml` with a headless test in Chromium and WebKit, a size limit on the WASM | `just web`; the headless test boots the core in a worker |

## D. Ported maths (pure; side by side with R2, R3 and A)

Each port lands with vectors in `fixtures/<area>/` that the Rust tests and the existing Swift suite both read.
The Swift code is not removed here: the old app and the watch still use it.

| # | Issue | From | Proof |
|---|---|---|---|
| D1 | stats: load, ACWR and its projection, zone mix, phases, training-block guidance | `Metrics`, `TrainingLoad`, `AcwrProjection`, `ZoneMix`, `PhaseManager`, `SendLogHealthCore/Acwr` | `just rust`, `just core`, `just health-core` on the same vectors |
| D2 | stats: readiness (baseline, recovery engine, tunables) and the health precedence rule | `SendLogHealthCore`, `HealthMetricPrecedence` | `just rust`, `just health-core`, `just watch-core` |
| D3 | force: Tindeq byte format, recording limit, force engine, curve fit, guided protocol, hands-free control | `SendLogWatchCore`, `ForceEngine`, `ForceCurveEngine`, `HandsFreeForceController` | `just rust`, `just watch-core`, `just core` |
| D4 | stats: workout and attempt summaries, the RPE model, history derivations, grade pyramid, box-plot summary | `WorkoutStats`, `RPEModel`, `RPEDepletion`, `HistoryDerivedData`, `BoxPlot` | `just rust`, `just core`, `just watch-core` |

## A. The store

| # | Issue | Scope | Proof |
|---|---|---|---|
| A1 | store: schema and migrations | `sm-store`: one `.sql` per step, the 12 tables of #1045 and the local-only tables, the change-log triggers, `sm_now` and `sm_remote` | `just rust`: a recorded PostgREST row per table round-trips. `just web`: the same migrations run in a browser, and the data survives a reload |
| A2 | store: reads and plain writes | Every table: create, update, soft delete, restore; the read models the screens need | `just rust` |
| A3 | store: the eight former RPCs as transactions | Purge session, purge recording, health upsert with precedence, link recordings, merge sessions, rename tag, phone workout, erase all | `just rust`: the cases of `supabase/tests/*.sql` as Rust tests |
| A4 | store: the export bundle | `data.json` and the per-recording files as `Effect::Save`s, byte for byte from a seeded store | `just rust` |
| A5 | store: the legacy-import mapping | Rows by column name, `ON CONFLICT DO NOTHING`, per-family state, the old queue's items as local writes | `just rust`: twice equals once; a local edit survives |

## S. Sync

| # | Issue | Scope | Proof |
|---|---|---|---|
| S1 | sync: the core | `sm-sync`: `CloudRecord`, sealed fields, the rules, the phase repair, `SyncState` and `reduce`, batches, a fake transport, `just gen-cloudkit` and `just gen-core`, `fixtures/cloud/` | `just rust`: two stores converge under each rule |
| S2 | sync: the web's poll engine and its states | When to fetch and send, back-off, `Refused`, sign-in expired, every edge of the web statechart | `just rust` |
| S3 | sync: the phone's transport | `Data/CloudKit` over `CKSyncEngine`; entitlements; `fixtures/cloud/` through `CKRecord` | `just build-ios`, the app-target tests. Device: two phones, one Apple ID. Owner: container, schema |
| S4 | sync: the web's transport | `web/src/cloud.ts` over CloudKit JS; the sign-in app kind; `fixtures/cloud/` through CloudKit's record object; the web tokens, allow-listed for the secret scan | `just web` (node). Device: sign in, phone and browser on one Apple ID. Owner: tokens, origins |
| S5 | sync: the edges on both | Account changed, quota full, the cloud copy deleted, "Delete iCloud copy", sign out keeping or removing the browser's copy | `just rust` for the states. Device: each edge with a throwaway Apple ID, and one with Advanced Data Protection |

## N. The new shell (after blocks #354)

| # | Issue | Scope | Proof |
|---|---|---|---|
| N1 | screens: the runtime | `sm-screens` (the route table from the folder, the look's tokens, the tab layout), `Open`, `Act` and `Close` in `sm-app`, shown screens answered with ops, `just pins`; first screen: Settings, with its rows only | `just rust`: the screen equals `settings.json`; an action returns ops that `apply` to the next screen |
| N2 | native: the host | `CoreHost`, `ScreenHost`, the tab view from the core's layout, the look from tokens, `Features/Kinds` with `MascotKind`, the `-newCore` launch argument | `just build-ios`; the app-target tests; a 390 screenshot of Settings |
| N3 | web: the host | Blocks' shell on the core, `web/src/kinds`, the device's abilities, the one-tab lock, "Not saved in this browser", the service worker | `just web`: headless, tap through Settings in Chromium and WebKit, offline reload; 390 and 1440 screenshots |

## U. Screens (after N; each is one Rust file, its actions, and its test against the approved JSON)

Every slice proves by `just rust`, `just build-ios`, `just web`, and 390 and 1440 screenshots of both hosts.

| # | Issue | Waits on |
|---|---|---|
| U1 | Today: readiness tiles, session kind, Start, this week, last ticks | D1, D2, A2 |
| U2 | Log · Sessions: weekly load, sessions by week, filters | D1, D4, A2; #352 for a heat map |
| U3 | Session detail: heart rate and effort, attempts, edit, delete, merge | D4, A3, #351, #353 |
| U4 | Log · Logbook: totals, the grade pyramid, the tick list, a tick's detail | D4, A2 |
| U5 | Settings in full: grades, units, phases, the tag manager, export, erase; the sync row in every state | A3, A4, S1 |
| U6 | Force: analysis cards, the curve per tag, presets, recordings list and detail | D3, A2, #351, #353 |
| U7 | Session: the start screen, a session logged by hand, routines and their preview | A2 |

## L. Live (the phone's stay SwiftUI; the web's are Blocks screens)

| # | Issue | Scope | Proof |
|---|---|---|---|
| L1 | native: Apple Health into the core | `HealthKitService` sends `Health` events; the core applies precedence and readiness; the widget payload comes back as an effect | `just rust`, `just build-ios`. Device: HealthKit, background delivery |
| L2 | native: the live force view on the core | `TindeqBluetooth` on the `ble` contract; the SwiftUI view draws `LiveFrame`; recordings saved by the core | `just rust`, `just build-ios`. Device: a Tindeq |
| L3 | web: live force | `web/src/ble.ts`; the force screen with #351's chart and G1's timer; buttons absent without Bluetooth | `just web`: headless with a fake radio; the screen without Bluetooth. Device: Chrome with a Tindeq |
| L4 | native: the live session and the routine runner on the core | Fell and Sent, rest, the phone-recorded workout; Live Activity content from `LiveFrame` | `just rust`, `just build-ios`. Device: Live Activity |
| L5 | web: the live session | The same loop as a Blocks screen | `just web` |

## B. Boards (#1047's fifteen steps, in Rust; B1 to B6 need nothing above but R1)

| # | Issue | Scope | Proof |
|---|---|---|---|
| B1 | boards: the crate and its types | `sm-boards`: board, layout, hold, route, setup, send; the six MoonBoard layouts, one file each | `just rust` |
| B2 | boards: MoonBoard lighting | Grid to LED index, the ASCII message, flags, 20-byte chunks, #1047's vectors | `just rust` |
| B3 | boards: Aurora-wire lighting | Level from the name, level 2 and 3 encoding, the power budget, framing, vectors | `just rust` |
| B4 | boards: the link machine | The pure reducer on the `ble` contract: scan, connect, the write queue, drops | `just rust` |
| B5 | boards: wiring rules and the wiring check | `WiringRule`, `LEDMap`, `Lighting::plan`, the check's reducer; the five Tension Board 2 layouts | `just rust` |
| B6 | boards: Kilter layouts | One file per layout from its handbook; no rule where the map cannot be read | `just rust` |
| B7 | boards: records | Tables `board_setups`, `routes`, `sends`; the logbook commands; their sync rows and schema | `just rust`; two stores converge |
| B8 | boards: the radios | `BoardBluetooth` (CoreBluetooth) and the board half of `ble.ts`; the Bluetooth purpose string; a debug route that lights one LED by index | `just build-ios`, `just web`. Device: #1047's checklist |
| B9 | boards: the tab | Add a wall, the route list with its filters, route detail, the route editor; the `board` app kind in SwiftUI and in the page | `just rust`, both hosts, screenshots |
| B10 | boards: the wiring check screen | Probe, fit and teach on the drawn board | `just rust`. Device: a real wall |
| B11 | boards: light a route | Light, clear, every reason it cannot; the lit route kept in the live session | `just rust`. Device |
| B12 | boards: log a send | The send sheet, ticks in the logbook, the link to the live session | `just rust`, both hosts |
| B13 | boards: the Aurora export reader | As #1047's issue 12, starting from a real file | `just rust`. Waits on #1047's open question 2 |
| B14 | boards: the Moon logbook reader | As #1047's issue 13 | `just rust`. Same |
| B15 | boards: the import screen | How to ask each maker, the picker, the preview, apply; marking holds on a name-only route | `just rust`, both hosts |
| B16 | release: board paperwork | As #1047's issue 15, plus the web page's "not affiliated" line | `just docs-check` |

Then the two rewritten issues (`supersedes.md`): **#1048** (attempt to route) after B11, L4 and X5; **#1056**
(route from a screenshot) after B9 and B12.

## X. The switch and the removal (queued `--serial`; no promotion to `main` between X3 and X7)

| # | Issue | Scope | Proof |
|---|---|---|---|
| X1 | watch-core: the handoff types | `WatchSnapshot`, `WatchRecord`, `WatchRecordAck`, the outbox rule (#1045 W1); the core's serde mirror; `fixtures/watch/` | `just watch-core`, `just rust` |
| X2 | native: the import | The PostgREST reader and sign-ins in Swift (#1045 A5), rows to the core, the import screens | `just rust`; simulator tests against a stubbed `URLProtocol` |
| X3 | native: the switch | The new shell is the app; the import is offered when an old session is found; the old root view is unreachable | `just ci`; UI smoke; a release note |
| X4 | watch: reads the snapshot | The phone publishes the core's snapshot; the watch's seven table reads go (#1045 W2) | `just build-watch`. Device: context delivery |
| X5 | watch: sends records | The outbox over `transferFile`, the ack after the core has stored; the old upload queue's items move to the outbox; Supabase leaves the watch target (#1045 W3) | `just build-watch`, the watchOS test job. Device: delivery, phone out of reach |
| X6 | native: delete the old app | `AppModel.swift`, the old `Features`, `Data/Repositories`, the Supabase and realtime services, the cache and GRDB, the ported and dead `Core` files and their tests; `just core` and the coverage floors shrink to what is left | `just ci` |
| X7 | repo: remove Supabase | `supabase/`, two workflows, the scripts, the secret-scan entries; `CLAUDE.md`, the README, the App Store and review notes rewritten | `just ci`, the docs stale-command check |
| X8 | mcp: read the export | `createExportStore`; auth, the Supabase transport and its dependency deleted (#1045 E2) | `cd mcp && npm test`, `npm run typecheck`, `npm run dry-run` |
| X9 | watch: views on Blocks' kit | The watch's views on BlocksUI's watch kit, in Swift (#1045 U9) | `just build-watch`. Device |

## V. Web deploy

| # | Issue | Scope | Proof |
|---|---|---|---|
| V1 | web: deploy | `web.yml` uploads the built files: `staging` to the preview address (CloudKit development), `main` to sendmeter.app (production); response headers; `CLAUDE.md`'s Vercel paragraph | A preview deploy from the PR's branch run by hand; the headless suite against it. Owner: Vercel settings and secrets, the first production deploy |

V1 can land any time after N3: the web app is useful local-only before sync exists.

## Later, dated

| # | Issue | When |
|---|---|---|
| Z1 | Delete the importer, its screens and the Sign in with Apple entitlement (#1045 L1) | 90 days after the first TestFlight build that contains X3 |

## Order at a glance

```
blocks: #354 ──────────────────────────┐        #351 #352 #353 G1 ── the slices that use them
R1 → R2 ─┬→ D1 D2 D3 D4 ───────────────┤
     R3 ─┤                             ├→ N1 → N2, N3 → U1 … U7 ─┐
         ├→ A1 → A2 → A3, A4, A5 ──────┤          └→ V1          ├→ X2 → X3 → X4 → X5 → X6 → X7 → X8, X9
         │        └→ S1 → S2 ──────────┘→ S3, S4 → S5 ───────────┤
         │                               L1 … L5 (after N2, N3) ─┘
R1 → B1 → B2 … B6 → B7 (after A1, S1) → B8 → B9 … B12 → B13 B14 → B15 → B16 → #1048, #1056
X1 (any time after R1)
```

Sixty issues, the two rewritten ones among them, and one dated clean-up. The shortest path to a first screen
drawn from real data on both platforms is R1, R2, R3, A1, A2, N1, N2, N3, U1.
