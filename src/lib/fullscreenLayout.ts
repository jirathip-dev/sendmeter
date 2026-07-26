/// Vertical-fit rules for the immersive fullscreen overlays (#221).
///
/// The overlays — Force recorder, phone workout timer, guided routine — must
/// fit ONE screen on the smallest supported iPhone (SE, 375×667). Scrolling to
/// reach START/STOP mid-set is the bug, not the fix, so nothing large is sized
/// in fixed pixels any more: the chrome shrinks with the viewport (`clamp()`),
/// and the live force chart flexes to absorb whatever is left.
///
/// Pure, so the sizing maths is unit-tested (`fullscreenLayout.test.ts`) —
/// the components only consume the CSS strings these builders return.

/// Apple HIG minimum tappable edge. No responsive floor may go under it.
export const MIN_TAP_PX = 44;

/// A `clamp(min, preferred, max)` box dimension driven by viewport height.
export interface ClampSpec {
  /// Floor — the size on the shortest viewport we support.
  minPx: number;
  /// Preferred size as a % of the *small* viewport height (`svh`). Small, not
  /// dynamic: a browser's collapsible toolbar can then never hide the action.
  preferredSvh: number;
  /// Ceiling — the original design size, so big screens are unchanged.
  maxPx: number;
}

export function clampCss(s: ClampSpec): string {
  return `clamp(${s.minPx}px, ${s.preferredSvh}svh, ${s.maxPx}px)`;
}

/// What `clampCss(s)` resolves to on a viewport `svhPx` tall — the same maths
/// the browser does (CSS defines clamp as `max(min, min(val, max))`, so a
/// min above the max wins), letting tests pin real device sizes.
export function resolveClamp(s: ClampSpec, svhPx: number): number {
  const preferred = (s.preferredSvh / 100) * svhPx;
  return Math.max(s.minPx, Math.min(preferred, s.maxPx));
}

/// A hero number (countdown / stopwatch). Width drives it — the digits must
/// not run off the sides — but height caps it, so a short viewport (landscape,
/// a small phone with large text) shrinks it instead of pushing the action
/// button off-screen.
export interface HeroFontSpec {
  minPx: number;
  vw: number;
  svh: number;
  maxPx: number;
}

export function heroFontCss(s: HeroFontSpec): string {
  return `clamp(${s.minPx}px, min(${s.vw}vw, ${s.svh}svh), ${s.maxPx}px)`;
}

export function resolveHeroFont(s: HeroFontSpec, vwPx: number, svhPx: number): number {
  const preferred = Math.min((s.vw / 100) * vwPx, (s.svh / 100) * svhPx);
  return Math.max(s.minPx, Math.min(preferred, s.maxPx));
}

// ── The specs themselves ────────────────────────────────────────────────────

/// BOULDER / DONE circle, phone workout overlay (design size 132).
export const WORKOUT_ACTION_CIRCLE: ClampSpec = {
  minPx: 92,
  preferredSvh: 17,
  maxPx: 132,
};

/// START / STOP circle, Force overlay (design size 118).
export const FORCE_ACTION_CIRCLE: ClampSpec = {
  minPx: 88,
  preferredSvh: 15,
  maxPx: 118,
};

/// Vertical padding inside the Force overlay's tinted phase banner (design 18).
export const BANNER_PAD_Y: ClampSpec = {
  minPx: 9,
  preferredSvh: 2,
  maxPx: 18,
};

/// Gap between the Force overlay's stacked sections (design 10).
export const SECTION_GAP: ClampSpec = {
  minPx: 6,
  preferredSvh: 1.2,
  maxPx: 10,
};

/// The wrapped exercise-tag strip. A user with many tags wraps to many rows,
/// which is what pushed START off the bottom; cap it at roughly two rows and
/// let the strip itself scroll rather than the whole overlay.
export const TAG_STRIP_MAX: ClampSpec = {
  minPx: 54,
  preferredSvh: 10,
  maxPx: 88,
};

/// Floor for the live force trace. The chart is the flexible element — it
/// absorbs the leftover height — but below this it is unreadable, so the
/// overlay's own scroll takes over instead of shrinking it further.
export const CHART_MIN_PX = 88;

/// Phone workout countdown (design `clamp(64px, 22vw, 140px)`).
export const WORKOUT_TIMER_FONT: HeroFontSpec = {
  minPx: 44,
  vw: 22,
  svh: 15,
  maxPx: 140,
};

/// Force overlay segment countdown (design `clamp(64px, 20vw, 112px)`).
export const FORCE_TIMER_FONT: HeroFontSpec = {
  minPx: 40,
  vw: 20,
  svh: 13,
  maxPx: 112,
};

/// Force overlay's smaller hero numbers — the free-hold stopwatch and the
/// DONE tick (design `clamp(56px, 18vw, 96px)`).
export const FORCE_HERO_SM_FONT: HeroFontSpec = {
  minPx: 34,
  vw: 18,
  svh: 11,
  maxPx: 96,
};

/// Routine overlay segment countdown (design `clamp(56px, 20vw, 120px)`).
export const ROUTINE_TIMER_FONT: HeroFontSpec = {
  minPx: 40,
  vw: 20,
  svh: 14,
  maxPx: 120,
};
