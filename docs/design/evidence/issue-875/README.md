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
