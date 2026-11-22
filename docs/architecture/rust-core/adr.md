# ADR: one Rust core for the iPhone app and the web app (#1059)

## Summary

Decision: one Rust core holds the data and its rules, the SQLite store, the sync rules, the stats, the force-gauge and board protocols, the file readers and every Blocks screen. The iPhone app links it through UniFFI and keeps only Apple's parts (Health, the Bluetooth radio, the iCloud link, the watch, the live views). A new web app on sendmeter.app runs the same core as WASM, saves in the browser, works with no Apple ID, and syncs to the same private iCloud database through CloudKit JS. Synced fields are plain CloudKit fields so the web can read them; the recovery inputs from Apple Health stay end-to-end encrypted and phone-only. The new app is built beside today's app and replaces it in one step.
Slices: 6 Blocks issues first (4 filed, 2 new), then 60 issues in 11 groups: foundation (3), ported maths (4), store (5), sync (5), new shell (3), screens (7), live views (5), boards (16), the rewritten #1048 and #1056 (2), switch-over and Supabase removal (9), web deploy (1). A screen is one Rust file drawn on both platforms.
Open questions: (1) May Apple Health values sit unencrypted in iCloud? Recommended: only the readiness score and workout heart rate; HRV, resting heart rate, sleep and weight stay encrypted and off the web. (2) An Apple ID with Advanced Data Protection may be refused web sign-in whatever the user turns on (one public test says so; Apple documents nothing): is "web stays local-only for those users" acceptable? (3) Approving this ADR approves the new dependencies listed in `boundaries.md`.

Status: proposed, 2026-11-22. Read on staging `67150de2`; Blocks at staging `73adae31`.

## Question

#1045, #1046 and #1047 plan Sendmeter as a Swift app: a GRDB store, sync rules in Swift, screens built as Swift
values, a Swift board package. The owner wants as much as possible in Rust and the full app in a browser with the
same data. How is one Rust core shared by the iPhone app and a web app, with no server, and what happens to the
three approved plans?

Fixed by the owner (2026-11-22): Rust core for both platforms; the full app on the web, local-first; CloudKit JS
sync with no server; local-only web use without an Apple ID; Web Bluetooth for the Tindeq and the boards in Chrome
and Edge; a static build on sendmeter.app (Vercel) replacing the old web app; generic UI goes to Blocks, only the
lit board and the mascot are app kinds.

## What was found

- **It runs.** A probe core (SQLite store with a migration list, a Blocks screen with an app kind, `diff` to ops)
  was built once and run three ways: host tests, WASM in Chromium and WebKit on browser storage, and an iOS
  simulator app drawn by BlocksUI through UniFFI. Commands and results: `blocks.md`.
- **Browser storage has edges.** The store persists in Chromium and in WebKit with a profile. A private window
  refuses the storage API, so the web app must be able to run in memory and say so.
- **CloudKit on the web reads no end-to-end encrypted data.** Under Advanced Data Protection every field marked
  encrypted and every asset is end-to-end encrypted
  ([Apple Platform Security](https://support.apple.com/guide/security/sec973254c5f/web)). #1045 writes every field
  encrypted and the two heavy columns as assets: the web could read none of it.
- **Advanced Data Protection may block web sign-in outright.** Apple documents its web-access switch for
  iCloud.com only ([support page](https://support.apple.com/en-us/102630)). A public test of CloudKit JS on
  2026-09-14 found the sign-in refused for such an account with the switch on
  ([MistKit #486](https://github.com/brightdigit/MistKit/issues/486)). Not verified here.
- **App Review rule 5.1.3 (ii):** apps "may not store personal health information in iCloud". #1045 already
  syncs HRV, resting heart rate, sleep and weight, encrypted; plain fields would weaken that.
- **The watch cannot link the core.** Rust ships no ready-built standard library for `arm64_32-apple-watchos`,
  the architecture of Apple Watch models before Series 9; `rustup target list` on 1.100.0 offers only the
  64-bit watch targets.
- **Blocks' three #1045 gaps are closed** (iOS build, public initialisers, watchOS build: blocks #347 to #349).
  Its client-built mode still assumes TypeScript builders or a stream; Rust-built screens are blocks #354.

## Decisions

### 1. One core, ten crates, two thin bridges

| Bridge to Swift | For | Against |
|---|---|---|
| **UniFFI 0.32, proc-macros** | Generates the Swift and the C header; typed enums and records; ran in the probe | A build step (an XCFramework) before Xcode |
| swift-bridge | Lighter generated code | A smaller project; not run here; no gain for a two-function surface |
| A hand-written C ABI | No dependency | Every type marshalled by hand, twice |

Decision: a Cargo workspace at the repo root, `crates/sm-*` (`boundaries.md`). The compiler enforces the
boundaries: the stats crate cannot see SQLite, the screens crate cannot see the store. `sm-app` is the only door,
and it has two functions on both platforms:

- `open(config)` once;
- `handle(event, stamp) -> effects` for everything else: a tap, a Bluetooth packet, an iCloud change, a Health
  day, a watch record, a timer.

The core never calls out and never reads a clock: the host passes the time with every event and carries out the
effects it gets back. So there are no callbacks across either bridge, both bridges expose the same two
functions, and the whole app can be driven by a host test.

- iOS: `sm-ffi-swift` (UniFFI) built as `SendmeterRust.xcframework` by `just rust-ios`; events and effects are
  typed Swift enums. The core runs on its own actor, never on the main thread.
- Web: `sm-ffi-web` (wasm-bindgen); events and effects are JSON, with generated TypeScript types. The core runs
  in a worker; the page only draws.
- The watch links no Rust. `SendLogWatchCore` and `SendLogHealthCore` stay Swift for the watch and the widgets.
  Maths that both sides compute (readiness, force reps, the Tindeq byte format) is held equal by shared test
  vectors in `fixtures/`, which `cargo test` and `swift test` both read.

### 2. The store: SQLite in Rust, the same file format and schema on both platforms

| Option | For | Against |
|---|---|---|
| GRDB on iOS (#1045), a second store on the web | Nothing to change on iOS | Two schemas, two sets of queries, two migration lists |
| **rusqlite with its own SQLite on iOS; the same crate on WASM over browser storage** | One schema, one migration list, one set of SQL, the same SQLite version everywhere; ran in the probe | The WASM carries SQLite: 0.87 MB compressed in the probe |

Decision: `sm-store` is the only crate that touches SQLite. One migration per file in
`crates/sm-store/migrations/`, collected by the build, applied in name order on open, on both platforms. Tables
and columns keep #1045's names. GRDB leaves the app.

- iOS: the file #1045 named, `Application Support/SendmeterNative/sendmeter.sqlite`.
- Web: the browser's private file system (OPFS) through the "access-handle pool" file layer. It needs no
  cross-origin isolation, which matters: isolation headers would cut the Apple sign-in window off from the page.
- A private window, or a browser without that storage, gets an in-memory store and a banner: "Not saved in this
  browser". Nothing else changes.
- One tab owns the store. A second tab offers "Use Sendmeter here", which takes it over.
- A browser may clear a site it has not seen for a while (Safari: seven days). The app asks the browser to keep
  its storage, and while sync is off Settings shows "Only in this browser" with Export beside it.

### 3. Sync: the rules in Rust, one thin transport per platform

| Option | For | Against |
|---|---|---|
| Our own engine on raw CloudKit calls on both platforms | One code path | Gives up CKSyncEngine's push, scheduling and account handling on iOS, which the owner kept |
| **CKSyncEngine on iOS; a small poll engine in Rust on the web; one rule set under both** | Each platform uses what it has; every decision is shared | When to send and fetch is decided in two places |

Decision: `sm-sync` owns everything that decides: which rows are pending, how a row becomes a record, the
conflict rules, the sync state, the batches. A transport only moves records and reports what happened, in the
same event types on both platforms (`sync.md`):

- iOS: `CloudKitTransport` wraps `CKSyncEngine`. It turns engine events into core events and answers the
  engine's "next batch" from the core. It holds no rule.
- Web: `cloud.ts` wraps CloudKit JS (sign-in, fetch zone changes, save, delete). The poll engine in `sm-sync`
  decides when: after a local change, when the tab is shown, every minute while it is open.

They stay consistent because (a) the record's fields and types are written by Rust on both sides, (b) the
CloudKit schema file is generated from the same table list, (c) each transport passes one shared set of record
and error fixtures, and (d) the rules run in host tests with two stores and a fake transport. Zone, record
types and record names are #1045's.

### 4. Encryption: plain fields (changes #1045)

#1045 wrote every value through `encryptedValues` and the two heavy columns as assets. CloudKit's web access
cannot read end-to-end encrypted data, so:

- Synced fields are **plain CloudKit fields** under Apple's standard protection: encrypted in transit and at
  rest, with keys Apple holds. Sync is no longer end-to-end encrypted. Settings says so beside the switch.
- Force samples and workout traces become **packed bytes fields**, not assets (assets are end-to-end encrypted
  under Advanced Data Protection). A recording is at most 384 KB, under CloudKit's 1 MB record limit.
- **Exception, recommended:** the seven recovery inputs read from Apple Health (HRV, resting heart rate, three
  sleep values, weight, respiratory rate) stay in `encryptedValues`. Other iPhones read them; the web does not
  get them and shows the readiness score without its inputs. Open question 1.
- **Advanced Data Protection.** A user with it must turn on Settings › [name] › iCloud › iCloud.com › Allow
  Data Access (named "Access iCloud Data on the Web" before iOS 26.4) and approve each web sign-in on a trusted
  device. That is what Apple documents, for iCloud.com. It may not be enough for a third-party site (see above):
  the web app treats a refused sign-in as a state with plain words and stays local-only. Open question 2.

### 5. Screens: built in Rust, drawn by BlocksUI and the HTML renderer

Decision: a screen is one file in `crates/sm-screens/src/screens/`: a pure function from its input to a Blocks
`Block`, and a pure function from an action to what the user meant. `sm-app` loads the input from the store,
keeps the last screen it showed per route, and answers every change with Blocks row ops (`diff`). Both hosts are
generic: they draw a screen, apply ops, send actions back. No host knows a screen.

- iOS: `ScreenHost` wraps `BlocksView`; tabs and navigation are SwiftUI, their list comes from the core.
- Web: Blocks' shell (tabs, back, sheets) on a local source instead of a stream (blocks #354).
- The approved #1046 screens (`design/redesign/screens/*.json`) become the screen tests' expected values.
- The colours and tiles are defined once in Rust and handed to both renderers as tokens.
- What a device cannot do is not drawn: the core is told the device's abilities at `open` (Bluetooth, Health,
  watch, saved storage), so "other browsers hide those buttons" is decided in the screen, once.
- App kinds, drawn per platform: `board` and `mascot`, plus the web's Apple sign-in button. Everything generic
  is a Blocks issue (`blocks.md`): #351 to #354 are filed; this ADR adds a timer kind and one Swift bug the
  probe found.
- iOS keeps its live recording, force and watch views in SwiftUI, fed by the core. The web has no SwiftUI: its
  live force and session screens are Blocks screens with #351's live chart.

### 6. Bluetooth: protocols in Rust, the radio per platform

Decision: one small contract (`BleCommand`, `BleEvent`). The Tindeq byte format, the force engine, both board
lighting encoders, the board link machine and the wiring check are pure Rust. `TindeqBluetooth`,
`BoardBluetooth` (CoreBluetooth) and the web's `ble.ts` (Web Bluetooth) only carry commands out and events in.
On the web the browser's device chooser stands in for scanning. Web Bluetooth exists in Chrome and Edge (and
other Chromium browsers) on desktop and Android, and in no iPhone browser: elsewhere the core is told there is
no Bluetooth and the pair, pull and light buttons are not built.

### 7. The web app: a static build, deployed from CI

Decision: `web/` holds a little TypeScript (boot, the worker, the two transports, the app kinds, a service
worker for offline use) and no framework. `just web` builds the WASM and the bundle into `web/dist`. A new
workflow `web.yml` tests it headless and deploys the built files with Vercel's CLI: `staging` to a preview
address with CloudKit's development environment, `main` to sendmeter.app with production. Vercel builds
nothing and runs no code. CloudKit JS is loaded from Apple only when the user chooses to sign in: a local-only
user's browser talks to no one but sendmeter.app.

### 8. How it is built: beside today's app, then one switch

| Option | For | Against |
|---|---|---|
| #1045's order: move today's screens onto the new store one family at a time, then rebuild them | Small visible steps | Every screen is rebuilt by #1046 anyway; the re-wiring of the 12,958-line `AppModel.swift` is thrown away |
| **Build the new app (core, store, new screens) behind a launch flag; switch in one PR; then delete the old** | `AppModel.swift` is never edited, only deleted; no serial cut-over; `main` stays shippable throughout | Two apps in the binary until the switch |

Decision: the second. Existing users cross over by #1045's one-time import, as planned. The web grows with the
same slices and can go to its preview address as soon as the shell and the first screens exist.

## What this keeps, changes and replaces

Line by line for #1045, #1046 and #1047, with the rewritten #1048 and #1056: `supersedes.md`.

## Consequences

- One implementation of the data rules, the stats, the sync rules, the protocols and every screen, tested once
  on the host. A screen change is one Rust file and reaches both platforms.
- The phone app needs a Rust toolchain to build: CI, TestFlight and every lane run `just rust-ios` before
  Xcode. `just rust` becomes the primary gate; `just core` shrinks to what Swift keeps.
- Sync is not end-to-end encrypted. The privacy answer "data not collected" still holds (the data is in the
  user's own iCloud), but the Settings text and the review notes must say what protects it.
- The watch and the widgets keep their Swift maths. Two implementations of readiness, the force engine and the
  Tindeq format exist for good, held equal by shared vectors.
- The web has no Apple Health, no watch and no importer from the old Supabase account: readiness and watch
  workouts reach it through iCloud from the phone. A user of the old web app with no iPhone keeps no data.
- The web is always the newest build; a phone may lag by weeks. So synced schema changes are add-only, an
  unknown field is kept and ignored (#1045's rule), and a migration that adds a synced table or column asks
  for one full fetch.
- A CloudKit schema change must be deployed to production before the web build that writes it is promoted.
- The first load of the web app downloads about 1 MB; afterwards it starts offline from the browser's cache.
- Clock skew can make the wrong edit win a conflict (#1045 accepted this); browsers add more clocks.
- Vercel's free plan is for non-commercial use. Fine while Sendmeter is free; a paid Sendmeter needs a plan
  change or another static host. Nothing in the build depends on Vercel.

### Owner actions (nothing a lane can do)

- Apple Developer portal and CloudKit Console, from #1045: the container, iCloud and push on the App IDs, the
  schema deployed to production. New: import the generated `cloudkit/schema.ckdb` into development.
- CloudKit Console › API Access: two web tokens (development, production), sign-in by postMessage, allowed
  origins `sendmeter.app` and the preview address. They are public values, committed like the old anon key.
- Vercel: turn off the Git build for the project (the workflow uploads built files); a stable preview address
  (for example `preview.sendmeter.app`); a deploy token and the project ids as secrets of the `Preview` and
  `Production` GitHub environments. The first production deploy replaces the old web app.
- Device checks with throwaway Apple IDs: phone and web on one Apple ID; an account with Advanced Data
  Protection; quota full; Chrome with a Tindeq and with a board; Safari on a real iPhone (saved storage).
- Answer the three open questions, and #1047's two (which boards, and the makers' export files): they stand.

## Open questions

1. **Health values in iCloud.** Options: (a) recommended, as written: the seven recovery inputs encrypted and
   phone-only; the readiness score, its zone and workout heart rate plain; (b) everything plain: the web shows
   HRV and sleep too, with more App Review and privacy exposure; (c) no health row synced at all: the web shows
   no readiness.
2. **Advanced Data Protection.** If the owner's device check confirms such accounts cannot sign in on the web,
   is local-only web use for them acceptable for launch? No design without a server gets around it.
3. **Dependencies.** The list in `boundaries.md` (Rust crates, build tools, Apple's CloudKit JS, Vercel's CLI
   in CI) is approved with this ADR, or struck there.

## Hot files

| File or list | Class | Becomes |
|---|---|---|
| The store's schema steps | central list | `crates/sm-store/migrations/NNNN_<name>.sql`, collected by the crate's build script |
| Screens and their routes | central list | `crates/sm-screens/src/screens/<name>.rs`, one per screen, each naming its own route; the route table is written by the build script |
| Board layouts | central list | `crates/sm-boards/src/layouts/<id>.rs`, collected the same way (#1047's `Boards/` folder) |
| App kinds | central list | `native/SendmeterNative/Sources/Features/Kinds/<Name>Kind.swift` and `web/src/kinds/<name>.ts`; a core test fails a kind a screen uses that either folder lacks |
| `justfile` | every slice adds a recipe | `just/<area>.just`, imported by the root file, which is then frozen |
| CloudKit schema, TypeScript event types | generated | `cloudkit/schema.ckdb` by `just gen-cloudkit`; `web/src/gen/core.d.ts` by `just gen-web-types` |
| Swift bindings, the XCFramework, `web/dist` | generated | built by `just rust-ios` and `just web`, never committed |
| CI | docs and CI per area | new files `rust.yml` and `web.yml`; nothing is added to `native-swift.yml` but one build step |
| `Sources/App/AppModel.swift` | #1045's hot file | not edited again: the new app does not use it, slice X6 deletes it |
| `CLAUDE.md` | docs | one repo-map line in R1; rewritten once in X7 |

The exact `.drover/arch.toml` lines. The repo has none yet; the first slice to land creates the file.

```toml
# slice R1 (workspace)
frozen = ["justfile"]

[[collect]]
dir = "just"
glob = "*.just"

# slice R3 (web bridge)
generated = ["web/src/gen/core.d.ts"]
generate = "just gen-web-types"

[[ban]]
pattern = "indexedDB|localStorage|navigator\\.storage"
paths = ["web/src/**"]
except = ["web/src/worker.ts"]
reason = "the store is the only saved state: the worker hands the browser's file system to the core"

# slice A1 (store)
[[collect]]
dir = "crates/sm-store/migrations"
glob = "*.sql"

[[ban]]
pattern = "rusqlite"
paths = ["crates/**"]
except = ["crates/sm-store/**", "crates/sm-ffi-web/**"]
reason = "only the store touches SQLite; the web bridge installs its file layer"

# slice S1 (sync core)
generated = ["web/src/gen/core.d.ts", "cloudkit/schema.ckdb"]
generate = "just gen-core"

# slice S3 (CloudKit on iOS)
[[ban]]
pattern = "import CloudKit"
paths = ["native/**", "ios/**"]
except = ["native/SendmeterNative/Sources/Data/CloudKit/**"]
reason = "sync rules live in crates/sm-sync; only the transport sees CloudKit"

# slice S4 (CloudKit on the web)
[[ban]]
pattern = "CloudKit\\."
paths = ["web/src/**"]
except = ["web/src/cloud.ts"]
reason = "only the web transport calls CloudKit JS"

# slice N1 (screens)
[[collect]]
dir = "crates/sm-screens/src/screens"
glob = "*.rs"

# slice N2 (iOS host)
[[collect]]
dir = "native/SendmeterNative/Sources/Features/Kinds"
glob = "*Kind.swift"

# slice N3 (web host)
[[collect]]
dir = "web/src/kinds"
glob = "*.ts"

# slice L3 (Web Bluetooth)
[[ban]]
pattern = "navigator\\.bluetooth"
paths = ["web/src/**"]
except = ["web/src/ble.ts"]
reason = "only the web radio calls Web Bluetooth; protocols live in crates/sm-force and crates/sm-boards"

# slice B1 (boards)
[[collect]]
dir = "crates/sm-boards/src/layouts"
glob = "*.rs"

# slice X6 (the old app deleted)
[[ban]]
pattern = "import Supabase"
paths = ["native/**", "ios/**"]
reason = "there is no server: the one-time import uses URLSession in Sources/Data/LegacyImport"

[[ban]]
pattern = "import GRDB"
paths = ["native/**", "ios/**"]
reason = "the store is Rust: crates/sm-store"
```

When S1 lands, `just gen-core` runs `gen-web-types` and `gen-cloudkit` (cargo only, so it runs on Linux), and
the S1 lines replace R3's two. The top-level keys (`frozen`, `generated`, `generate`) sit above the tables in the file.
#1045's and #1047's `arch.toml` lines are replaced by these.
