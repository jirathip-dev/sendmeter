# Blocks: what was run, what works, the gaps

Blocks at tag `v2.0` (`b1a9c9916efc5144a791aaca50d401c077a27501`), the latest release. Host macOS 27.2,
Swift 6.4.2. Each probe was a scratch package or a compiler call outside this repo; nothing here was changed.

## Confirmed by a run

**A screen built on the device draws with no server.** A scratch package pinned
`.package(url: "https://github.com/jirathip-dev/blocks", exact: "2.0.0")`. Its one test decodes a screen (a `stat`,
a `chart` and an app kind `force-curve`), hands it to `BlocksView(screen, source: nil)` with
`.appBlocks(…)` and `.blocksLook(Look(palette: <own colours>, tiles: nil))`, renders it in a hosting view and
counts pixels: the screen drew, and the app kind drew in the app's own view.

```
swift test            → Executed 1 test, with 0 failures     exit 0     (macOS)
Package.resolved      → blocks 2.0.0 at b1a9c991…            (SwiftPM reads the tag v2.0 as 2.0.0)
```

So: no stream, no server, no `Replica` is needed; the app's own palette goes in through `Look`; a chart Blocks
has no kind for is drawn by the app through `AppBlocks`. In XcodeGen the pin is `exactVersion: 2.0.0`.

## Gaps: three Blocks issues to file

### Gap 1 (blocks the phone): BlocksUI does not compile for iOS

```
swift build --target BlocksUI --triple arm64-apple-ios26.0-simulator --sdk <iphonesimulator SDK>      exit 1
swift/Sources/BlocksUI/BlockActs.swift:51:32: error: 'Gesture' is ambiguous for type lookup in this context
```

The line is inside `#if os(iOS)`, `some Gesture`, and both SwiftUI and the generated `Blocks.Gesture` struct
match. The macOS build skips it, and Blocks' CI builds the Swift package on macOS only, so nothing caught it.
`staging` (`e823e0b1`) has the same line. It is the only error that build reports.

Issue to file: *BlocksUI: the iOS build fails on an ambiguous `Gesture`; add an iOS simulator build to the Swift
gate, then a tag.*

### Gap 2 (blocks typed screens): no public initialisers

```
swift build --target InitProbe      exit 1
Probe.swift:8: error: incorrect argument label in call (have 'title:', expected 'from:')
```

`Screen`, `Stat`, `Row` and the other generated structs have public fields but only `init(from: Decoder)` is
public, so `Screen(title: "Today")` does not compile outside the package. Today an app can only decode a screen
from JSON text or from its own `Encodable` values. The issue asks for a screen "built as Swift values": that needs
this. TypeScript already has generated builders; Swift has none.

Issue to file: *swift: generated public initialisers for every kind and its parts, so a client-built app builds
a `Block` as typed values.*

Decision here: the screens slices wait for it. Sendmeter does not write its own JSON builder layer to work
around it: that would be a second way to build a screen, deleted a month later.

### Gap 3 (blocks the watch): BlocksUI has no watchOS build

`Package.swift` lists iOS 26 and macOS 26 only. The `Blocks` types compile for watchOS 26
(`swiftc -emit-module`, exit 0). BlocksUI does not (exit 1: `no such module 'CoreImage'`; it also imports WebKit,
PDFKit and Vision).

Issue to file: *BlocksUI: a kit that builds for watchOS (`Look`, `Palette`, the surface, `ActButton`,
`BlockNode` for the kinds that need no WebKit, PDFKit, Vision or CoreImage).*

Decision here: until it lands the watch app stays plain SwiftUI on `WatchDesign` and links no Blocks. The phone's
`Look` and the watch's colours both come from `SendmeterPalette` in `SendLogWatchCore`, so the two cannot drift.

## Not gaps, but the owner should know

- **The floor.** BlocksUI needs iOS 26: the manifest says so and the glass surface (`glassEffect`) is an
  iOS 26 API. An iOS 17 target cannot link it (`compiling for iOS 17.0, but module 'Blocks' has a minimum
  deployment target of iOS 26.0`). So the phone app, its widget and `Package.swift` move to iOS 26 / macOS 26
  and swift-tools 6.2, keeping the Swift 5 language mode. Open question 1.
- **Charts.** The `chart` kind has bar, stacked, line, combo and donut over named categories, and its formats are
  count, baht and percent. Load by week fits. Force curves at 80 Hz, heat maps, box plots and heart-rate traces do
  not, and are app kinds.
- **Docs.** Blocks' `docs/consume.md` says to pin a commit on `staging` and that no manifest names a tag; its
  README and this issue say to pin a release tag. The tag works. Worth one line in the gap 1 issue.
- The iOS render itself (a real `BlocksView` on a phone) is unverified until gap 1 is fixed: no claim is made.
