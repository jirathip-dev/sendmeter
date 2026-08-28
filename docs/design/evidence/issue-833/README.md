# Issue #833 — Force context + Guided full-screen prototypes

Design-gate evidence only. These files do not implement product behavior. Native SwiftUI remains authoritative.

## Surface and source vocabulary

Primary surface: **Operate**; secondary surface: **Monitor**. A climber must understand the current phase and next physical action before decorative or historical information.

The prototypes extend the existing `GuidedForceProtocolView`, `SurfaceCard`, `GuidedGlassButtonStyle`, `ForceTraceChart`, and `SendmeterStyle` vocabulary:

- iOS system grouped background and SF system type
- 16 pt SurfaceCard rhythm and continuous corners
- Force primary / trace `#5B5FC7`
- Strength / rest `#DDB13A`
- Optimal `#2E96F0`, alert `#E5743A`, execution `#7B83EB`
- existing copy preserved: `Hands-free`, `Pull to start`, `Release to stop`

Illustrative protocol data (`Strength Repeaters`, 18.0 kg, 16.2–19.8 kg) must come from the real selected preset and resolved target plan in implementation.

## Variants

### V1 — Persistent identity header (conservative)

Guided full screen keeps protocol identity and details permanently above the phase card. Outside context groups device readiness, selected protocol, target, and Training Balance in the current card rhythm.

Trade-off: strongest continuity with current SwiftUI, but protocol identity consumes vertical space during every phase.

### V2 — Phase first + details disclosure

Guided full screen gives the current phase first position and places protocol identity in a collapsible details block. Outside context treats readiness as a compact status banner and uses progressive disclosure for protocol detail.

Trade-off: best timer prominence, but identity can become less glanceable if the details block is collapsed.

### V3 — Inline coach strip (recommended)

Guided full screen retains the compact existing composition, adds persistent protocol identity, then pairs target with the next physical action immediately under the phase. Outside context adds only a high-contrast hands-free strip, protocol details, target/side context, and explicit bottom clearance.

Trade-off: densest option and the target module has less room for long localized strings. It is the narrowest change and makes `Pull to start` / `Release to stop` fastest to find.

## Interaction

- Guided files: Rest / Armed / Work / Measuring controls update phase, metric, and hands-free copy.
- All files: `Show no target` replaces the value/range with an explicit `No target set` state.
- V2 files: protocol details disclosure toggles the optional detail block.
- Controls are at least 44 pt where they represent product actions; the prototype-only state dock uses compact labels for comparison.
- `prefers-reduced-motion` is honored.

## Verification

- Six PNGs rendered with `chrome-headless-shell` at exactly **390 × 844**.
- All six HTML files opened and their target toggle executed in a real browser session.
- All three Guided files also changed from Rest to Measuring and displayed `Release to stop`.
- Visual inspection confirmed the floating tab bar is visible and does not cover Training Balance or chart content in all outside-context captures.
- PNG SHA-256 hashes are in `capture.log`.

## Slop self-audit

Final score: **0 / 10**.

No tells fired. The purple is the shipped Force token, SF type is the native system choice, the centered countdown is the existing phase-control hierarchy rather than a generic hero, and the composition is Operate/Monitor rather than Decide/Learn. No feature grid, accent rail decoration, glass blur theater, monument stat, icon topper, or wrong-surface framing was introduced.

## Recommendation

Recommend **V3** for approval. It follows the issue's narrow-scope correction most closely: preserve the current Force composition, expose context and physical action, and reserve the tab-bar inset without broadly redesigning native UI.
