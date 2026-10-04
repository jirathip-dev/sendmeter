# Issue #998 evidence index

`#998` — the guided full-screen's Target Coach card is rendered only while a
pull is being measured (hold / reverse-out / reverse-return / paused); it is
gone from rest, set-rest, prepare, side-switch and complete.

## Build identity

All measurement legs were captured from the final lane tree (committed as
`2beab74`) and the app-target suite afterwards; the build was:

```
xcodebuild -project native/SendmeterNative/SendmeterNative.xcodeproj \
  -scheme SendmeterNative -configuration Debug \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath <worktree>/.xcode-derived build
```

`Sendmeter.debug.dylib` sha256 =
`9da6471e77469820660e699713a6745c87e09018369e573b1c19ef0a2d6fb514`.
Every measurement log proves the installed app against that hash before and
after the capture (`shasum -a 256` of the built and installed dylib).

## Measurement legs (`measurement-<device>-<size>-<state>.log` + `.png`)

Fixture: `--guided-force-fixture=<rest|work> --guided-force-fixture-measure`,
the #993 harness (`ForceView.swift`, section `GuidedForceMeasurementProbe`).

| log | device | text size | state | scrollContent / viewport | fits |
|---|---|---|---|---|---|
| `measurement-se3-default-rest` | iPhone SE 3G, 375×647 | default | SET REST | 680.5 / 647 | false |
| `measurement-se3-default-hold` | iPhone SE 3G, 375×647 | default | HOLD | 785.0 / 647 | false |
| `measurement-se3-axxxl-rest` | iPhone SE 3G, 375×647 | accessibility XXXL | SET REST | 2057.1 / 647 | false |
| `measurement-pro17-default-rest` | iPhone 17 Pro, 402×778 | default | SET REST | 685.4 / 778 | true |
| `measurement-pro17-default-hold` | iPhone 17 Pro, 402×778 | default | HOLD | 806.4 / 778 | false |

`measurement-pro17-default-rest-prefix-churn.log` and
`-prefix-blank-capture.png` are the **pre-fix** capture from the first slice
(`deb2923`): with the rest screen fitting, the measured-driven chart growth
oscillated (chart 151.7 ↔ 168.7, ~100 probe prints/second across 40 s) and the
full-screen cover never drew. The fix (`2beab74`) resolves the growth from the
static budget; the same leg is stable afterwards (2 probe lines, screen drawn).

## Gates

| log | gate | raw exit |
|---|---|---|
| `just-list.log` | `just --list` | 0 |
| `just-slop.log` | `just slop` | 0 |
| `just-core.log` | `just core` (1513 tests) | 0 |
| `just-gen.log` | `just gen` | 0 (project.yml untouched) |
| `build-ios-recipe.log` | `just build-ios` raw recipe | 74 (documented host condition: default DerivedData path) |
| `build-ios-authority.log` | first-slice authority build (`deb2923`) | 0, BUILD SUCCEEDED |
| `build-ios-authority-final.log` | final-head authority build | 0, BUILD SUCCEEDED |
| `app-target-suite*.log.gz` | CI-shape `xcodebuild test -only-testing:SendmeterNativeTests` | final head: **0 — TEST SUCCEEDED, 171 tests, 0 failures** |

## RED/GREEN receipts

- `red-coach-during-rest-mutation.log` — mutant renders the coach during
  `.rest`; `testTargetCoachRendersOnlyWhileAPullIsMeasured` fails (raw exit 1)
  with `("true") is not equal to ("false") - rest must not render the Target
  Coach`; restored → pass, raw exit 0.
- `red-chart-growth-measurement-feedback.log` — mutant resolves the chart
  growth from the measured stack again;
  `testChartGrowthResolvesFromTheStaticBudgetSoAMeasurementCannotMoveIt` fails
  (raw exit 1, 2 failures); restored → pass, raw exit 0.
