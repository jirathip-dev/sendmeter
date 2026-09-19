# #928 — Force chart axis labels: rendered evidence

Lane: `impl-928` · worktree `/Users/jirathip/.herdr/worktrees/sendmeter/impl-928`
Base: `a5e986865cd6d4d6baacbf25375862279e76529c` (`origin/staging`)

## How these captures were produced

They are rendered by the app-target test
`Tests/SendmeterNativeTests/ForceCurveAxisLegibilityTests.swift`, which builds
the REAL `NativeForceCurveCard` and `ForceProgressCard` exactly as `ForceView`
stacks them (16 pt screen padding over `systemGroupedBackground`, card width
375 − 2 × 16 = 343 pt) and renders them with `ImageRenderer` at scale 2 — the
iPhone SE (3rd generation)'s pixel density — inside the iOS 26.5 simulator
(`impl928-sim`, UDID `3F595614-FCC7-4DAB-BACA-0B74C54BE53C`).

Fixture: the same curve the Core golden tests pin (1–120 s, 24.8–44.2 kg,
48 kg band top, a 27–33 kg plan target) plus six static-capacity recordings, so
the metric row, the legend, the axis labels and the tile captions all carry
real values.

```bash
xcodebuild test -project native/SendmeterNative/SendmeterNative.xcodeproj \
  -scheme SendmeterNative -destination "id=3F595614-FCC7-4DAB-BACA-0B74C54BE53C" \
  -only-testing:SendmeterNativeTests CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /Users/jirathip/impl928-derived
# → ** TEST SUCCEEDED **, 50 tests, 0 failures (exit 0)
```

The test writes the PNGs into the app's Documents directory
(`impl928-evidence/`); they were copied here with `cp` and their SHA-256s
re-verified.

## Captures

| Capture | SHA-256 | Pixels | Points (pt) |
|---|---|---|---|
| `force-chart-axis-928-normal-light.png` | `55dc7bc1be258a7a98a88334926f0f6790e231efcb7526c3cf27517940b461ae` | 750 × 1216 | 375 × 608 @2x |
| `force-chart-axis-928-normal-dark.png` | `8c3bdeff5294c9c81b131b676f4da18a0ecddde5d7c00d1e309d66613e4125e2` | 750 × 1216 | 375 × 608 @2x |
| `force-chart-axis-928-ax5-light.png` | `e844168ad9a7c7d5951c9eaafc039a45545e4e0bd074bce1c88d231cd31c2fec` | 750 × 4947 | 375 × 2473.5 @2x |
| `force-chart-axis-928-ax5-dark.png` | `d636f49e375e8d42f73a04a5b8a275b20bd39209a70cccdbd13e78613c4a4bbf` | 750 × 4947 | 375 × 2473.5 @2x |

`normal` = default text size (`.large`), `ax5` = the largest accessibility size
(`.accessibility5`). The measured label size at those sizes is printed by the
same test: `UIFontMetrics(forTextStyle: .caption2).scaledValue(for: 11)` is
**11.0 pt** at `.large` and **40.5 pt** at `.accessibility5`.

## What each capture shows (inspected by the lane)

**normal-light / normal-dark.** The curve card draws y labels `53 / 26 / 0`
inside its plot column and all four admitted x labels `1s / 10s / 60s / 120s`
under the plot, centred on their gridlines, with no collision and nothing
clipped at either edge (the trailing inset now reserves the half-width of the
longest label). The metric row (`Max 46.3 kg`, `CF 24.6 kg`, `W′ 1,234.5 kg·s`)
and the legend (`Hill fit`, `95% band`, `Plan target`) are fully inside the
card; the tile captions (`Latest kg`, `Best kg`, `Recordings`) and the
empty-state sentence are inside their tiles. Light and dark are identical in
layout.

**ax5-light / ax5-dark.** The curve card's y labels `53 / 26 / 0` and three x
labels `1s / 10s / 120s` remain inside the plot; the density rule dropped the
`60s` label, which no longer clears its neighbour by the 6 pt gap at 40.5 pt
(asserted in `ChartAxisLabelRuleTests`). The metric row reads one value per
line (`Max 46.3 kg` / `CF 24.6 kg` / `W′ 1,234.5 kg·s`) with units intact, and
the legend reads one entry per line. The two progress tiles stack full-width,
so their titles, values (`39.0`, `39.0`, `6`) and captions are readable instead
of truncating to stubs.

## Known limits of this evidence

* It is an **offscreen `ImageRenderer` render inside the app process**, not a
  device or simulator screen capture: the layout engine is the real SwiftUI
  one at the real 375 pt width, but the compositor is not the phone's. The
  Force tab has no launch-argument fixture for these two cards (that seam lives
  in `Sources/App/SendmeterNativeApp.swift`, outside this lane's fence), so a
  screen capture is not reachable from this lane.
* In the `ax5` render the plan-target line (`Plan target 30.0 kg · range
  27.0–33.0 kg`) wraps to two lines and ends in a truncation ellipsis. That
  element is untouched by this slice (its `.caption` font was already
  Dynamic Type-aware and no modifier of it changed) and no `lineLimit` exists
  in the app or in the slice for it; the app's `ScrollView` layout was not
  re-verified for this element. It is listed in the lane report as not
  verified rather than claimed as fixed.
* Physical-device readability acceptance (issue AC6) stays OPEN: these
  captures are not device evidence.
