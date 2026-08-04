# Release notes

This is the canonical source of truth for user-facing changes since the last
App Store release. Add a concise, plain-language bullet under the best category
when a change affects what users can see or do (for example, `- Force recordings
now show the selected grip type in History.`). Leave out internal maintenance,
CI, dependency updates, and refactors unless users experience a change.

## Unreleased

### Added

### Improved

- See your 28-day activity mix at a glance with a proportional training-load bar.
- Filter History by session type and Force tag, including loose Force recordings.
- Force: Hands-free mode now runs every static sensor protocol pull-by-pull, records completed and early-release outcomes, and waits safely for unload before the next rep.
- Force equipment setup is now concise, optional guidance without checklists or training blockers.
- Switch the Force protocol list clearly between Static and Reverse Action modes, with color-coded badges and mode-matched presets.

### Fixed

- Restore the Tare button in the Force fullscreen gauge so a non-zero load-cell baseline can be zeroed again.
- Force: fixed hands-free adaptive reps failing to save (with a "Failed to save recording" error) after the first rep of a run.
- Routine now has its own distinct color in the activity-mix bar, legend, and heatmap instead of looking identical to Antagonist.
- Activity-mix percentages no longer round a real, visible share down to 0% — small shares now show as "<1%".
- Fixed grouping a just-edited Force recording into a session (or moving it into an existing one) sometimes leaving it stuck showing as loose until reload.
- History, Peak Force Trend, and %BW now date recordings by your local day instead of UTC, so sessions and reps made before 07:00 no longer land on the wrong day.

## 1.0 — 2026-08-02

### What’s New in This Version

- Train Reverse Action protocols with or without a Tindeq: cadence-only sessions save progress, while measured results stay separate from Static holds.
- Set up Force sessions with clearer equipment guidance and repeatable reference marks.
- Open the ACWR card for weekly, daily, and 28-day training-load details.
- Let Apple Watch detect bouldering attempts automatically from wrist motion, height, and heart-rate changes.
- Dismiss mobile sheets more reliably with an easier-to-reach handle and a short downward flick.
