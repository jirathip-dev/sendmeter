# Release notes

This is the canonical source of truth for user-facing changes since the last
App Store release. Add a concise, plain-language bullet under the best category
when a change affects what users can see or do (for example, `- Force recordings
now show the selected grip type in History.`). Leave out internal maintenance,
CI, dependency updates, and refactors unless users experience a change.

## Unreleased

### Added

- Reverse Action protocols can now run as a resumable cadence-only timer without a force sensor, with set progress and partial completion saved to History.

### Improved

- Reverse Action now keeps its live force trace visible and uses capacity models separate from Static holds, with clear protocol and model labels throughout Force.
- Force setup guidance now focuses on measurement equipment and your own reference marks without prescribing exercises or claiming to assess form.
- Training-load details now open from the ACWR card, with weekly and daily views plus a 28-day activity breakdown.
- Apple Watch boulder tracking now uses wrist motion, local height, and heart-rate changes to detect attempts and keep the climbing/rest display in sync automatically.

### Fixed

- Bottom sheets on mobile now keep their drag handle reachable while scrolling and respond to a short downward flick.
