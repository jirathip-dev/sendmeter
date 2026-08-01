import type { TindeqPreset } from "../types";

/// #312 — "Force 5s get-ready countdown does nothing (free hold only)".
///
/// A free hold (protocol === null) has no timeline, so `buildTimeline`'s
/// prepare segment (protocol.ts) never gets built for it — the checkbox in
/// ForceFullscreen had nothing to drive. This is the free-hold equivalent: a
/// small local countdown owned entirely by ForceFullscreen's component state
/// (deliberately NOT folded into protocol.ts — a free hold has no timeline to
/// join). Kept as two pure, dependency-free functions in their own module
/// (not inside ForceFullscreen.tsx) for two reasons: they're directly
/// testable without a DOM (this repo has no jsdom/testing-library configured,
/// and the component's unconditional `createPortal(..., document.body)` means
/// it can't be rendered in a test here at all — see ForceFullscreen.test's
/// header comment), and `eslint-plugin-react-refresh`'s
/// `only-export-components` rule forbids a component file from exporting
/// anything else.

/// Seconds the free-hold countdown runs before the hold starts — matches the
/// `prepareS: 5` a guided run bakes into its timeline (ForceView.tsx).
export const PREPARE_S = 5;

/// Whether tapping Start should begin this local countdown, vs. starting
/// immediately. A guided run (protocol !== null) already has its own prepare
/// segment baked into the timeline and walks it via the timeline position
/// instead — it must never ALSO run this local countdown, regardless of the
/// checkbox.
export function startsWithCountdown(
  protocol: TindeqPreset | null,
  prepare: boolean,
): boolean {
  return protocol === null && prepare;
}

/// Seconds left in a countdown started at `startedMs`, as of `nowMs`; null
/// when no countdown is running (never started, or cancelled). Clamped to
/// >=0 — the caller fires onStart once this reaches 0.
export function prepRemainingS(
  startedMs: number | null,
  nowMs: number,
  totalS: number = PREPARE_S,
): number | null {
  if (startedMs === null) return null;
  return Math.max(0, totalS - (nowMs - startedMs) / 1000);
}
