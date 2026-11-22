# What this keeps, changes and replaces

**Kept**: stands as approved. **Changed**: the decision stands, the named part differs. **Replaced**: this ADR's
version is built instead. None of the three plans' implementation issues are filed; `migration.md` is the list.

## #1045 local-first (`docs/architecture/local-first/`)

| # | #1045 says | Now | What is built |
|---|---|---|---|
| 1 | The device is the source of truth; no server; no account; no login | Kept | |
| 2 | Decision 1: one SQLite file, typed tables, Postgres names minus `user_id` | Kept | The same file on the phone; the same schema in the browser |
| 3 | Decision 1: through GRDB, in `SendmeterCore` | Replaced | rusqlite in `sm-store`; GRDB leaves the app |
| 4 | Decision 1: "one schema, four generic adapters" (import, sync, export, MCP) driven by the table list | Kept | In Rust; the two bytes columns are the one typed exception |
| 5 | Decision 2: `CKSyncEngine`, one zone `Sendmeter`, private database, off by default, record name `<table>:<key>` | Kept | |
| 6 | Decision 2: every value field through `encryptedValues` | Replaced | Plain fields; the seven recovery inputs stay encrypted (open question 1) |
| 7 | Decision 2: the two heavy columns as `CKAsset`s | Replaced | Packed bytes fields |
| 8 | Decision 2: triggers log every local change; engine state, switch and last Apple ID in the store | Kept | The trigger's clock and its "remote apply" flag become two SQL functions |
| 9 | Decision 2 and `sync.md`: the five conflict rules; never shown to the user; never blocks a read or write | Kept | In `sm-sync`, for both platforms |
| 10 | `sync.md`: the statechart and `SyncState` | Changed | Kept for the phone; two states added for the web (`Refused`, sign-in expired); the web's own chart in `sync.md` |
| 11 | `sync.md`: rules as pure Swift in `Core/Sync`, a `CloudTransport` protocol, two-store host tests | Replaced | The same design in Rust; the transport is events and commands |
| 12 | Decision 3: the watch hands records to the phone over WatchConnectivity; one snapshot back; live mirrors by `sendMessage`; the watch never talks to CloudKit | Kept | The phone side hands the bytes to the core |
| 13 | `shapes.md`: `WatchSnapshot`, `WatchRecord`, `WatchRecordAck` in `SendLogWatchCore` | Kept | The core mirrors them with serde; `fixtures/watch/` holds them equal |
| 14 | Decision 4: a one-time import that keeps ids; `ON CONFLICT DO NOTHING`; resumes per family; old queue first; 90 days; no delete button | Kept | |
| 15 | Decision 4: the reader in Swift (`URLSession`), the row mapping in `Core/LegacyImport` | Changed | The reader stays Swift; the mapping moves to `sm-store`. The web has no importer |
| 16 | Decision 5: the export folder (`data.json`, `samples/`, `traces/`), off by default, location follows the sync switch; `mcp/` reads it | Kept | Written by the core; on the web "Export" downloads the same files |
| 17 | Decision 6: screens are pure builders in a Swift target `SendmeterScreens`, drawn by `BlocksView` in one `ScreenHost` | Replaced | Pure builders in the Rust crate `sm-screens`; `ScreenHost` stays, generic |
| 18 | Decision 6: force curve, heat map, box plot and heart rate as app kinds drawn by existing SwiftUI views | Replaced | Blocks core kinds (#351, #352, #353); only `board` and `mascot` are app kinds |
| 19 | Decision 6: recording, the live gauge and the routine runner stay live SwiftUI | Kept | On the phone. The web draws them as Blocks screens |
| 20 | Decision 6 and `blocks.md`: wait for Blocks B1 and B2; the watch stays SwiftUI until B3 | Changed | All three have landed in Blocks. B2 is no longer needed (no Swift builders). The screens now wait for #354 and the kinds they use |
| 21 | Consequences: no login, "Erase all data", privacy "data not collected", ~25 Core files and 55 test files deleted, `supabase/` and its workflows deleted | Kept | |
| 22 | Consequences: the 8 RPCs become store transactions; their SQL regressions become host tests | Kept | Rust transactions; `cargo test` |
| 23 | Consequences: minimum iOS 26 | Kept | Raised in slice R2 |
| 24 | Consequences: a synced column is a CloudKit schema change deployed before the build ships | Changed | Also before the web build is promoted; the schema is a generated file |
| 25 | Consequences: no promotion to `main` during the serial cut-over (group C) | Replaced | No serial cut-over: the new app is built behind a flag. Only group X holds promotion |
| 26 | Owner actions: portal container, capabilities, schema deploy, 90-day project, device checks | Kept | Plus the web tokens and Vercel (`adr.md`) |
| 27 | `boundaries.md`: the module table and the "Deleted" list | Changed | The "Deleted" list stands and grows; the module table is replaced by `boundaries.md` here |
| 28 | Hot files and `arch.toml` lines | Replaced | `adr.md` here. `AppModel.swift` is never edited, only deleted |
| 29 | `migration.md`: groups A, W, C, S, E, U and L1 | Replaced | `migration.md` here. W and L1 survive almost as written (X1, X4, X5, Z1) |

## #1046 redesign (`native/SendmeterNative/design/redesign/`)

| # | #1046 says | Now | What is built |
|---|---|---|---|
| 1 | Five tabs: Today, Session, Board, Force, Log; Settings behind Today's menu | Kept | The tab list is a value the core gives both hosts |
| 2 | Every approved screen and its content (`screens/*.json`, `png/`) | Kept | Each JSON file becomes its screen's expected value in a Rust test |
| 3 | Blocks screens are built only from core kinds plus two app kinds, `board` and `mascot` | Kept | `board`'s props are in `shapes.md` (`size` in place of `columns` and `rows`) |
| 4 | Live screens (session, Force, watch) are SwiftUI on Blocks' look | Changed | On the phone and watch, yes. On the web they are Blocks screens with #351's live chart and a timer kind |
| 5 | The chalk-and-slate palette and tiles, handed to Blocks; no swag pack | Kept | Defined once as tokens in `sm-screens`; the watch's Swift palette is checked against them |
| 6 | Mascots and the loading screen: the product's own assets and `SplashView`, unchanged | Kept | The web shows the same splash art as a still |
| 7 | 1440: the tab bar becomes a sidebar; Board list and route side by side | Kept | It is now a real layout (the web, and iPad later), not only a mockup |
| 8 | Settings: iCloud sync a single switch, off, no account, no sign-in | Changed | The phone: as drawn. The web: the same row is "Sign in with Apple", because signing in is how the web reaches iCloud |
| 9 | The render tool (`redesign-render`, `render.sh`) builds screens from JSON in Swift | Changed | Stays as the design record. New designs render the Rust screens |
| 10 | No prose; empty, error and onboarding states not drawn | Kept | New states this ADR adds ("Not saved in this browser", "Refused", "Use Sendmeter here") need a design pass in their slices |

## #1047 Board tab (`docs/architecture/boards/`)

| # | #1047 says | Now | What is built |
|---|---|---|---|
| 1 | Decisions 1 to 6: no outside service; every route is a user record; import is a pure reader plus a confirm step; holds marked or unknown; the LED map belongs to the wall; nothing lights on an unconfirmed map | Kept | |
| 2 | Decision 7: lighting is a pure package `BoardCore`, Foundation only, at `native-plugins/board-core/`, tested on the host and Linux | Replaced | The same contents as the Rust crate `sm-boards`; one test run serves both platforms |
| 3 | Decision 7: one CoreBluetooth class serves both board families; `TindeqBluetooth` untouched; a second `CBCentralManager` | Changed | `BoardBluetooth` stays and speaks the shared `BleCommand`/`BleEvent` contract; `TindeqBluetooth` is rewired to it too. The web adds `ble.ts` |
| 4 | Decisions 8 to 10: one setup per wall; a send carries a route snapshot; stored in the local-first store, private iCloud only | Kept | Tables `board_setups`, `routes`, `sends`; `sends` also holds gym and crag ticks (#1046's logbook) |
| 5 | Decision 11: the board is drawn, not pictured | Kept | The `board` app kind, drawn in SwiftUI and in the web page |
| 6 | `data-shapes.md`: the Swift types | Changed | The same types and names in Rust; `BoardLogbook` is a trait `sm-store` implements; `Sendable` notes no longer apply |
| 7 | `statecharts.md`: the link, the wiring check, an import, the lit route | Kept | Pure reducers in Rust; the link's commands are `BleCommand`s |
| 8 | `protocols.md`: both wire formats, the vectors, the LED orders, the unverified list | Kept | The vectors become `sm-boards` tests |
| 9 | `imports.md`: how to get the file, the two formats, idempotence by content id | Kept | The web reads the same files through its file picker |
| 10 | The legal and App Store assessment; owner actions; the two open questions | Kept | One addition: the web page also shows the "not affiliated" line |
| 11 | Module table (`BoardCore`, `SendmeterCore/Boards`, `BoardBluetooth`, `Features/Board`) and its rules | Replaced | `boundaries.md` here. The rules survive: no network, no policy in the radio or the screens |
| 12 | Hot files: one file per layout in `Boards/`; its own workflow `board-core.yml`; `just board-core` | Changed | One file per layout in `crates/sm-boards/src/layouts/`; covered by `rust.yml` and `just rust` |
| 13 | Issues 1 to 15 | Replaced | B1 to B16 in `migration.md`, the same steps in the same order |
| 14 | "The watch does not link `BoardCore` in v1; `RouteRef` stays usable there" | Changed | The watch links no Rust. It gets a small Swift `RouteChoice` in `SendLogWatchCore` (below) |

## #1048, rewritten: map each attempt to its route

**Problem.** A session's attempts do not know which route they were on.

**Wanted.**

- On a board: the route lit from the Board tab tags every attempt after it, until another is lit.
- Off a board: the user picks a grade or a route name on the watch, the phone or the web; it applies until it
  changes.
- History and the logbook group attempts by route, with sent or not.

**How, on the Rust core.**

- The tagging is one pure function in `sm-domain`: attempts and a timeline of route marks in, tagged attempts
  out. The marks come from the lit route (`LitRoute`, #1047) and from manual picks, merged by time.
- The watch stays Swift: `SendLogWatchCore` gains `RouteChoice` (a grade or a name) and `RouteMark` (a choice
  and a time); a finished workout's `WatchRecord` carries its marks. The watch tags nothing itself.
- The store writes the tag into `climb_attempts` (`route_id`, `route_name`, `route_grade`, `outcome`). A Sent
  tap also writes the tick in `sends`, with tries counted from the tagged attempts.
- The grouped views are the Log screens in `sm-screens`.

**AC.**

- [ ] The current route is part of the live session in `sm-app`, set by lighting a route or by a manual pick,
      and attached to each attempt with its time range.
- [ ] Changing the route mid-session splits the attempts at that time; earlier attempts keep theirs.
- [ ] The watch can set or change the route off the board; its marks arrive with the workout.
- [ ] `cargo test` covers tagging, changing and clearing; `just watch-core` covers `RouteMark`'s JSON, with a
      shared fixture in `fixtures/watch/`.
- [ ] The web shows the same grouping from synced data.

Waits on B11 (light a route), L4 (the phone's live session on the core) and X5 (watch records).

## #1056, rewritten: add a route from a screenshot (MoonBoard first)

**Problem and wanted:** as filed. The user picks a screenshot of a route from the maker's app; the lit hold
circles become holds on the wall's grid; the user checks, fixes and saves. One climb at a time, nothing
uploaded. The approved screens (pick, confirm, error) are kept.

**How, on the Rust core.**

- The reader is pure Rust in `sm-boards::screenshot`: pixels in, a `RouteDraft` or a named refusal out. No
  Apple Vision: plain image analysis, so the phone and the web share one reader.
- The host only decodes the picked image to RGBA pixels (ImageIO on the phone, a canvas in the browser) and
  sends `Event::Pixels`. It reads nothing from the image.
- The three screens are Blocks screens in `sm-screens`; the confirm screen is the route editor with the read
  holds filled in.

**AC.**

- [ ] A MoonBoard route screenshot fills a new route's holds with start, hand and finish roles on grid labels.
- [ ] The confirm screen shows the read holds on the board; the user can add, remove or change a hold; nothing
      is saved without confirming.
- [ ] An unreadable image (not a MoonBoard, cropped, unknown layout) says what is wrong and saves nothing.
- [ ] The reader has `cargo test` cases on sample images the lane draws itself; no maker screenshot is committed.
- [ ] No network request; the same flow works in the web app.

Waits on B9 (the route editor) and B12.
