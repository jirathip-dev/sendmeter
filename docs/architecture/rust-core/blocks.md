# Blocks: what was run, what works, the gaps

The probe ran on 2026-11-22 against Blocks at staging `73adae31`; Blocks was read again on 2026-11-23 at
staging `976cf0f6`. Host macOS 27.2, Xcode 27.2, Rust 1.100.0. The probe was a scratch workspace outside this
repo; nothing here was changed. Not run and not claimed: CloudKit, HealthKit, Bluetooth, a real iPhone, a real
Watch. They are device-only.

## The probe

One Rust crate, about 280 lines:

- a store: rusqlite 0.43 with its own SQLite, two migration files applied by name, a generated column;
- a screen: Blocks' typed builders (`Screen`, `Stat`, `Chips`, `Button`, `Section`, `List`, `Row`) and one app
  kind (`board`), checked with `Built::check`;
- a door: `screen()` returns the screen as JSON; `act(action, values, now)` writes the store, builds the next
  screen and returns Blocks' `diff` of the two as row ops.

The bridge: UniFFI 0.32.2, about 35 lines. Every call is synchronous.

## Confirmed by a run

| Claim | Command | Exit |
|---|---|---|
| The core works on the host: a tap writes SQLite, the ops applied to the old screen give the new one | `cargo test -p sm-probe` (1 test) | 0 |
| It builds for the iPhone and the simulator | `cargo build -p sm-probe --release --target aarch64-apple-ios-sim` (and `aarch64-apple-ios`) | 0 |
| UniFFI writes the Swift bindings from the built library | `uniffi-bindgen generate --library libsm_probe.dylib --language swift` | 0 |
| A Swift app links the Rust library and BlocksUI for iOS | `swift build --product ProbeApp --triple arm64-apple-ios26.0-simulator --sdk <iphonesimulator SDK>` | 0 |
| **A Blocks screen built in Rust is drawn on iOS by BlocksUI**: the app decodes Rust's JSON into a `Block`, `BlocksView` draws it with the app kind, Rust's ops decode as `[Op]` and `Block.apply` gives Rust's next screen exactly; the SQLite file survives a relaunch | install and launch in an iOS 27.2 simulator (iPhone 17e), then read the app's own report: 6 checks, run twice | 0 |
| BlocksUI's `apply` changes an app block's `rows` field (G2 below) | the first iOS run, before the prop was renamed: 1 of 6 checks failed on exactly that field | 1 |
| The UniFFI bridge compiles with `unsafe_code` forbidden, as the lint floor demands | `RUSTFLAGS="-F unsafe-code" cargo check -p sm-probe` (2026-11-23) | 0 |
| The watch cannot use ready-built Rust | `rustup target list`: `aarch64-apple-watchos` and its simulator only, no `arm64_32-apple-watchos` | 0 |

Screenshot: `run/probe-ios.png`. It shows Blocks' default look, not Sendmeter's palette: the probe set no
theme.

What the runs also showed:

- **The iOS build must name its floor:** without `IPHONEOS_DEPLOYMENT_TARGET=26.0` the linker warns that
  SQLite's object was built for iOS 27.2. R2 sets it in `scripts/rust-ios.sh`.
- **Swift files that import both Blocks and SwiftUI** must write `SwiftUI.Scene` (Blocks has a `Scene` kind),
  the same clash as `Gesture` in blocks #344. With Rust-built screens only `ScreenHost` and the kinds import
  both.
- **iOS taps:** the simulator run sent its three actions through the handler `BlocksView` is given, from code;
  `simctl` cannot touch the screen. A finger on a real iPhone is device-only.
- **Not run:** clippy's pedantic floor over UniFFI's generated code. R2's rust gates are that run.

## Kept for a later web app

The issue first asked for a web app, and its AC asks for a browser run. That run was made before the owner
dropped the web app, and is recorded here only so a later web app starts from a known point: the same probe,
built to WASM with SQLite inside (2.54 MB, 0.87 MB gzipped), was drawn by Blocks' HTML renderer in Chromium
and WebKit, took real clicks, patched by ops and kept its data over a reload (`node web/run.mjs`, 9 checks
each, run twice, exit 0; `run/probe-web-chromium-390.png`, `run/probe-web-webkit-390.png`). A private window
refused saved storage. Nothing in this ADR builds on it.

## Blocks today

Read at staging `976cf0f6`. All four issues this ADR waited on have merged:

| Issue | What landed | Used by |
|---|---|---|
| blocks #354 | Client-built screens from an app's own Rust: the crate builds for `aarch64-apple-ios` under a CI gate; `BlocksView(block, source: nil, act:)` with `Block.apply(ops)` is the documented way on iOS (`docs/client-built.md`), held by `ClientBuiltTests` | Every screen |
| blocks #351 | The live line plot kind: streamed points, a target band, a peak line, in every renderer | Force curve, heart rate (U3, U6) |
| blocks #352 | The heat map kind | Load by day and week (U2) |
| blocks #353 | The box plot kind | Force per hand, per session (U3, U6) |

Sendmeter's use is exactly the documented one: its Rust builds a `Block`, serialises it, keeps the last screen
per route, and answers actions with `diff`'s ops. What stays the app's job, as Blocks' guide lists it: its FFI
and the threads behind it, its own kinds, and one pin for the crate and the Swift package. N1 adds the test
that the two pins agree.

## Gaps

### G2, to file in Blocks: swift: `Block.apply` rewrites an app block's own `rows` field

*Problem.* Still present at staging `976cf0f6` (read, not rerun). `eachList` in
`swift/Sources/Blocks/Apply.swift` walks every key in `Block.walked` and writes `o[key] = .array(items)` back.
`JSONValue.items` returns `[]` for a value that is not an array, so a field that merely shares a walked name,
such as an app block's `"rows": 12`, becomes `[]`. Rust's `apply` leaves an app block's own fields alone, so
the two disagree after any op on such a screen.

*Seen.* The probe's `board` app kind had `"columns": 11, "rows": 12`. After Rust's first ops, the Swift screen
differed from Rust's next screen in exactly `/blocks[3]/rows`: `[]` against `12`. Renaming the prop made the
two equal.

*Wanted.* `eachList` skips a walked key whose value is not an array, and does not descend into an app block's
own fields. A fixture in `fixtures/protocol` with an app block carrying `rows`, `blocks` and `items` as
non-lists, applied by Rust, TS and Swift to the same result.

Until it lands, Sendmeter's `board` kind names its prop `size` (`shapes.md`), so nothing waits on G2.

### Not filed: a timer kind

The first draft asked Blocks for a timer kind (a clock that counts on the device), for the web's live session
and force screens. With no web app the live screens are SwiftUI, which counts from the instants in `LiveFrame`.
No Blocks screen in the approved designs shows a running clock, so there is nothing to file.

## Not gaps

- **#1045's B1, B2 and B3** have landed (blocks #347, #348, #349). B2's Swift initialisers are no longer needed
  by Sendmeter: no screen is built in Swift.
- **Every approved #1046 screen uses only core kinds** plus `board` and `mascot`: stat, chips, button, section,
  list, row, form, chart (bars and the stacked pyramid), sheet, and now plot, heat map and box plot. Nothing
  else was found missing. #1060's new look files its own gaps in Blocks (#1063's recipe).
