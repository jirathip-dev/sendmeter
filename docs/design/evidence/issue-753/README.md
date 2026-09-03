# #753 R2 — Recovery Inputs containment + 7d/28d parity — implementation evidence

Real simulator captures of the native iPhone app built from this worktree's
`orch/753-recovery-device-r2` head (Debug, `xcodebuild -scheme SendmeterNative`,
`-derivedDataPath /Volumes/NVMe2TB/DerivedData/Sendmeter753-r2`).
Captured via `xcrun simctl io <udid> screenshot` from the DEBUG-only
`--recovery-fixture` / `--recovery-fixture-scrolled` launch-argument harness
(`RecoveryInputsFixtureView` in `Sources/App/SendmeterNativeApp.swift`), which
presents the real `RecoveryInputsSheet` fed by a deterministic 60-day
representative history.

## Why this round (R2) exists

The first native fix (#871, merged as 19c62df) was still reported failing on a
physical device (issue #753 reopen, Build 50 / main c05bc64a): bars rendered
"uniform blue" with no visible above/near/below encoding of the 28-day
baseline, and no visible 7d/28d trend parity. Measuring the R1 evidence
(`docs/evidence/recovery-inputs-390x844.png`, committed by #871) instead of
eyeballing it exposes both root causes:

1. **The bar ramp could not saturate on real data.** `RecoveryBarGradient.position`
   mapped relative distance linearly over 0–100% of the baseline; a bar needed a
   ±100% excursion to reach an endpoint. Measured on the R1 fixture's own
   HRV bars: every bar renders between RGB ≈ (98,176,244) and (122,170,242) —
   a ΔRGB of ~24 across the whole row, i.e. one blue family. R1's frame
   contains **zero yellow-family pixels** and no perceptually purple bar.
2. **The 28d dashed series never rendered.** R1 (and the first R2 build) drew
   the 28d `LineMark` inside the same per-day loop as the 7d line with two
   differently named series keys and colliding numeric run values; Swift
   Charts silently dropped the second series. Pixel scan of both the R1 frame
   and the first R2 capture: **zero** reference-gray pixels in any plot area —
   only the solid 7d line existed. That is the device's "no visible 7d/28d
   parity": the 28d average was computed and null-aware, but never drawn.
3. **R1's evidence fixture could not demonstrate parity anyway**: it supplied
   only 14 days inside the 60-day warm-up window, so its "28d" line was a
   13-observation EWMA hugging the bars.

## Fixes in this round

- `Sources/Core/RecoveryInputs.swift` — `RecoveryBarGradient` saturation is
  bounded at 12% relative distance (`saturationRelativeDistance`), with
  per-direction exponents (`belowRampExponent = 0.08`, `aboveRampExponent =
  0.35`) so ordinary variance reads: clearly above that day's 28d EWMA →
  purple, clearly below → yellow, near → the neutral blue. Deterministic
  tests pin the ramp (RED proven against the pre-fix code first).
- `Sources/Features/Dashboard/RecoveryInputsSheet.swift` — both trend
  families now share one series dimension (`"Trend"`) with unique per-family
  values (`7d-run-N` / `28d-run-N`), each emitted by its own `ForEach` pass,
  drawn bars → 28d dashed → 7d solid (web draw order). Wiring tests pin the
  series keys so the dropped-series pattern cannot return.
- `Sources/App/SendmeterNativeApp.swift` (DEBUG only) — the evidence fixture
  now generates a deterministic 60-day representative history (fixed LCG +
  Box–Muller; no `arc4random`), with realistic ranges, wear gaps at offsets
  58/30 and a visible-window gap at offset 8; `--recovery-fixture-scrolled`
  scrolls the sheet to the bottom for the lower-card capture. Release builds
  are untouched (`#if DEBUG`).

## Device / OS / mode

- Device: iPhone 14 simulator (390×844 pt; 1170×2532 px @3x), UDID
  3828F6A5-0DA3-4687-9E7D-F751878850AD (lane-local "Sendmeter753-iPhone14")
- OS: iOS 26.5 (SimRuntime iOS-26-5)
- App: Sendmeter (bundle com.jirathip.sendlog.native, Debug build, launch arg
  `--recovery-fixture[ --recovery-fixture-scrolled]`)
- Theme: light (`simctl ui ... appearance light`)

## Files

| File | Proves | SHA-256 |
|---|---|---|
| recovery-inputs-390x844.png | Legend + HRV / Resting HR / Resp Rate / Sleep cards: bars visibly purple above / blue near / yellow below their 28d baseline; dashed 28d line visibly distinct from the solid 7d line; gap at offset 8 splits both lines; nothing escapes a card | d4ab8d2714737697a76309a30d1066a7b5ef5f3146209157504195fe0b958be5 |
| recovery-inputs-390x844-scrolled.png | Deep Sleep / REM Sleep / Weight cards + shared date axis (22 Aug / 29 Aug / 4 Sep): same color/lines/gap semantics; weight honestly stays neutral (its day-to-day change is inside the ±2% deadband of its own 28d average) | 0ec9c8b0b9b3c5b51d85cefe5c81b13984cfe1d06ec006f838d75020db251483 |

## Pixel-level audit (PIL 12.3.0, reproducible)

Sampled every 2nd pixel of each 1170×2532 frame and classified saturated
(ΔRGB ≥ 40) non-gray pixels:

R1 accepted frame (`docs/evidence/recovery-inputs-390x844.png`):
- yellow-family pixels: **0**; bar tones confined to one blue family
  (measured HRV bar span ≈ (98,176,244)…(122,170,242), ΔRGB ≈ 24).

R2 frame (`recovery-inputs-390x844.png`):
- yellow-family (below-baseline) pixels: **4298**
- purple/lavender family (above-baseline) pixels: **12421**
- sky-blue neutral family pixels: **1092**; indigo 7d lines: **4351**
- measured family centers — neutral (96,173,241), above (151,159,237),
  below (219,192,113) — three clearly separated colors.

Containment: vision + row-band pixel scans confirm every bar, both trend
lines, axis labels, and the legend stay inside their card; plots are clipped
(`plotArea.clipped()`) and bars use an explicit in-domain baseline. The shared
date axis renders once below the last card.

## Verification notes

- Both trend lines are genuinely warmed: the fixture supplies 46+ consecutive
  observations before the visible 14-day window, so the 28d EWMA is a real
  28-day average (alpha = 2/29, null-aware, first-non-null seed), visibly
  smoother and dashed vs the solid 7d line.
- The offset-8 gap appears in every row: no bar, and both lines split into
  two runs (run indices 1 and 2) without bridging.
- Capture sequence:
  1. Build with the color-ramp fix only → frame showed three bar color
     families but still no 28d line (confirmed the missing-series defect).
  2. Build with the series-dimension fix → dashed 28d line present in every
     row (this frame is `recovery-inputs-390x844.png`).
  3. Same build + `--recovery-fixture-scrolled` harness → lower cards and the
     shared axis (`recovery-inputs-390x844-scrolled.png`).
