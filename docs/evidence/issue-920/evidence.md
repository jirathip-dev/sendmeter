# Evidence — issue 920 (native/sync UX: pending status and Retry reflect the actual recoverable mutations)

Lane `impl-920` (worktree `~/.herdr/worktrees/sendmeter/impl-920`), base
`origin/staging` = `02e3d8968ace81b46eeb9b014e239d193bafcd54`.

Everything below was produced by a real run on this host; no frame, log or
number is hand-written. Frames come from the app-target suite
`SyncSurfacesRenderEvidenceTests.testCaptureSettingsAndEditorFrames`
(simulator `impl920-sim`, UDID `C604626D-CABE-4525-AA4F-3B9F4FE1A7E8`, iOS 26.5,
iPhone 17 Pro, 3× — 402 × 874 pt logical, 1206 × 2622 px).

## UI frames (rendered evidence, AC6)

The test hosts the REAL `SettingsView` / `TagManagerView` in a real `UIWindow`
on the app's own `UIWindowScene`, scrolls the hosting list to the bottom (where
the sync section sits), lays it out and captures the window hierarchy with
`drawHierarchy(in:afterScreenUpdates:)` at 3×. The PNGs in this directory are the captures of
`xcodebuild test … -only-testing:SendmeterNativeTests/SyncSurfacesRenderEvidenceTests`
(exit **0**, `Executed 1 test, with 0 failures`, seven `EVIDENCE_FRAME` lines),
copied out of the app container immediately afterwards; that raw log is
committed here as `render-evidence.log.gz`. The earlier full focused run
(`docs/evidence/issue-923/app-target-focused.log.gz`, also 13/0 with the same
seven frame lines) captured through the pre-fix path whose `layer.render`
frames came out black — the delivered PNGs are the post-fix captures. A bare
`SettingsView().aboutSupportSection` read is **not** renderable — SwiftUI reads
that view's `@Environment(AppModel.self)` outside a view installation and
crashes (`Accessing Environment<AppModel>'s value outside of being installed on
a View`) — which is why the whole installed screen is captured instead.

| file | sha256 | what it shows |
|---|---|---|
| `settings-data-sync-light.png` | `44abf82813bdc8c07a8fc38653739a9b6b7e121a7e61fd9467b20cf4ab0b4c2a` | Settings → About & Support at `.large`, light: pill **“5 waiting to upload”** (caution), “5 local changes saved on this iPhone and not uploaded yet. Use Retry Now to upload it.”, enabled **Retry Now**, “Rejected uploads — None”. |
| `settings-data-sync-dark.png` | `af702613faa0b16f572d5b25b4e64d65d6575f34a03b5e8006620b7ad6a6fc3f` | the same state in dark. |
| `settings-data-sync-ax5.png` | `d5afa91a21c88004c7539c62b0b041fd83aef7f0302bd5d214d29ea38e86643c` | the same state at `.accessibility5` (content height 4573 pt, scrolled 2858 pt). |
| `settings-retry-blocked-light.png` | `811bc51a9a4bf813f0cda01c3810b1681f6056be3ee01083722ed5b5353b244b` | **after one retry pass** with an un-adoptable settings/training-block residue: pill **“3 stayed on this iPhone”** (alert), “3 local changes could not be uploaded and stayed on this iPhone…”, **Retry Now disabled** (greyed) plus the honest explanation “Retrying cannot move these changes: this app version has no upload path for them, so they stay on this iPhone until they are re-saved.” — the AC2 no-silent-no-op state. |
| `settings-partial-refresh-dark-ax3.png` | `1b9779664963a70ce3473af883930fd6bf7e0ca971c945a02bb550d2b996e226` | #923 AC4 in dark at `.accessibility3`: the same section with the scoped partial-refresh failure row (“Health metrics didn’t refresh (…)”) under the pending row. |
| `tag-editor-pending-light.png` | `72c5d325c4b0505f0b8e6bf668874e442045959406fa88f5d0478282e3a087ff` | the real affected editor (`Manage Exercises` / `TagManagerView`) listing “Crimp · hidden · 1 rep”, with the new “Not uploaded yet” section: “1 exercise change saved on this iPhone and not uploaded yet.” + **Retry Now**. |
| `tag-editor-pending-dark-ax3.png` | `2dd49780f66829b77cc5f8ee316f20f4248d1778359fc608a8a9a5fb7889dc96` | the same editor in dark at `.accessibility3`. |

VoiceOver meaning is carried by the accessibility contract in the same diff
(`StatusPill` gets `accessibilityLabel("Upload status")` +
`accessibilityValue(statusLabel)`, and every row/control has a stable
`accessibilityIdentifier`). **The physical-device VoiceOver pass stays OPEN** —
it needs real hardware, which this host does not have.

## Logs in this directory

| file | command | outcome |
|---|---|---|
| `core-tests.log.gz` | `swift test --package-path native/SendmeterNative --filter MutationSyncStatusTests` (GREEN) | 13 tests / 0 failures |
| `core-tests-923.log.gz` | `swift test --package-path native/SendmeterNative --filter RefreshSlicePlanTests` (GREEN) | 12 tests / 0 failures |
| `app-target-focused.log.gz` | `xcodebuild test … -only-testing:SendmeterNativeTests/SyncSurfacesAppTests -only-testing:SendmeterNativeTests/SyncSurfacesRenderEvidenceTests …` (GREEN) | 13 tests / 0 failures, exit 0, 7 `EVIDENCE_FRAME` lines |
| `probe-*.diff` | the RED/GREEN splice probes (see the report) | each probe's mutation, verbatim |

The full CI-shape app-target suite, `just fast`, and every probe invocation are
logged under `docs/evidence/issue-923/` and `docs/evidence/issue-920/probe-*`
and cited with raw exits in `.report-1.md`.
