# Sendmeter Native — Parity Gauntlet brief (batch 2)

Owner: orch-sendmeter (all-DeepSeek/opencode, gauntlet protocol).
Goal: close the remaining native/web parity gaps so the SwiftUI target can
reach the physical iPhone/watch soak gate (docs/native-swift-rewrite.md) while
the Capacitor and native implementations remain separately validated.

Status note: #637's dispatch-only native TestFlight path is now present in
`.github/workflows/native-testflight.yml`. Issue #768 also makes the native
Release configuration use the shipped Sendmeter app record and embed the
existing Apple Watch companion. The physical soak and promotion gates below
remain device-only.

## Order of attack — #637 FIRST

### P1 (#637) — TestFlight/CI distribution path for SendmeterNative
- The native target has a dispatch-only TestFlight/CI path. This unblocks
  physical-device testing of every other parity item, so it goes first in the
  historical batch order. #768 keeps that path aligned with the embedded watch
  companion.
- Deliverable: a working CI pipeline (XcodeGen `native/SendmeterNative/project.yml`
  → xcodebuild → signed build → TestFlight upload via fastlane or gh actions)
  that Guy can actually ship from. Requires the repo's signing/distribution
  setup — check `fastlane/` and existing `ios-ci.yml` patterns first.

### P2 (#633) — routine completion ≥60s gate (web parity)
- Native routine completion currently logs regardless of elapsed time; web
  requires ≥60s. Add the gate + tests (GaugeSessionTracker / PhaseManager).

### P3 (#632) — sign-out drains offline queue (web #264/#273 parity)
- Sign-out must drain the offline queue and report lost recordings. No silent
  data loss path.

### P4 (#631) — tindeq_tags registry, Apple Sign-In, theme, Send Conditions
- Native lacks: tindeq_tags registry (rename/hide), Apple Sign-In, theme,
  Send Conditions (web parity). Implement each; Apple Sign-In is the
  multi-step one — verify against the existing web auth flows.

### P5 (#630) — History: combined timeline, multi-select → create session, charts
- History lacks the combined timeline, multi-select → create session, and
  session/recording charts. Implement against web parity.

## Gauntlet rules (from the plush gauntlet template, same discipline)

- Fan out MIN 3, MAX 6 subagents per batch, one per coherent module, parallel
  when decomposition allows. Every batch: implementer(s) + at least one
  adversarial reviewer (separate opencode agent, fresh context, harsh brief).
- Orchestrator = single integrator: collect, review, run all gates, merge
  once. Merge is the orchestrator's default (no per-task approval).
- ISSUE HYGIENE: create/attach the issue per piece FIRST, comment progress +
  evidence, `Refs #N`/`Closes #N` correctly, close only with evidence.
- Keep the progress visible (herdr-status board / digest).
- All agents DeepSeek/opencode. NO claude, NO codex, NO gemini.

## Non-negotiable

- Keep the Capacitor/web implementation separately maintained. The native
  Release bundle now uses the existing shipped Sendmeter app record, but native
  implementation promotion remains gated on the physical device soak (per
  docs/native-swift-rewrite.md).
- Every parity fix must have tests (the native target has a solid
  SendmeterCoreTests suite — extend it).
- Run the repo's standard gates: `npm run typecheck && npm run lint && npm
  test && npm run build` for web-adjacent changes; `swift test` in
  native/SendmeterNative for native changes; CI must be green.
- Don't touch unrelated code; worktree isolation per piece.

## Acceptance criteria (verdict gate for the batch)

1. #637: the dispatch-only TestFlight build remains available, and #768's
   Release build embeds the watch companion; Guy can install it on physical
   devices once signing/profile gates pass.
2. #633/#632/#631/#630: each closed with evidence + tests, web parity verified.
3. cargo-equivalent quality bar: no new warnings, tests green, CI green.
4. Web app source remains untouched by the native target; native stays under
   the separate physical-device promotion gates.
