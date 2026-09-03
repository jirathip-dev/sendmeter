# #880 — Workout History HR/effort chart axis gutter — implementation evidence

Real simulator captures of the native iPhone app built from this worktree's
`orch/880-history-axis-gutter` head (Debug, `xcodebuild -scheme SendmeterNative`).
Captured via `xcrun simctl io <udid> screenshot`; appearance driven by
`xcrun simctl ui <udid> appearance light|dark`. The chart stack is the REAL
`WorkoutHrChartView` + `WorkoutEffortChartView` composition `SessionDetailView`
builds (SurfaceCard + shared tMax + shared scrub binding), driven by the
DEBUG-only `--workout-charts-fixture` harness with a synthetic 50-minute watch
workout (1000 HR samples at the watch's 3 s stride, four attempts with manual
and detected sources).

## Device / OS / mode

- Device: iPhone 14 simulator (390×844 pt; 1170×2532 px @3x)
- OS: iOS 26.5 (SimRuntime iOS-26-5)
- App: Sendmeter (bundle com.jirathip.sendlog.native, Debug build, launch arg
  `--workout-charts-fixture` — the DEBUG-only evidence harness that presents
  the workout-detail chart card without a signed-in session)
- Theme: System (fresh install, so `simctl ui appearance` drives light/dark)

## Files

| File | Mode | Proves | SHA-256 |
|---|---|---|---|
| workout-charts-before-light-390x844.png | light, pre-fix | The defect reproduced on this build: both charts' Y labels ("167 bpm", "142", "117", "10 eff", "0") render in a TRAILING strip — the plot stops short of the card's right edge and the labels sit detached from the data | 6f11c942e17490d7b6ab15a229f021a127ea0cd8ad638aaae4f8afa4dd476d69 |
| workout-charts-light-390x844.png | light, fixed | Y labels pinned to the leading edge; the HR line/area and effort bars now fill the full card width to the plot's right edge; 0:00/25:00/50:00 X labels aligned and unclipped; the trailing label strip is gone | 1100a57d4a08013297c3988da0a5920a6a4ec63460fa30cd7b9b575ffb9d5850 |
| workout-charts-dark-390x844.png | dark, fixed | Same fixed layout in dark appearance (labels leading, data to the right edge) | 5e355092c386ecf7cb87ac9b61a0f3629788ce463ef06aa8bf867a61127c6bcc |

## Pixel-level verification notes

- Right-edge strip analysis (x 960–1170 of the 1170 px frame) on the light
  pair: the PRE-FIX strip contains all five Y labels and no data marks — the
  reserved trailing gutter; the FIXED strip contains no bpm/eff labels, the
  blue HR area/line reaches the plot's right-edge gridline, and each chart's
  "50:00" label ends at that edge unclipped.
- Bottom-left corner check (effort chart): the "0" Y label and "0:00" X label
  sit cleanly separated — no overlap at the leading edge.
- The HR recovery caption ("−27 bpm"), attempt-window shading, effort bars
  (manual=caution, detected=optimal), and the scrub binding are the unchanged
  real views; tooltips/haptics/VoiceOver are untouched source paths (see the
  chart files' diffs — axis position only).

## Verification notes

- The before capture is from the same worktree HEAD with the two chart files
  reverted to the staging version (the fix's two-line change re-applied
  afterwards); all other files identical.
- Capture log: 3 screenshots, one per (state, appearance) pair, taken ≥12 s
  after launch (splash floor + boot-state resolution).
- Physical-device/TestFlight check items for Guy's single pass are listed in
  the PR body (real long workout, Dynamic Type sizes, RTL not applicable).
