# What this keeps, changes and replaces

**Kept**: stands as approved. **Changed**: the decision stands, the named part differs. **Replaced**: this ADR's
version is built instead. **Withdrawn**: the owner dropped it; nothing is built. None of the three plans' implementation issues are filed; `migration.md` is the list.

## #1045 local-first (`docs/architecture/local-first/`)

| # | #1045 says | Now | What is built |
|---|---|---|---|
| 1 | The device is the source of truth; no server; no account; no login | Kept | |
| 2 | Decision 1: one SQLite file, typed tables, Postgres names minus `user_id` | Kept | The same file and names |
| 3 | Decision 1: through GRDB, in `SendmeterCore` | Replaced | rusqlite in `sm-store`; GRDB leaves the app |
| 4 | Decision 1: "one schema, four generic adapters" (import, sync, export, MCP) driven by the table list | Changed | Two adapters, in Rust: sync and export. The import and `mcp/` are gone (rows 14 to 16) |
| 5 | Decision 2: `CKSyncEngine`, one zone `Sendmeter`, private database, off by default, record name `<table>:<key>` | Kept | |
| 6 | Decision 2: every value field through `encryptedValues` | Kept | The plain-field change this issue first asked for is withdrawn with the web app |
| 7 | Decision 2: the two heavy columns as `CKAsset`s | Kept | |
| 8 | Decision 2: triggers log every local change; engine state, switch and last Apple ID in the store | Kept | The trigger's clock and its "remote apply" flag become two SQL functions |
| 9 | Decision 2 and `sync.md`: the five conflict rules; never shown to the user; never blocks a read or write | Kept | In `sm-sync` |
| 10 | `sync.md`: the statechart and `SyncState` | Kept | The same chart; the type is Rust |
| 11 | `sync.md`: rules as pure Swift in `Core/Sync`, a `CloudTransport` protocol, two-store host tests | Replaced | The same design in Rust; the transport is events and commands |
| 12 | Decision 3: the watch hands records to the phone over WatchConnectivity; one snapshot back; live mirrors by `sendMessage`; the watch never talks to CloudKit | Kept | The phone side hands the bytes to the core |
| 13 | `shapes.md`: `WatchSnapshot`, `WatchRecord`, `WatchRecordAck` in `SendLogWatchCore` | Kept | The core mirrors them with serde; `fixtures/watch/` holds them equal |
| 14 | Decision 4: a one-time import that keeps ids; `ON CONFLICT DO NOTHING`; resumes per family; old queue first; 90 days; no delete button | Withdrawn | No import (owner, 2026-11-24): both users start over. The owner exports the old data privately |
| 15 | Decision 4: the reader in Swift (`URLSession`), the row mapping in `Core/LegacyImport` | Withdrawn | Neither is built. No `import_state` table, no Sign in with Apple |
| 16 | Decision 5: the export folder (`data.json`, `samples/`, `traces/`), off by default, location follows the sync switch; `mcp/` reads it | Changed | The folder is kept, written by the core. `mcp/` is deleted by #1066; a reader can return as its own issue |
| 17 | Decision 6: screens are pure builders in a Swift target `SendmeterScreens`, drawn by `BlocksView` in one `ScreenHost` | Replaced | Pure builders in the Rust crate `sm-screens`; `ScreenHost` stays, generic |
| 18 | Decision 6: force curve, heat map, box plot and heart rate as app kinds drawn by existing SwiftUI views | Replaced | Blocks core kinds (plot, heat map, box plot: blocks #351 to #353, merged); only `board` and `mascot` are app kinds |
| 19 | Decision 6: recording, the live gauge and the routine runner stay live SwiftUI | Changed | Kept, and each must fit one screen with no scrolling |
| 20 | Decision 6 and `blocks.md`: wait for Blocks B1 and B2; the watch stays SwiftUI until B3 | Changed | All three landed. B2 is no longer needed (no Swift builders). Client-built screens (#354) landed too: nothing waits on Blocks |
| 21 | Consequences: no login, "Erase all data", privacy "data not collected", ~25 Core files and 55 test files deleted, `supabase/` and its workflows deleted | Changed | Kept, and far more goes: #1066 deletes everything `ports.md` does not list |
| 22 | Consequences: the 8 RPCs become store transactions; their SQL regressions become host tests | Kept | Rust transactions; `cargo test` |
| 23 | Consequences: minimum iOS 26 | Kept | Raised in slice R2 |
| 24 | Consequences: a synced column is a CloudKit schema change deployed before the build ships | Kept | |
| 25 | Consequences: no promotion to `main` during the serial cut-over (group C) | Replaced | No cut-over: the old app is deleted first (#1066). No promotion from then until the owner accepts the new app |
| 26 | Owner actions: portal container, capabilities, schema deploy, 90-day project, device checks | Changed | No 90-day project: the owner exports privately and shuts Supabase down. The rest is kept, plus the cap issue and one Blocks issue to file (`adr.md`) |
| 27 | `boundaries.md`: the module table and the "Deleted" list | Changed | The "Deleted" list stands and grows; the module table is replaced by `boundaries.md` here |
| 28 | Hot files and `arch.toml` lines | Replaced | `adr.md` here, added to #1049's file. `AppModel.swift` is deleted by #1066 |
| 29 | `migration.md`: groups A, W, C, S, E, U and L1 | Replaced | `migration.md` here. W survives almost as written (X1, X2, X3). C, E2 and L1 are gone: no cut-over, no `mcp/`, no importer to remove |
| 30 | Proofs named as `just core`, `just watch-core`, `just build-ios` | Changed | #1049 retired those recipes: proofs are gatekeeper gates |

## #1046 redesign (`native/SendmeterNative/design/redesign/`)

| # | #1046 says | Now | What is built |
|---|---|---|---|
| 1 | Five tabs: Today, Session, Board, Force, Log; Settings behind Today's menu | Kept | The tab list is a value the core gives the host |
| 2 | Every approved screen and its content (`screens/*.json`, `png/`) | Kept | Each JSON file is its screen's expected value in a Rust test, until #1060's approved screens (`docs/design/<slug>/screens/`, #1063's recipe) replace them |
| 3 | Blocks screens are built only from core kinds plus two app kinds, `board` and `mascot` | Kept | `board`'s props are in `shapes.md` (`size` in place of `columns` and `rows`) |
| 4 | Live screens (session, Force, watch) are SwiftUI on Blocks' look | Changed | Kept, with the new rule: each fits one screen with no scrolling, on iPhone and Watch. Where an approved live mockup scrolls, its slice redraws it |
| 5 | The chalk-and-slate palette and tiles, handed to Blocks; no swag pack | Kept | A Blocks scheme per mode and a style file in `crates/sm-screens/look/`, handed to BlocksUI as tokens; the watch's Swift palette is checked against them. #1060 may replace both files; the mechanism stays, and what its CSS pack says beyond them is a Blocks issue (`adr.md`, decision 4) |
| 6 | Mascots and the loading screen: the product's own assets and `SplashView`, unchanged | Kept | |
| 7 | 1440: the tab bar becomes a sidebar; Board list and route side by side | Kept | A mockup for iPad later, as in #1046 |
| 8 | Settings: iCloud sync a single switch, off, no account, no sign-in | Kept | |
| 9 | The render tool (`redesign-render`, `render.sh`) builds screens from JSON in Swift | Changed | Stays as the design record. New designs render the Rust screens |
| 10 | No prose; empty, error and onboarding states not drawn | Kept | |

## #1047 Board tab (`docs/architecture/boards/`)

| # | #1047 says | Now | What is built |
|---|---|---|---|
| 1 | Decisions 1 to 6: no outside service; every route is a user record; import is a pure reader plus a confirm step; holds marked or unknown; the LED map belongs to the wall; nothing lights on an unconfirmed map | Kept | |
| 2 | Decision 7: lighting is a pure package `BoardCore`, Foundation only, at `native-plugins/board-core/`, tested on the host and Linux | Replaced | The same contents as the Rust crate `sm-boards` |
| 3 | Decision 7: one CoreBluetooth class serves both board families; `TindeqBluetooth` untouched; a second `CBCentralManager` | Changed | `BoardBluetooth` stays and speaks the shared `BleCommand`/`BleEvent` contract; `TindeqBluetooth` is rewired to it too |
| 4 | Decisions 8 to 10: one setup per wall; a send carries a route snapshot; stored in the local-first store, private iCloud only | Kept | Tables `board_setups`, `routes`, `sends`; `sends` also holds gym and crag ticks (#1046's logbook) |
| 5 | Decision 11: the board is drawn, not pictured | Kept | The `board` app kind, drawn in SwiftUI |
| 6 | `data-shapes.md`: the Swift types | Changed | The same types and names in Rust; `BoardLogbook` is a trait `sm-store` implements; `Sendable` notes no longer apply |
| 7 | `statecharts.md`: the link, the wiring check, an import, the lit route | Kept | Pure reducers in Rust; the link's commands are `BleCommand`s |
| 8 | `protocols.md`: both wire formats, the vectors, the LED orders, the unverified list | Kept | The vectors become `sm-boards` tests |
| 9 | `imports.md`: how to get the file, the two formats, idempotence by content id | Kept | |
| 10 | The legal and App Store assessment; owner actions; the two open questions | Kept | |
| 11 | Module table (`BoardCore`, `SendmeterCore/Boards`, `BoardBluetooth`, `Features/Board`) and its rules | Replaced | `boundaries.md` here. The rules survive: no network, no policy in the radio or the screens |
| 12 | Hot files: one file per layout in `Boards/`; its own workflow `board-core.yml`; `just board-core` | Changed | One file per layout in `crates/sm-boards/src/layouts/`; covered by the rust gates, no workflow of its own |
| 13 | Issues 1 to 15 | Replaced | B1 to B16 in `migration.md`, the same steps in the same order |
| 14 | "The watch does not link `BoardCore` in v1; `RouteRef` stays usable there" | Changed | The watch links no Rust. It gets a small Swift `RouteChoice` in `SendLogWatchCore` (below) |

## This issue (#1059), by its amendments

| The issue asked for | Now |
|---|---|
| A web app on sendmeter.app: WASM build, SQLite in the browser, CloudKit JS sign-in and transport, Web Bluetooth, a Vercel deploy | Withdrawn (q3123). Not in this ADR. The earlier browser run is kept in `blocks.md` as a record for a later web app |
| AC: record the change of #1045's encryption to plain fields, and what Advanced Data Protection users turn on for web access | Withdrawn with the web app: encryption is #1045's, unchanged, and there is nothing to turn on (`sync.md`) |
| AC: how the two transports stay consistent; a statechart for sync on the web | One transport. `sync.md` has how it is held honest, and #1045's statechart as the core's type |
| Health values readable on the web (q3120) | Moot: no web. Every health value stays encrypted |
| Blocks issues #351 to #354 first | Merged in Blocks; nothing waits |
| A timer kind for Blocks (found by the first draft, for the web's live screens) | Not filed: the live screens are SwiftUI |
| "The import readers" in the core, where they meant #1045's Supabase import | Withdrawn (amendment of 2026-11-24). The board makers' file readers (#1047, B13 to B15) are a different thing and stay |
| Starting "from what lands with #1045 to #1047", beside today's app | Changed (same amendment, #1066): the old app is deleted first; `ports.md` lists what is kept, and each file goes with the PR that ports it |
| The personal force models | #1065 designs them; they live in `sm-stats` (`adr.md`, decision 10) |

## #1048, rewritten: map each attempt to its route

**Problem.** A session's attempts do not know which route they were on.

**Wanted.**

- On a board: the route lit from the Board tab tags every attempt after it, until another is lit.
- Off a board: the user picks a grade or a route name on the watch or the phone; it applies until it changes.
- History and the logbook group attempts by route, with sent or not.

**How, on the Rust core.**

- The tagging is one pure function in `sm-domain`: attempts and a timeline of route marks in, tagged attempts
  out. The marks come from the lit route (`LitRoute`, #1047) and from manual picks, merged by time.
- The watch stays Swift: `SendLogWatchCore` gains `RouteChoice` (a grade or a name) and `RouteMark` (a choice
  and a time); a finished workout's `WatchRecord` carries its marks. The watch tags nothing itself.
- The store writes the tag into `climb_attempts` (`route_id`, `route_name`, `route_grade`, `outcome`). A Sent
  tap also writes the tick in `sends`, with tries counted from the tagged attempts.
- The grouped views are the Log screens in `sm-screens`.
- The current route shows on the live session screen, which still fits one screen with no scrolling on iPhone
  and Watch. Picking a route is a sheet on the phone and its own page on the watch.

**AC.**

- [ ] The current route is part of the live session in `sm-app`, set by lighting a route or by a manual pick,
      and attached to each attempt with its time range.
- [ ] Changing the route mid-session splits the attempts at that time; earlier attempts keep theirs.
- [ ] The watch can set or change the route off the board; its marks arrive with the workout.
- [ ] `cargo test` covers tagging, changing and clearing; the watch-core suite covers `RouteMark`'s JSON, with
      a shared fixture in `fixtures/watch/`.
- [ ] The live session screen with a route shown passes its layout test at 375 × 667 points and at 40 mm.

Waits on B11 (light a route), L3 (the phone's live session on the core) and X3 (watch records).

## #1056, rewritten: add a route from a screenshot (MoonBoard first)

**Problem and wanted:** as filed. The user picks a screenshot of a route from the maker's app; the lit hold
circles become holds on the wall's grid; the user checks, fixes and saves. One climb at a time, nothing
uploaded. The approved screens (pick, confirm, error) are kept.

**How, on the Rust core.**

- The reader is pure Rust in `sm-boards::screenshot`: pixels in, a `RouteDraft` or a named refusal out. Plain
  image analysis with no Apple Vision and no new dependency, so it is tested on the host.
- The host only decodes the picked image to RGBA pixels (ImageIO) and sends `Event::Pixels`. It reads nothing
  from the image.
- The three screens are Blocks screens in `sm-screens`; the confirm screen is the route editor with the read
  holds filled in.

**AC.**

- [ ] A MoonBoard route screenshot fills a new route's holds with start, hand and finish roles on grid labels.
- [ ] The confirm screen shows the read holds on the board; the user can add, remove or change a hold; nothing
      is saved without confirming.
- [ ] An unreadable image (not a MoonBoard, cropped, unknown layout) says what is wrong and saves nothing.
- [ ] The reader has `cargo test` cases on sample images the lane draws itself; no maker screenshot is committed.
- [ ] No network request.

Waits on B9 (the route editor) and B12.
