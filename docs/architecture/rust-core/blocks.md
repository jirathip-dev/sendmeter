# Blocks: what was run, what works, the gaps

Blocks at staging `73adae3100924c45e86f3f7206f11acd3c183cd2`. Host macOS 27.2, Xcode 27.2, Rust 1.100.0.
The probe was a scratch workspace outside this repo; nothing here was changed. Not run and not claimed:
CloudKit, CloudKit JS, HealthKit, Bluetooth, Web Bluetooth, a real iPhone, real Safari. They are device-only.

## The probe

One Rust crate, about 280 lines, built three ways from the same source:

- a store: rusqlite 0.43 with its own SQLite, two migration files applied by name, a generated column;
- a screen: Blocks' typed builders (`Screen`, `Stat`, `Chips`, `Button`, `Section`, `List`, `Row`) and one app
  kind (`board`), checked with `Built::check`;
- a door: `screen()` returns the screen as JSON; `act(action, values, now)` writes the store, builds the next
  screen and returns Blocks' `diff` of the two as row ops.

The bridges: UniFFI 0.32.2 for Swift, wasm-bindgen 0.2.130 for the browser, each about 35 lines.

## Confirmed by a run

| Claim | Command | Exit |
|---|---|---|
| The core works on the host: a tap writes SQLite, the ops applied to the old screen give the new one | `cargo test -p sm-probe` (1 test) | 0 |
| It builds for the browser, SQLite included | `cargo build -p sm-probe --release --target wasm32-unknown-unknown`, then `wasm-bindgen --target web` | 0 |
| **A Blocks screen built in Rust is drawn in a browser by the HTML renderer from the WASM build**, and stays live: a tap on "Start session" reaches Rust, the store is written, the returned ops patch the page; the chip's value arrives; the app kind draws; after a reload the data is still there | `node web/run.mjs`: 9 checks each in Chromium, WebKit, and WebKit with a profile (Playwright, 390 wide), run twice | 0 |
| It builds for the iPhone and the simulator | `cargo build -p sm-probe --release --target aarch64-apple-ios-sim` (and `aarch64-apple-ios`) | 0 |
| UniFFI writes the Swift bindings from the built library | `uniffi-bindgen generate --library libsm_probe.dylib --language swift` | 0 |
| A Swift app links the Rust library and BlocksUI for iOS | `swift build --product ProbeApp --triple arm64-apple-ios26.0-simulator --sdk <iphonesimulator SDK>` | 0 |
| **The same screen is drawn on iOS by BlocksUI**: the app decodes Rust's JSON into a `Block`, `BlocksView` draws it with the app kind, Rust's ops decode as `[Op]` and `Block.apply` gives Rust's next screen exactly; the SQLite file survives a relaunch | install and launch in an iOS 27.2 simulator (iPhone 17e), then read the app's own report: 6 checks, run twice | 0 |

Screenshots: `run/probe-web-chromium-390.png`, `run/probe-web-webkit-390.png`, `run/probe-ios.png`. They show
Blocks' default looks, not Sendmeter's palette: the probe set no theme.

What the runs also showed:

- **The WASM is 2.54 MB, 0.87 MB gzipped**, built for size. SQLite is most of it. Blocks' own no-go on WASM
  (`wasm-core/adr.md`, 264 KB against 2.8 KB of TypeScript) was about replacing its renderer's logic; here the
  WASM is the app. The page's renderer stays Blocks' TypeScript.
- **Browser storage:** Chromium saved to OPFS. WebKit with a profile saved to OPFS, and the data was still
  there when the browser was started again. WebKit without a profile, which is how a private window behaves,
  refused OPFS ("get OPFS root: UnknownError"): the probe fell back to memory and ran every check but the
  reload. That fallback is in the design.
- **The WASM build on a Mac needs LLVM's archiver** for SQLite's C code: `AR_wasm32_unknown_unknown` set to the
  toolchain's `llvm-ar` (rustup component `llvm-tools`). Apple's `ar` writes an empty archive and the link then
  fails on every `sqlite3_*` symbol. R3 sets it in `just web`; Linux CI is not affected.
- **The iOS build must name its floor:** without `IPHONEOS_DEPLOYMENT_TARGET=26.0` the linker warns that
  SQLite's object was built for iOS 27.2. R2 sets it in `just rust-ios`.
- **Swift files that import both Blocks and SwiftUI** must write `SwiftUI.Scene` (Blocks has a `Scene` kind),
  the same clash as `Gesture` in blocks #344. With Rust-built screens only `ScreenHost` and the kinds import
  both.
- **iOS taps:** the simulator run sent its three actions through the handler `BlocksView` is given, from code;
  `simctl` cannot touch the screen. The browser run used real clicks. A finger on a real iPhone is device-only.

## The mode: client-built from Rust (blocks #354)

Blocks has two modes: a server streams ops (A), or TypeScript builders in the page build the screen for the
React adapter (B). Sendmeter is a third: **the app's own Rust builds the screen and the ops on the device, and
the standard renderers draw them.** The run shows it works today with what Blocks ships, with these edges,
which are #354's to close. This is what Sendmeter needs from it:

| Need | Today | Wanted from #354 |
|---|---|---|
| The crate on `wasm32-unknown-unknown`, `aarch64-apple-ios` and `aarch64-apple-ios-sim` | Builds (the probe), but no CI gate holds it | The CI builds #354 already lists |
| The web renderer driven by local code | The probe called `render`, `patcher`, `behave` and `grow` from `web/dist/blocks.js` with a hand-made context object (`act`, `open`, `apps`, `store`, `held`, `view`, …). They are exported but not a documented entry | One documented call: give it a root, a screen, an action handler and the app's kinds; hand it ops later |
| The web **shell** on local code | `mount` draws tabs, back, sheets, confirms and toasts, but opens every screen on a stream URL | `mount` with a local source: "open this path" and "this action happened" go to the app's code; screens and ops come back from it |
| BlocksUI driven by local code | Works and is documented: `BlocksView(block, source: nil, act:)` and `Block.apply(ops)` | A test that holds it; the example |
| The same look from tokens on both | `css(scheme)` and `tiles` on the web; `Palette(tokens:dark:)` and `Tiles(tokens:)` in Swift | Confirmed as the supported way for an app whose tokens come from its core |

The orchestrator should add the table's second and third rows to #354 if its ADR does not already cover the
shell. Sendmeter's N2 and N3 wait for it; N1 does not.

## Gaps: Blocks issues

Filed (owner's decision q3032), each waited on by the slices in `migration.md`:

| Issue | What | Used by |
|---|---|---|
| blocks #351 | Live line chart: streamed points, a target band, a peak line | Force curve (live and saved), heart rate |
| blocks #352 | Heat map | Load by day and week |
| blocks #353 | Box plot | Force per hand, per session |
| blocks #354 | Client-built screens from Rust (above) | Everything |

Found by this ADR, to file the same way:

### G1: kind: timer (counts on the device, optional bar, an action at zero) (design first)

*Problem.* Sendmeter's live session shows elapsed time and a rest countdown with a bar; its guided force
protocol counts each hang and each rest. No core kind draws a running clock. Sending an op every second (or
every frame, for a smooth bar) from the app is the wrong tool: the renderer can count by itself from a start
time. BlocksUI has `RelativeValue`, redrawn each minute, for text only.

*Wanted.* A core kind: counts up from a start instant or down to an end instant, drawn by the renderer from the
device clock; an optional progress bar; a label and a tone; an optional action sent once when a countdown
reaches zero; a paused state holding a fixed value. Rust type, generated TS and Swift, the HTML renderer and
BlocksUI, fixtures, showcase.

*AC.* A design at 1440 and 390 (count-up, countdown with bar, paused, finished). No op is needed while it
runs. The zero action fires once, also when the page or app was in the background at zero. Fixtures: the three
states. From sendmeter #1059.

### G2: swift: `Block.apply` rewrites an app block's own `rows` field

*Problem.* Read on staging `73adae31`. `eachList` in `swift/Sources/Blocks/Apply.swift` walks every key in
`Block.walked` and writes `o[key] = .array(items)` back. `JSONValue.items` returns `[]` for a value that is not
an array, so a field that merely shares a walked name, such as an app block's `"rows": 12`, becomes `[]`. Rust's
`apply` leaves an app block's own fields alone, so the two disagree after any op on such a screen.

*Seen.* The probe's `board` app kind had `"columns": 11, "rows": 12`. After Rust's first ops, the Swift screen
differed from Rust's next screen in exactly `/blocks[3]/rows`: `[]` against `12`. Renaming the prop made the
two equal.

*Wanted.* `eachList` skips a walked key whose value is not an array, and does not descend into an app block's
own fields. A fixture in `fixtures/protocol` with an app block carrying `rows`, `blocks` and `items` as
non-lists, applied by Rust, TS and Swift to the same result.

Until it lands, Sendmeter's `board` kind names its prop `size` (`shapes.md`), so nothing waits on G2.

## Not gaps

- **#1045's B1, B2 and B3** have landed (blocks #347, #348, #349). B2's Swift initialisers are no longer needed
  by Sendmeter: no screen is built in Swift.
- **Every approved #1046 screen uses only core kinds** plus `board` and `mascot`: stat, chips, button, section,
  list, row, form, chart (bars and the stacked pyramid), sheet. Nothing else was found missing for them.
- **The web's Apple sign-in button** is drawn by Apple's CloudKit JS into an element the page gives it. It is
  an app kind on the web only, not a Blocks gap.
- **Pins.** Blocks' `docs/consume.md` asks an app to pin one commit in Cargo, npm and SwiftPM and to test that
  the pins agree. `just pins` (slice N1) is that test.
