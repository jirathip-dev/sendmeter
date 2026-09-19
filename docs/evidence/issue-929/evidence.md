# #929 — Training Load axis labels: rendered evidence

Lane: `impl-929` · worktree `/Users/jirathip/.herdr/worktrees/sendmeter/impl-929`
Base: `3df082cf3a1e21cf756cda4aa4d4fd5a30908f86` (`origin/staging`)

Two capture methods, both named below; neither is device evidence (#881 stays
the release tracker for physical-device readability).

## 1. Offscreen renders (`training-load-axis-929-*.png`)

Produced by the app-target test
`Tests/SendmeterNativeTests/TrainingLoadAxisLegibilityTests.swift`, which
mirrors `TrainingLoadSheet.weeklyLoadSection` (title + delta chip + the real
`WeeklyBarsView` inside `SurfaceCard`, 16 pt screen padding, 375 pt wide — the
iPhone SE (3rd generation), the narrowest supported phone) and renders it with
`ImageRenderer` at scale 2 inside the iOS 26.5 simulator (`impl929-sim`,
iPhone SE (3rd generation), UDID `CDC56602-94B2-4802-A09A-F7E41D154F76`).

```bash
xcodebuild test -project native/SendmeterNative/SendmeterNative.xcodeproj \
  -scheme SendmeterNative -destination "id=CDC56602-94B2-4802-A09A-F7E41D154F76" \
  -only-testing:SendmeterNativeTests/TrainingLoadAxisLegibilityTests \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /Users/jirathip/impl929-derived
# → ** TEST SUCCEEDED **, 6 tests, 0 failures (exit 0)
```

The test writes the PNGs into the app's Documents directory
(`impl929-evidence/`); they were copied here and their sizes re-measured.

| Capture | pt (at 2×) | What it shows (lane reading) |
|---|---|---|
| `…populated-normal-light.png` | 375 × 251 | Title, delta chip, empty reserved tooltip slot, four bars with `630 / 1,050 / 600 / 1,232` above them and `3w / 2w / 1w / Now` below. No values list (every label fits at the default text size). Nothing clipped or overlapping. |
| `…populated-normal-dark.png` | 375 × 251 | Same layout in dark mode. |
| `…populated-normal-dark-selected.png` | 375 × 251 | The selected `Now` bar (outlined) with the tooltip `Now / 1,232 AU / ▲ 17% vs prior wk` inside the card; the chart below it does not move (reserved slot). |
| `…sparse-normal-light.png` / `…sparse-normal-dark.png` | 375 × 251 each | The sparse dataset (`0 / 0 / 300 / 360`): zero weeks draw the 2 pt minimum stubs, all four labels drawn. |
| `…populated-ax5-light.png` / `…populated-ax5-dark.png` | 375 × 970 each | Accessibility size: title and chip each wrap to their own lines (the chip no longer squeezes the title into `WEE/KLY/LOA/D`), the reserved slot is empty, four bars on ONE baseline with **no** value labels above them and `3w / 2w / 1w` below (`Now` does not fit its column), and the exact values list `3w 630 AU / 2w 1,050 AU / 1w 600 AU / Now 1,232 AU` below the chart. |
| `…sparse-ax5-light.png` / `…sparse-ax5-dark.png` | 375 × 970 each | Same at accessibility size for the sparse set: the 1-character `0` totals still fit their columns, `300`/`360` do not, and the list carries all four values. |
| `…populated-ax5-light-selected.png` | 375 × 970 | Accessibility size with the `Now` bar selected: the tooltip wraps inside the card (its left/right edges stay inside the card border) and the chart and list below are unchanged. |

Measured by the same test (printed): `UIFontMetrics(forTextStyle: .caption2)`
`.scaledValue(for: 11)` = **11.0 pt** at the default size and **40.5 pt** at
`.accessibility5`; the `caption2` Text band is **16.0 pt** / **59.0 pt**; the
chart's own height is **108 pt** at the default size (unchanged from the
shipped chart) and **194 pt** at `.accessibility5`; the reserved tooltip slot
is **60 pt** / **≈221 pt** (the `caption2` scaling of that base) against a
measured three-line tooltip of **199.5 pt**.

The renders are cropped to the drawn content by the lane's harness: the
simulator's `ImageRenderer` sizes its canvas from the layout pass that runs
before `WeeklyBarsView`'s width state settles, so an un-cropped accessibility
render loses the values list at the bottom edge. The crop only removes blank
canvas (verified: the committed accessibility captures end on the last list
line).

## 2. Simulator screen captures (`simulation-929-*.png`)

Real app on the same iPhone SE (3rd generation) simulator, driven by the
existing `--training-load-fixture` / `--training-load-empty-window-fixture`
launch arguments (`Sources/App/SendmeterNativeApp.swift`), with the
simulator's own content-size and appearance settings changed through `simctl`:

```bash
xcrun simctl ui <udid> appearance light|dark
xcrun simctl ui <udid> content_size large|accessibility-extra-extra-extra-large
xcrun simctl launch <udid> com.jirathip.sendlog.native --training-load-fixture
xcrun simctl io <udid> screenshot simulation-929-<name>.png
```

| Capture | Shows |
|---|---|
| `simulation-929-populated-normal-light.png` / `…-normal-dark.png` | The whole sheet at the default text size: Weekly load card with the four bars, their `2,640 / 2,400 / 2,280 / 2,670` labels, `3w / 2w / 1w / Now`, the delta chip, and **no** values list (no label is omitted at this size); Daily load heatmap and Activity mix unchanged below. |
| `simulation-929-populated-ax5-light.png` / `…-ax5-dark.png` | Accessibility size: the title and the delta chip each get their own line; the bars sit below the fold of the 667 pt screen (the tooltip slot and the chart bands are all larger), so the values list is not visible on this screen — the offscreen captures above carry it. |
| `simulation-929-emptywindow-normal-light.png` | The empty-window fixture: four 2 pt stubs with `0` values and week labels, `Daily load — No training load in the past 53 weeks.`, `Last 28 days · 0 AU` — the honest empty states, unchanged. |
| `simulation-929-emptywindow-ax5-light.png` / `…-ax5-dark.png` | The same fixture at accessibility size. |

## Known limits of this evidence

* Not device pixels: the offscreen renders run in the app process and the
  screen captures come from the iOS 26.5 simulator. Physical-device
  readability (issue AC6) stays OPEN; #881 is the release tracker.
* The accessibility-size **values list** is proved by the offscreen renders and
  by the test's assertions; on the 667 pt SE screen it lies below the fold, so
  the screen captures cannot show it (no scroll injection is available to this
  lane — `Tests/SendmeterNativeUITests` is outside the slice's fence).
* The tooltip's *interaction* (tap/scrub/haptics) is unchanged code with its
  existing tests; the selected-state captures come from the
  `WeeklyBarsView(initialSelection:)` evidence seam rather than from a touch.
