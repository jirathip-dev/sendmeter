# #875 — tab reorder + approved mascots — implementation evidence

Real simulator captures of the native iPhone app built from this worktree's
`orch/875-tabs-mascots` head (Debug, `xcodebuild -scheme SendmeterNative`).
Captured via `xcrun simctl io <udid> screenshot`; appearance driven by
`xcrun simctl ui <udid> appearance light|dark`. No #868 design mockups were
reused — these are the actual rendered app surfaces.

## Device / OS / mode

- Device: iPhone 14 simulator (390×844 pt; 1170×2532 px @3x)
- OS: iOS 26.5 (SimRuntime iOS-26-5)
- App: Sendmeter (bundle com.jirathip.sendlog.native, Debug build, launch arg
  `--tabs-fixture <tab>` — the DEBUG-only evidence harness that presents the
  real `MainTabView` without a signed-in session)
- Theme: System (fresh install, so `simctl ui appearance` drives light/dark)

## Files

| File | Mode | Proves | SHA-256 |
|---|---|---|---|
| tabs-force-selected-light-390x844.png | light | Tab order Dashboard → Force → Workout → History → Settings; Force (R11 mascot) selected and tinted; Workout (R16 mascot) inactive; icons template-tinted like SF Symbols | 7369f14f123a49459fe18b7ec887c9183fb43cd7da585f8f11766e33fc068f7f |
| tabs-force-selected-dark-390x844.png | dark | Same order/selection in dark appearance | df60c62f852960266b5bad4aa98a799725121757c69a24dd20132969291904ac |
| tabs-workout-selected-light-390x844.png | light | Workout (R16 mascot) selected and tinted; the Manual workout card shows the WorkoutMascotLarge (optical 160 master) tinted SendmeterStyle.primary, plus "Manual workout" title and "Start Manual workout" button | 89278b083276a23ff53104cfd4940d90a9401aaa6592bd36caab489f571dd408 |
| tabs-workout-selected-dark-390x844.png | dark | Same Workout-selected state + card in dark appearance | 31af8ee04c4e47d728aaf9195f67a8b22defda3f379202976277012c6b306827 |

## Verification notes

- Pixel-level check (BMP decode): selected Force icon renders the primary tint
  (light ≈ RGB(80,84,190); dark ≈ RGB(120,124,228)); inactive mascot icons
  render the tab bar's inactive gray (light ≈ RGB(25,25,29)) — identical
  treatment to the SF Symbol tabs — confirming the explicit
  `.renderingMode(.template)` wiring.
- Tab assets are byte-identical copies of the approved #868 revision-16 SVG
  masters (r11-force-control-24, workout-r16-exact-24,
  workout-r16-optical-160, r11-force-control-160); hashes match the design
  worktree sources.
- Capture log: 4 screenshots, one per (appearance, selected tab) pair,
  taken ≥6 s after launch (splash floor + boot-state resolution).

---

## #875 r2 — Force tab glyph real-size legibility (device reopen)

Reopened because Build 50's selected Force tab glyph did not retain a clear
kangaroo-deadlift/barbell read at real tab size on a physical device, although
the rendered SVG was byte-identical to the approved R11 24 px master
(`ed6dab81…`, verified). Investigation result: every delivered-rendering axis
was faithful — the wired asset is the approved master, the tab draws it at its
natural 24 pt size (measured 69×66 px @3x == the master's 24 pt ink box), and
template tinting is correct in both modes. The failure was the 24 pt optical
presentation itself: the artwork's paw/plate separation and barbell negative
space collapse at 24 pt (design history flagged this "legibility floor" in
#868 R5/R6 QA), so no hash/asset test could catch it.

Fix (R11 geometry frozen, rendering only): the Force tab now presents the SAME
approved master as pinned 1x/2x/3x rasters at a 28 pt optical size in
`ForceMascotTab.imageset` (the master SVG remains in the imageset as the
hash-pinned provenance anchor; Workout is untouched). Measured on screen:
Force icon ink grows from 69×66 px (23.0×22.0 pt) to 80×76 px @3x
(26.7×25.3 pt) — the barbell bar/plates and ear separation now read at real
tab-bar size in light + dark, selected + inactive.

### Files

| File | Mode | Proves | SHA-256 |
|---|---|---|---|
| r2-tabs-force-28pt-selected-light-390x844.png | light | Force tab selected; R11 master at the 28 pt optical presentation, template-tinted | 5b3dfe34a85a69a47c3945db1fa7957bb104434c83b24e63ba57975d890e3f32 |
| r2-tabs-force-28pt-selected-dark-390x844.png | dark | Same selected state in dark appearance | bb7258e9168467b19e38997e12e45bf4a69c8ba7768a4c81a8aed1737c1cc024 |
| r2-tabs-workout-selected-light-390x844.png | light | Force tab INACTIVE (gray) at the 28 pt presentation; Workout R16 untouched and selected | a34374603755372d11298ba5f83333c731e80e28312d7395605f23523deb6224 |
| r2-tabs-workout-selected-dark-390x844.png | dark | Same inactive Force / selected Workout state in dark appearance | bc0f2b478816cfcd587c7c0041e6709601f2b8194b15616cced9eb754aa5f2fa |
| r2-compare-force-selected-light-24-vs-28.png | light | Actual-size strip: Force selected 24 pt (old) vs 28 pt (new) | 5a638d74b8a152826f8b44db2715a1e9e583a317856a6af4b7c2a9fe40689c13 |
| r2-compare-force-selected-dark-24-vs-28.png | dark | Actual-size strip: same comparison, dark | 318d09a6250bd5888bb5c2000ecf4acf2394f0fe415c0aa5a2a3b489a301256c |
| r2-compare-force-inactive-light-24-vs-28.png | light | Actual-size strip: Force inactive 24 pt (old) vs 28 pt (new) | fdd35ec4c7cae6d8a8b8d84218aeeb5fe9220d5b775a7ea965809bace7d7a2c1 |
| r2-compare-force-inactive-dark-24-vs-28.png | dark | Actual-size strip: same comparison, dark | ae224b5e15cb0d91012b46b16594b661953dfd0cae96796370522242d0b92f9b |

### Verification notes

- Same capture pipeline as the #878 set: real Debug build of this branch,
  `--tabs-fixture <tab>` harness, `simctl io screenshot` @3x (1170×2532 px =
  390×844 pt), iPhone 14 simulator, iOS 26.5, `simctl ui appearance` light/dark.
- Icon ink bbox measured from the rasters (PIL): selected Force =
  80×76 px @3x in light (80×77 px dark) vs 69×66 px @3x at the 24 pt baseline —
  the pinned raster scale is what UIKit actually draws (verified at 24 pt and
  30 pt probe builds: natural-size drawing, no tab-bar downscale).
- Raster provenance: `r11-force-control-28pt@*.png` are deterministic librsvg
  renders of the approved master (`rsvg-convert -w 28/56/84`); SHA-256 pinned
  in `TabGlyphRenderingWiringTests` with a documented repro command.
- Discriminating gate: `Tests/SendmeterCoreTests/TabGlyphRenderingWiringTests.swift`
  pins template wiring, resource wiring, the master hash, raster scale, raster
  content identity, and the untouched Workout vector imageset; RED-probed on
  all four axes (scale regression → exit 1; content swap → exit 1; master
  mutation → exit 1; template→original → exit 1).
- Physical-device items for Guy's single end pass (not verifiable on the
  simulator): final read of the 28 pt Force glyph at arm's length on the
  device, and feel/balance of the slightly larger inactive glyph next to the
  other tabs.
