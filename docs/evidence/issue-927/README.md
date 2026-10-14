# #927 follow-up — the Dashboard large title rendered over the shared error banner

Owner report: build-57 device screenshot (2026-10-06 06:22). The Dashboard's large title was drawn
**on top of** the error banner ("iPhone is set aside" / "account." covered).

## Captures (iPhone 16 Pro simulator, iOS 26.5, 1206×2622 px = 402×874 pt @3x)

Every capture is the **real banner over the real tab screen**: the DEBUG harness
`--error-banner-fixture <copy> --tabs-fixture <tab>` sets `model.errorMessage` (real
`UserFacingError` copy), and `RootView`'s production `ErrorBannerHost` draws the banner over the
real `MainTabView`. Installed bundle proven by `Sendmeter.debug.dylib` sha256
`ab4b71ee2741da7c20551d533f0d8bb003e07aea1c9042090f77d1e1b6e47322` (build output and the installed
container match; `.reports/927-evidence-dylib.sha`). Text size driven with
`xcrun simctl ui <udid> content_size large | accessibility-extra-extra-extra-large`, appearance with
`simctl ui <udid> appearance light|dark`, captured with `simctl io <udid> screenshot`.

| File | Text size | Copy | Shows |
| --- | --- | --- | --- |
| `dashboard-default-light.png` | default (`large`) | the build-57 copy (`.dataUnreadable`) | full 4-line message + ✕ in an opaque banner; **Dashboard** large title laid out below it |
| `dashboard-default-dark.png` | default | same | same, dark |
| `dashboard-largest-light.png` | largest (`accessibility-extra-extra-extra-large`) | same | glyph + ✕ on the top row, the whole message across the banner width (9 lines, ends "account."); Dashboard title starts below the banner |
| `dashboard-largest-dark.png` | largest | same | same, dark |
| `dashboard-largest-longest-light.png` | largest | longest copy (`.authClockSkew`) | the whole message ("…then try again.") and ✕ on screen |
| `force-largest-light.png` / `workout-largest-light.png` / `history-largest-light.png` / `settings-largest-light.png` | largest | build-57 copy | every other large-title tab: banner whole, title below it |

At the largest size the banner takes most of the screen; the tab content (title first) is pushed
below it and stays reachable by dismissing the banner. Nothing is drawn over the banner.

`SHA256SUMS` pins the PNGs. Gate logs and the RED/GREEN pair live in `.reports/` at the lane root
(`.reports/927-lane-report.md`).

## Not proven here (owner-gated)

The physical-device check, and the VoiceOver spoken-output / haptic residuals tracked with #881.
