# ADR: one Rust core for the iPhone app (#1059)

## Summary

Decision: one Rust core holds the data and its rules, the SQLite store, the sync rules, the stats, the force-gauge and board protocols, the file readers and every Blocks screen. Swift keeps Apple's parts (Health, the Bluetooth radio, the iCloud link, the live session and force views) and the whole Watch app. The core is plain synchronous Rust on one background queue. Sync is native iCloud only, encrypted as #1045 approved. There is no web app and no import: both users start over, the old app is deleted first, and only a listed set of files is kept. Every live session and force screen fits one screen with no scrolling, on iPhone and Watch. Rust is gated as strictly as cooee from its first crate.
Slices: 48 issues in 10 groups, after the cleanup (#1066): foundation and gates (2), ported maths (4), store (4), sync (3), new shell (2), screens (7), live views (3), boards (16), the rewritten #1048 and #1056 (2), the Watch and the release (5). The four Blocks issues have landed; one Blocks bug is left to file and nothing waits on it.
Open questions: (1) The Watch app stays Swift and gets its data through the phone, because stable Rust ships no ready-built library for watches before Series 9. Accept that (recommended), or drop those watches? (2) The line cap must count Rust. With the old app deleted first it can also come down: about 43,000 lines are kept, and the finished app is estimated at 70,000. Approve a cap issue that counts Rust and lowers the cap from 120,000 to 80,000?

Status: proposed, 2026-11-24. Read on staging `d99394f2`; Blocks at staging `976cf0f6`.

## Question

#1045, #1046 and #1047 plan Sendmeter as a Swift app: a GRDB store, sync rules in Swift, screens built as Swift
values, a Swift board package. The owner wants as much as possible in Rust. How is one Rust core built into the
iPhone app, what stays Swift, and what happens to the three approved plans?

Fixed by the owner:

- Rust core, scope as in the summary; generic UI goes to Blocks, only the lit board and the mascot are app kinds.
- **No web app** (q3123). Removed from this ADR: CloudKit JS, web sign-in, the WASM build, the browser store,
  the sendmeter.app deploy. A web app can return later on the same core. All health data stays on the phone and
  in the user's private iCloud.
- **A synchronous core with rusqlite**, called from a Swift background actor; no async runtime; every query has
  a test run against the real migrations (q3127).
- **Rust gates as strict as cooee's**, turned on by the PR that adds the first crate (q3081).
- **Live session and force screens fit one screen**, no scrolling, on iPhone and Watch (q3117).
- **Dependencies** (q3124): `blocks` (git, pinned), `serde`, `serde_json`, `rusqlite` (bundled SQLite),
  `uniffi`, `uuid`, a pinned Rust toolchain with the iOS targets, `cargo-deny`. Nothing else without asking.
- **No Supabase import** (2026-11-24): both users start over with empty data. The one-time import, its reader
  and its screens are gone from this ADR. The owner exports the old data once, privately, outside the repo.
- **The old app is deleted first** (#1066), once this ADR is approved. This ADR lists the files to keep; each
  goes with the PR that ports it (`ports.md`).
- **The personal force models** (#1065) live in the core's stats crate; #1065 designs them.

## What was found

- **It runs.** A probe core (SQLite store with a migration list, a Blocks screen with an app kind, `diff` to
  ops) was built and run on the host and in an iOS simulator app drawn by BlocksUI through UniFFI. Commands
  and results: `blocks.md`.
- **Blocks is ready.** The four issues this ADR waited on have merged: client-built screens from an app's own
  Rust (#354), the live line plot (#351), the heat map (#352), the box plot (#353). One Swift bug the probe
  found is still there and is not filed yet (`blocks.md`, G2).
- **The watch cannot link the core.** Rust ships no ready-built standard library for `arm64_32-apple-watchos`,
  the architecture of Apple Watch models before Series 9: `rustup target list` on 1.100.0 offers only the
  64-bit watch targets. Building it needs a nightly toolchain, which the stable and MSRV gates rule out.
- **UniFFI passes the unsafe ban.** The probe's UniFFI bridge compiles with `unsafe_code` forbidden, so the
  bridge crate needs no exception from cooee's lint floor.
- **The repo's gates moved** (#1049): every gate runs through gatekeeper, `justfile` and `AppModel.swift` are
  frozen, `.drover/arch.toml` and `ci/cap.toml` exist. The cap counts Swift and TypeScript only: 100,332 of
  120,000 lines today.
- **App Review rule 5.1.3 (ii)** says apps "may not store personal health information in iCloud". #1045
  already syncs HRV, resting heart rate, sleep and weight to the user's private iCloud, encrypted. This ADR
  leaves that as #1045 decided it; the review notes must name it.

## Decisions

### 1. One core, nine crates, one bridge

| Bridge to Swift | For | Against |
|---|---|---|
| **UniFFI 0.32, proc-macros** | Generates the Swift and the C header; typed enums and records; ran in the probe; approved | A build step (an XCFramework) before Xcode compiles |
| swift-bridge | Lighter generated code | A smaller project; not run here; no gain for a two-function surface |
| A hand-written C ABI | No dependency | Every type marshalled by hand; needs `unsafe`, which the lint floor forbids |

Decision: a Cargo workspace at the repo root, `crates/sm-*` (`boundaries.md`). The compiler enforces the
boundaries: the stats crate cannot see SQLite, the screens crate cannot see the store. `sm-app` is the only
door, and it has two functions:

- `open(config)` once;
- `handle(event, stamp) -> effects` for everything else: a tap, a Bluetooth packet, an iCloud change, a Health
  day, a watch record, a timer.

The core never calls out, never waits and never reads a clock: the host passes the time with every event and
carries out the effects it gets back. So there are no callbacks across the bridge and the whole app can be
driven by a host test.

| Core style | For | Against |
|---|---|---|
| **Synchronous: plain functions, rusqlite** (owner, q3127) | No runtime on the phone; a call is a function call across the bridge; one order of events | A slow call holds up the next event |
| Async with sqlx and tokio | Queries checked at compile time | A runtime in the app; async across UniFFI; the check needs a database at build time |

Decision: synchronous. Swift's `CoreHost` actor owns the core and is the only caller. Every event enters one
queue and is handled in the order it was sent, off the main thread. Long work (the export, a first sync) is cut into steps: the core does one step and returns `Wake`, so no call is long. What sqlx would have
checked at compile time is checked by a test per query (decision 2).

### 2. The store: SQLite in Rust, one schema, one migration list, one tested file per query

| Option | For | Against |
|---|---|---|
| GRDB in Swift (#1045) | Nothing new | The store and its rules stay Swift; the core could not own its data |
| **rusqlite with its own SQLite** (owner) | One place for schema, queries and rules; the same SQLite version on every iOS; ran in the probe | SQLite is compiled into the app |
| sqlx | Compile-time query checks | Async only (see above) |

Decision: `sm-store` is the only crate that touches SQLite. The file is the one #1045 named,
`Application Support/SendmeterNative/sendmeter.sqlite`. Tables and columns keep #1045's names. GRDB leaves the
app.

- **Migrations:** one file per step in `crates/sm-store/migrations/`, collected by the crate's build script,
  applied in name order on open.
- **Queries:** one statement per file in `crates/sm-store/queries/<name>.sql`, collected the same way into
  typed constants. The store runs nothing else: its `Query` type cannot be made from a string.
- **A test per query:** `crates/sm-store/tests/queries/<name>.rs` runs the query against a store opened in
  memory through the real migrations. The build fails a query with no test of its name, and a test with no
  query. One more test prepares every statement against the migrated schema, so a renamed column fails
  `cargo test`, not a user's phone.

### 3. Sync: the rules in Rust, CKSyncEngine as the transport, encryption unchanged

Decision: `sm-sync` owns everything that decides: which rows are pending, how a row becomes a record, the
conflict rules, the sync state, the batches. `CloudKitTransport` (Swift) wraps `CKSyncEngine`: it turns engine
events into core events and answers the engine's "next batch" from the core. It holds no rule (`sync.md`).
Zone, record types, record names, the five conflict rules and the statechart are #1045's.

**Encryption is #1045's, unchanged:** every value field goes through `encryptedValues` and the two heavy
columns are assets. This issue's AC asked the ADR to record a change to plain fields so a web app could read
them; the owner dropped the web app, so that change is withdrawn. A user with Advanced Data Protection has
nothing to turn on. A later web app would have to reopen this: CloudKit's web access reads no end-to-end
encrypted field.

### 4. Screens: built in Rust, drawn by BlocksUI

Decision: a screen is one file in `crates/sm-screens/src/screens/`: a pure function from its input to a Blocks
`Block`, and a pure function from an action to what the user meant. `sm-app` loads the input from the store,
keeps the last screen it showed per route, and answers every change with Blocks row ops (`diff`). The host is
generic: `ScreenHost` wraps `BlocksView`, applies ops and sends actions back. It knows no screen.

- This is Blocks' client-built mode (`docs/client-built.md` in Blocks, from #354), used as documented.
- Tabs and navigation are SwiftUI; their list comes from the core.
- A screen's test compares what it builds with the approved design's JSON. Today that is #1046's
  `design/redesign/screens/*.json`; when #1060's new look is approved, its files replace them. A new look
  changes screen files and tokens, not this architecture.
- The colours and tiles are defined once in Rust and handed to BlocksUI as tokens.
- App kinds, drawn in SwiftUI: `board` and `mascot`. Everything generic is a Blocks kind.

### 5. Live session and force screens fit one screen

The live recording, force and routine views stay SwiftUI on the phone, fed by the core (`LiveFrame`); the
watch's stay Swift. Requirement, on every slice that builds or changes one (L2, L3, X4, #1048):

- During a session, the session screen and the force-measure screen each show everything on one screen. They
  do not scroll, on the smallest iPhone the app supports (375 × 667 points) and the smallest Apple Watch
  (40 mm), with the fullest content: the longest route name, the widest numbers, every optional row present.
- When space runs out, a view shrinks numbers, then drops secondary rows. It never scrolls.
- A sheet or picker opened from a live screen (pick a route, RPE) is its own screen and may scroll. The
  watch's End and Pause page is its own screen and also fits.

Enforced by: a layout test per live view at the smallest size with the fullest content (app-target tests on
the phone, the watch test suite on the watch); `ScrollView` banned in the two live folders (`arch.toml`
below); a screenshot at the smallest size in each slice's PR. Design lanes carry the same rule.

### 6. Bluetooth: protocols in Rust, the radio in Swift

Decision: one small contract (`BleCommand`, `BleEvent`). The Tindeq byte format, the force engine, both board
lighting encoders, the board link machine and the wiring check are pure Rust. `TindeqBluetooth` and
`BoardBluetooth` (CoreBluetooth) only carry commands out and events in.

### 7. The Watch: stays Swift, served through the phone

| Option | For | Against |
|---|---|---|
| **The watch links no Rust** | Every supported watch keeps working; stable toolchain | Readiness, the force engine and the Tindeq format exist in Swift and in Rust |
| Link the core on 64-bit watches only | One implementation | Drops every watch before Series 9 |
| Build Rust's library for the older watches ourselves | One implementation, all watches | A nightly toolchain; no stable or MSRV gate can hold it |

Decision: the first (open question 1). `SendLogWatchCore` and `SendLogHealthCore` stay Swift for the watch and
the widgets. The watch hands finished records to the phone and reads one snapshot back, as #1045 decided; the
phone's side of that is the core. Maths both sides compute is held equal by shared test vectors in
`fixtures/`, which `cargo test` and `swift test` both read. The pure crates (`sm-stats`, `sm-force`) need
nothing from the phone, so linking them into the watch later is a build change, not a redesign.

### 8. Gates: gatekeeper's rust pack, on with the first crate

Decision: slice R1 adds the first crate and, in the same PR, turns on `packs = ["core", "swift", "rust"]` in
`.gatekeeper/config.toml`, so `./.gatekeeper/run check` (CI's required check and drover's done check) gates
every Rust line from the start. As cooee's:

| Gate | What it holds |
|---|---|
| `rust/fmt`, `rust/clippy`, `rust/bans` | `cargo fmt --check`; clippy pedantic with warnings as errors; the lint floor in `[workspace.lints]`: `unsafe_code` forbidden, no `unwrap`, `expect`, `panic`, `todo`, indexing, `as` casts or printing outside tests, no `allow` without a reason |
| `rust/deny` | `cargo-deny`: advisories, licences, duplicate versions, unknown sources (Blocks' repo is the one allowed git source) |
| `local/rust-test` | `cargo test --workspace --locked` on the pinned toolchain |
| `local/rust-stable` (leg `stable`) | The same tests on stable Rust |
| `local/rust-msrv` (leg `msrv`) | fmt, clippy, doc and tests on the MSRV, on a push to staging |
| `local/rust-doc` | `cargo doc` with warnings denied |
| `local/rust-allows` | At most 10 `allow` attributes across `crates/` |
| `local/rust-todos` | Every `// TODO(#N)` names an open issue |
| `core/deps` | Each direct dependency listed with its reason in `.gatekeeper/deps.toml` |
| `core/cap` | `crates/*/src/**/*.rs` counted under `ci/cap.toml` (open question 2: lanes may not edit that file) |

`rust-toolchain.toml` pins the MSRV, 1.99.1 (Blocks' and cooee's), with the two iOS targets. `local/app` and
the TestFlight lane build the core before Xcode compiles (slice R2). `.drover/rules.md` holds 25 of its 30
lines, so the Rust rules take at most five: the lint floor, no async and no clock, SQLite and SQL only as
tested query files in `sm-store`, no scrolling live screen, each naming the gate above that enforces it.

### 9. How it is built: the old app is deleted first, the new one is the only app

| Option | For | Against |
|---|---|---|
| #1045's order: move today's screens onto the new store one family at a time, then rebuild them | Small visible steps | Every screen is rebuilt anyway; the re-wiring of the 12,912-line `AppModel.swift` is thrown away |
| Build the new app beside the old one behind a launch flag, then switch (this ADR's first draft) | `main` stays shippable | Two apps in the tree and under the line cap; an import to carry users across |
| **Delete the old app (#1066), keep only what is ported or carried, build the new app in its place** (owner, 2026-11-24) | One app, one way to do each thing; no import, no flag, no switch; the cap falls | Nothing ships from staging until the new app is usable |

Decision: the third. `ports.md` is the list #1066 keeps: 60 pure files to port into the core, each deleted by
the PR that ports it, and the Swift that stays (Apple's edges, the watch, the widgets, the build skeleton).
Nothing else of the old app survives. The watch's attempt detector is kept as Swift, because it runs on the
watch (decision 7).

The new app keeps the bundle ids, so it installs over the old one. It reads nothing the old app stored, and
on first launch it removes what the old app left behind (slice N2).

### 10. Room for the personal force model (#1065)

Decision: the force curve fit moves from `sm-force` to `sm-stats`, beside readiness and training load, which
the model reads. #1065's model is a module of `sm-stats`: pure, with no store and no clock, like the rest of
that crate. If it needs a stored state, that is one more table: a migration file, its queries and tests, and
one record type (`shapes.md`). The watch shows the model's numbers from the phone's snapshot and computes none.

## What this keeps, changes and replaces

Line by line for #1045, #1046 and #1047, with the rewritten #1048 and #1056, and the lines of this issue the
amendments withdrew: `supersedes.md`.

## Consequences

- One implementation of the data rules, the stats, the sync rules, the protocols and every screen, tested on
  the host with no simulator. A screen change is one Rust file.
- The phone app needs a Rust toolchain to build: CI, TestFlight and every lane that builds the app. The Rust
  gates run on Linux; only the app build needs a Mac.
- The watch and the widgets keep their Swift maths. Two implementations of readiness, the force engine and the
  Tindeq format exist until the watch can link the core, held equal by shared vectors.
- Every call into the core is short by rule. A query that is slow on a large store is a bug with a test, not a
  reason for threads.
- No dynamic SQL: a filter is a parameter of a fixed statement. A new query is two new files and edits no list.
- From #1066 until the new app is usable, staging builds no app. `main` keeps the last old build, and the
  two installed apps keep working until the owner shuts Supabase down.
- Both users start over: nothing is imported, and the new app removes the old app's files on first launch.
- `mcp/` is deleted by #1066. The export folder stays, so a server that reads it can return as its own issue.
- A phone may run an older build than another phone on the same iCloud. Synced schema changes are add-only, an
  unknown field is kept and ignored (#1045's rule), and a migration that adds a synced table or column asks
  for one full fetch.
- A synced column is still a CloudKit schema change the owner deploys before the build ships (#1045).
- Clock skew can make the wrong edit win a conflict (#1045 accepted this).
- sendmeter.app and its Vercel project are not touched. The old web app there was retired in #857.

### Owner actions (nothing a lane can do)

- Before R1: the cap issue of open question 2.
- The private export of the old data, then shutting the two Supabase projects down. No slice depends on
  either.
- No promotion of staging to `main` between #1066 and a new app the owner accepts.
- File G2 in Blocks (`blocks.md`). Nothing waits on it.
- Apple Developer portal and CloudKit Console, as #1045 lists: the container, iCloud and push on the App IDs,
  the schema deployed to production.
- Device checks with a throwaway Apple ID, as #1045 and #1047 list: two phones on one Apple ID, quota full,
  sign-out, the watch handoff, a Tindeq, a board, the live screens on the smallest iPhone and Watch.
- #1047's two open questions (which boards, and the makers' export files) still stand.

## Open questions

1. **The Watch.** Options: (a) recommended: the watch stays Swift, as decision 7; (b) raise the watch app's
   floor to Series 9 and later and link `sm-stats` and `sm-force` there; (c) a nightly toolchain for the watch
   build only, outside the gates. Nothing else in this ADR changes with the answer.
2. **The line cap.** `ci/cap.toml` counts no Rust, and lanes may not edit it. To gate Rust lines from R1 it
   needs `crates/*/src/**/*.rs` in `count`. #1066 leaves about 43,000 of today's 100,332 counted lines; the
   finished app is estimated at 70,000 (35,000 of Rust, 8,000 of new Swift, 27,000 carried), and ports delete
   Swift as they add Rust. Options: (a) recommended: one cap issue, with #1066 or right after it, that adds
   the glob, drops `mcp/src/**/*.ts`, and lowers the cap to 80,000; (b) add the glob and leave the cap at
   120,000.

## Hot files

| File or list | Class | Becomes |
|---|---|---|
| The store's schema steps | central list | `crates/sm-store/migrations/NNNN_<name>.sql`, collected by the crate's build script |
| The store's statements and their tests | central list | `crates/sm-store/queries/<name>.sql` and `crates/sm-store/tests/queries/<name>.rs`, collected the same way |
| Screens and their routes | central list | `crates/sm-screens/src/screens/<name>.rs`, one per screen, each naming its own route; the build script writes the module list and the route table, so there is no `mod` list to edit |
| Board layouts | central list | `crates/sm-boards/src/layouts/<id>.rs`, collected the same way (#1047's `Boards/` folder) |
| App kinds | central list | `native/SendmeterNative/Sources/Features/Kinds/<Name>Kind.swift`; a core test fails a kind a screen uses that the folder lacks |
| Gates | CI per area | one file per gate in `.gatekeeper/gates/` (already collected); no workflow file is added |
| Swift bindings, the XCFramework | generated | built by `scripts/rust-ios.sh` into `target/`, never committed |
| `Sources/App/AppModel.swift` | frozen since #1049 | deleted by #1066, which also takes it out of `frozen` |
| `justfile` | frozen since #1049 | not edited: new commands are gates or scripts |
| `CLAUDE.md` | docs | rewritten by #1066 for the cleaned tree; one repo-map line and the gate rows in R1; read once more in X5 |

The exact `.drover/arch.toml` lines, added to the file #1049 created, each by the slice named:

```toml
# slice R1 (workspace)
[[ban]]
pattern = "async fn"
paths = ["crates/**"]
reason = "#1059: the core is synchronous; CoreHost's queue is the only concurrency"

[[ban]]
pattern = "std::time"
paths = ["crates/**"]
reason = "#1059: the core reads no clock; the host passes a Stamp with every event"

# slice A1 (store)
[[collect]]
dir = "crates/sm-store/migrations"
glob = "*.sql"

[[collect]]
dir = "crates/sm-store/queries"
glob = "*.sql"

[[collect]]
dir = "crates/sm-store/tests/queries"
glob = "*.rs"

[[ban]]
pattern = "rusqlite"
paths = ["crates/**"]
except = ["crates/sm-store/**"]
reason = "#1059: only the store touches SQLite"

# slice S2 (the iCloud link)
[[ban]]
pattern = "import CloudKit"
paths = ["native/**", "ios/**"]
except = ["native/SendmeterNative/Sources/Data/CloudKit/**"]
reason = "#1059: sync rules live in crates/sm-sync; only the transport sees CloudKit"

# slice N1 (screens)
[[collect]]
dir = "crates/sm-screens/src/screens"
glob = "*.rs"

# slice N2 (the host)
[[collect]]
dir = "native/SendmeterNative/Sources/Features/Kinds"
glob = "*Kind.swift"

# slice L2 (the first live view)
[[ban]]
pattern = "ScrollView"
paths = ["native/SendmeterNative/Sources/Features/Live/**"]
reason = "#1059: a live session or force screen fits one screen and never scrolls"

# slice B1 (boards)
[[collect]]
dir = "crates/sm-boards/src/layouts"
glob = "*.rs"

# slice X4 (the watch's views)
[[ban]]
pattern = "ScrollView"
paths = ["ios/App/SendLogWatch Watch App/Views/Live/**"]
reason = "#1059: a live session or force screen fits one screen and never scrolls"

# slice R2 (the app builds again)
[[ban]]
pattern = "import GRDB"
paths = ["native/**", "ios/**"]
reason = "#1059: the store is Rust: crates/sm-store"
```

#1066 leaves no file that imports Supabase or `Auth`, and no `AppModel.swift`. It takes that file out of
`frozen`, deletes the `import Auth` ban, and drops `except` from the `import Supabase` ban, so it holds
everywhere. #1045's and #1047's `arch.toml` lines are replaced by these.
