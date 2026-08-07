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

/// #486: whether tapping Disconnect must be gated behind a confirmation
/// instead of firing immediately. Tare and "How to set up" are already
/// hidden outright while `measuring || armed || counting` — Disconnect used
/// to be the one control in that top bar left live through all three, so one
/// mistimed tap mid-max-effort-rep silently discarded the recording (no
/// salvage: `disconnect()` in useTindeq.ts is the deliberate user path, not
/// the unexpected-drop path that triggers interruption salvage). Same three
/// booleans as the Tare/setup-guide gate, kept as an explicit predicate
/// (rather than inlined at the call site) so the rule is independently
/// testable without rendering ForceFullscreen — see this file's header
/// comment for why that component can't be rendered in a test here.
export function disconnectNeedsConfirm(params: {
  measuring: boolean;
  armed: boolean;
  counting: boolean;
}): boolean {
  return params.measuring || params.armed || params.counting;
}
