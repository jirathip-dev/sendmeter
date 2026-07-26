/// Pure decision layer for the app-wide tap haptics (#171). Everything that
/// decides WHETHER a tick fires — and which one — lives here, free of the DOM
/// and of Capacitor, so it is unit-testable; `haptics.ts` owns the document
/// listeners and the one native call.
///
/// The shape follows #172 (the intensity slider): a tick is guarded so a
/// gesture can only produce one, rather than one per pixel / per handler that
/// happens to be listening.

export type HapticKind = "light" | "medium" | "blocked";

/// Elements whose tap counts as an interactive action. Deliberately broad and
/// structural rather than a list of ~140 call sites: every `<button>` in the
/// app (nav items, steppers, chips, glass pills, the account FAB, sheet
/// buttons) is an action, and a new one gets feedback for free. Non-button
/// tappables opt in with `data-haptic`.
export const TAP_SELECTOR = [
  "button",
  '[role="button"]',
  "a[href]",
  'input[type="checkbox"]',
  'input[type="radio"]',
  // Toggle labels: the finger usually lands on the text, not the box. Scoped
  // with `:has` so a label wrapping a text/number field stays silent —
  // focusing a field and opening the keyboard is not a tap action.
  'label:has(input[type="checkbox"])',
  'label:has(input[type="radio"])',
  // Tappable cards (ReadinessCard, LiveWorkoutCard) already carry this class.
  ".card.tappable",
  "[data-haptic]",
].join(", ");

/// Ancestors that VETO a tick, nearest-match-wins against `TAP_SELECTOR`:
/// - `.chart-scrub` — `useChartHover` already ticks per data point (SL-68);
///   several of those hit areas sit *inside* a tappable card, so without this
///   a scrub on e.g. ReadinessCard's sparkline would fire twice.
/// - `[data-haptic="off"]` — a control that owns its own feedback (the #172
///   intensity slider) or a surface where a tap does nothing (a sheet's own
///   backdrop layer, which would otherwise inherit an ancestor card's tick).
export const MUTE_SELECTOR = '.chart-scrub, [data-haptic="off"]';

/// How far the pointer may travel between down and up and still count as a
/// tap. Beyond it the gesture is a scroll/drag/swipe and must stay silent —
/// `pointerdown` alone cannot tell the two apart, which is why the tick is
/// resolved on `pointerup` instead.
export const TAP_SLOP_PX = 10;

/// How recently a pointer gesture must have started for a mount-time tick
/// (a sheet opening) to count as "the user did this". Beyond it the sheet
/// appeared on its own — an auto-prompt, a restored session — and buzzing
/// would be a haptic with no action behind it.
export const GESTURE_FRESH_MS = 1500;

/// The attributes that decide a tap's fate, read off the nearest matching
/// element. Plain data so the rules below need no DOM.
export interface TapCandidate {
  /// The nearest match was a mute boundary (see `MUTE_SELECTOR`).
  muted?: boolean;
  /// `data-haptic` — "medium" for confirm/destructive, "off" to suppress.
  haptic?: string | null;
  ariaDisabled?: string | null;
  /// The native `disabled` attribute.
  disabled?: boolean;
}

/// The blocked-vs-accepted decision (#222). Start controls that are refused
/// are `aria-disabled` yet deliberately still clickable, so the tap can toast
/// the reason — they MUST NOT feel like the accepted tap next to them, or the
/// tick teaches the hand to trust a signal that lies. A refusal gets the
/// system warning pattern; a genuinely inert `disabled` control, which eats
/// the click entirely, gets nothing at all.
export function hapticForCandidate(
  c: TapCandidate | null | undefined,
): HapticKind | null {
  if (!c || c.muted) return null;
  if (c.haptic === "off") return null;
  if (c.disabled) return null;
  if (c.ariaDisabled === "true") return "blocked";
  if (c.haptic === "medium") return "medium";
  return "light";
}

/// The minimum of `Element` this module needs, so `candidateFor` can be
/// exercised without a DOM (the suite runs in node — there is no jsdom here).
/// A real `Element` satisfies it structurally.
export interface TapElementLike {
  closest(selectors: string): TapElementLike | null;
  matches(selectors: string): boolean;
  getAttribute(name: string): string | null;
  hasAttribute(name: string): boolean;
}

/// Resolve the element under a pointer to the tap it represents. `closest`
/// returns the NEAREST ancestor matching either list, which is what keeps a
/// button inside a tappable card (or inside a chart) from resolving to the
/// container: the innermost thing wins, and it wins exactly once.
export function candidateFor(
  target: TapElementLike | null | undefined,
): TapCandidate | null {
  if (!target) return null;
  try {
    const el = target.closest(`${TAP_SELECTOR}, ${MUTE_SELECTOR}`);
    if (!el) return null;
    if (el.matches(MUTE_SELECTOR)) return { muted: true };
    return {
      haptic: el.getAttribute("data-haptic"),
      ariaDisabled: el.getAttribute("aria-disabled"),
      disabled: el.hasAttribute("disabled"),
    };
  } catch {
    // An engine that can't parse the selector list would otherwise throw on
    // every pointerdown in the app. Feedback is never worth that.
    return null;
  }
}

export interface PointerSample {
  pointerId: number;
  x: number;
  y: number;
}

/// One tick per pointer gesture, resolved at lift-off.
///
/// A gesture starts at `down` and stays current until the next `down`, so a
/// `click` handler firing after `up` is still inside it. That is the whole
/// anti-double-fire mechanism: the delegated listener and any explicit
/// `tapHaptic()` on the same tap both go through here, and only the first one
/// through gets the tick. It also absorbs React StrictMode's double-invoked
/// mount effects.
export interface GestureTracker {
  /// `kind` is what the element under the pointer would fire; null = nothing
  /// interactive there. Arms the gesture either way.
  down(p: PointerSample, kind: HapticKind | null, nowMs: number): void;
  /// Disarms once the pointer has travelled past the tap slop — a scroll or
  /// drag that merely *started* on a button must not buzz.
  move(p: PointerSample): void;
  /// The kind to fire, or null if this gesture has nothing left to give.
  up(pointerId: number): HapticKind | null;
  /// The browser took the gesture over (scrolling). Disarm.
  cancel(pointerId: number): void;
  /// Claim this gesture's tick for an explicit caller (a handler that isn't a
  /// tap on an element — sheet mount, backdrop dismiss, drag-to-close).
  claim(nowMs: number, opts?: { requireGestureWithinMs?: number }): boolean;
}

export function createGestureTracker(slopPx = TAP_SLOP_PX): GestureTracker {
  let pending: (PointerSample & { kind: HapticKind }) | null = null;
  let fired = false;
  let lastDownAt = Number.NEGATIVE_INFINITY;

  return {
    down(p, kind, nowMs) {
      pending = kind ? { ...p, kind } : null;
      fired = false;
      lastDownAt = nowMs;
    },
    move(p) {
      if (!pending || pending.pointerId !== p.pointerId) return;
      if (Math.hypot(p.x - pending.x, p.y - pending.y) > slopPx) pending = null;
    },
    up(pointerId) {
      if (!pending || pending.pointerId !== pointerId) return null;
      const { kind } = pending;
      pending = null;
      if (fired) return null;
      fired = true;
      return kind;
    },
    cancel(pointerId) {
      if (pending && pending.pointerId === pointerId) pending = null;
    },
    claim(nowMs, opts) {
      if (fired) return false;
      const within = opts?.requireGestureWithinMs;
      if (within != null && nowMs - lastDownAt > within) return false;
      fired = true;
      return true;
    },
  };
}
