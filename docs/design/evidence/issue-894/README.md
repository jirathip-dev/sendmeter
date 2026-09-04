# #894 — Force disconnected/empty state: approved R11 Force hero glyph

Real simulator captures of the native iPhone app built from this worktree's
`orch/894-force-empty-glyph` head (Debug, `xcodebuild -scheme SendmeterNative`
via the canonical Xcode binary). Captured with `xcrun simctl io <udid>
screenshot`; appearance driven by `xcrun simctl ui <udid> appearance
light|dark`; the DEBUG-only `--tabs-fixture force` harness presents the real
`MainTabView` with Force selected and no signed-in session (the same harness
the #875/#891 tab evidence used).

## Device / OS / mode

- Device: iPhone 14 simulator (390x844 pt; 1170x2532 px @3x)
- OS: iOS 26.5 (SimRuntime iOS-26-5)
- App: Sendmeter (bundle com.jirathip.sendlog.native, Debug build, launch arg
  `--tabs-fixture force`)
- Theme: System; `simctl ui appearance` drives light/dark

## Files

| File | Mode | Proves | SHA-256 |
|---|---|---|---|
| force-empty-hero-light-390x844.png | light | The Force Progressor card's disconnected/empty state leads with the approved R11 Force master (`ForceMascotLarge`, 160 px hero optical variant) as a large standalone template silhouette tinted SendmeterStyle.primary (#5B5FC7); no cave/photo background remains in that surface; header, copy ("Your first pull starts here" / "Turn Bluetooth back on…"), and the Open Bluetooth Settings button are unchanged | ae30cace4f7825084f5f0924138bbf6574e8dbd6cccb7a7b0906a1c7ad150d6e |
| force-empty-hero-dark-390x844.png | dark | Same surface in dark appearance; the template glyph keeps the primary tint and reads clearly on the dark card | 718bfefaa52225020b71a26c8f6fe4abd58c3f0fe4add9e7aa15b8f49f21efd2 |
| red-green-proof.txt | - | Discriminating wiring test: RED (9 failures) on the old cave/photo composite, GREEN (3/3) after the fix; full SwiftPM suite 1163/0 | see file |

## Verification notes

- Pre-fix reference (same device, layout, and fixture): the #875 r2 Force-tab
  captures under `docs/design/evidence/issue-875/` — their Progressor card
  shows the SplashCaveBackground + SplashKangaroo composite in the same rows.
- Pixel-level comparison of the illustration band (rows y1387-1740 @3x =
  462-580 pt, the exact band where the pre-fix composite sat):
  - Light: the pre-fix capture has a full-width dark photo band there; the
    post-fix capture has NO dark band (full-width row scan), and 59,732
    periwinkle pixels = the tinted hero glyph (pre-fix: 1).
  - Dark: pre-fix band mean luma 18 (near-black photo); post-fix mean luma 39
    with the glyph's tinted pixels (59,356) lifting it; glyph sample color
    RGB(91,95,199) == #5B5FC7 == SendmeterStyle.primary in both modes.
- Wired asset/variant: `ForceMascotLarge.imageset/r11-force-control-160.svg`
  (SHA-256 6802e9439ff2fbcd70f60e7f04baf2196c33cf17de6ad309716966221ede6380,
  byte-identical to the approved #868/#875 R11 160 px hero master). No asset
  was added or modified — the approved hero master shipped unused in #875.
- Card hierarchy, copy, reconnect action ("Open Bluetooth Settings"),
  haptic button style, accessibility labels, and Dynamic Type are unchanged:
  only the illustration switches, via `artwork: .forceMascot` on the shared
  `ProductEmptyState` seam (default `.splash` keeps every other surface's
  composite — pinned by the existing EmptyStateWiringTests).
- Wiring gate: `Tests/SendmeterCoreTests/ForceEmptyStateArtworkWiringTests.swift`
  — source-text pins for the Force opt-in + the mascot artwork branch + the
  hero-master asset hash; RED on the old code (9 failures), GREEN after the
  fix; full suite `swift test` 1163 tests, 0 failures. See red-green-proof.txt.
- Gates at exact head: `swift test` 1163/0; `xcodegen generate` no project
  drift; anti-slop validate/cold/advisory all exit 0 (152 Swift files);
  `xcodebuild -scheme SendmeterNative` generic iOS Simulator Debug build
  (canonical Xcode binary, CODE_SIGNING_ALLOWED=NO) ** BUILD SUCCEEDED **
  (the first attempt via the `xcodebuild` PATH shim aborted before Xcode ran:
  its simulator orchestration could not boot its own device — rerun with
  `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild` and the
  explicitly listed simulator UDID succeeded).
- Physical-device items for Guy's pass (not verifiable on the simulator):
  hero-glyph read as kangaroo + low-anchor pull at arm's length on device,
  tint appearance on the real display, and BLE-disconnected + connected
  empty-state transitions.
