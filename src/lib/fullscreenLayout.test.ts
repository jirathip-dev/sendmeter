import { describe, expect, it } from "vitest";
import {
  BANNER_PAD_Y,
  CHART_MIN_PX,
  FORCE_ACTION_CIRCLE,
  FORCE_HERO_SM_FONT,
  FORCE_TIMER_FONT,
  MIN_TAP_PX,
  ROUTINE_TIMER_FONT,
  SECTION_GAP,
  TAG_STRIP_MAX,
  WORKOUT_ACTION_CIRCLE,
  WORKOUT_TIMER_FONT,
  clampCss,
  heroFontCss,
  resolveClamp,
  resolveHeroFont,
  type ClampSpec,
  type HeroFontSpec,
} from "./fullscreenLayout";

// The devices the overlays are sized against. Notched phones lose the extra
// safe-area padding on top of the 16px floor the overlays already pad with,
// so their usable height is quoted below, not the raw screen height.
const SE = 667; // iPhone SE — smallest supported, no insets
const MINI = 760; // iPhone 12/13 mini (812 − 50 top − 34 bottom + 2×16 floor)
const BIG = 926; // iPhone 14 Pro Max

const ALL_CLAMPS: [string, ClampSpec][] = [
  ["workout circle", WORKOUT_ACTION_CIRCLE],
  ["force circle", FORCE_ACTION_CIRCLE],
  ["banner padding", BANNER_PAD_Y],
  ["section gap", SECTION_GAP],
  ["tag strip", TAG_STRIP_MAX],
];

const ALL_FONTS: [string, HeroFontSpec][] = [
  ["workout timer", WORKOUT_TIMER_FONT],
  ["force timer", FORCE_TIMER_FONT],
  ["force hero sm", FORCE_HERO_SM_FONT],
  ["routine timer", ROUTINE_TIMER_FONT],
];

describe("clampCss / resolveClamp", () => {
  it("emits the CSS the components consume", () => {
    expect(clampCss({ minPx: 92, preferredSvh: 17, maxPx: 132 })).toBe(
      "clamp(92px, 17svh, 132px)",
    );
  });

  it("resolves the preferred size between the bounds", () => {
    const spec = { minPx: 92, preferredSvh: 17, maxPx: 132 };
    expect(resolveClamp(spec, 700)).toBeCloseTo(119, 5); // 17% of 700
  });

  it("clamps to the floor on a short viewport and the ceiling on a tall one", () => {
    const spec = { minPx: 92, preferredSvh: 17, maxPx: 132 };
    expect(resolveClamp(spec, 400)).toBe(92);
    expect(resolveClamp(spec, 1200)).toBe(132);
  });

  it("follows CSS semantics when the floor exceeds the ceiling", () => {
    // CSS clamp() is max(min, min(val, max)) — the minimum wins.
    expect(resolveClamp({ minPx: 120, preferredSvh: 50, maxPx: 80 }, 100)).toBe(120);
  });
});

describe("heroFontCss / resolveHeroFont", () => {
  it("emits a width-and-height bounded clamp", () => {
    expect(heroFontCss({ minPx: 44, vw: 22, svh: 15, maxPx: 140 })).toBe(
      "clamp(44px, min(22vw, 15svh), 140px)",
    );
  });

  it("takes whichever of width or height is the tighter constraint", () => {
    const spec = { minPx: 44, vw: 22, svh: 15, maxPx: 140 };
    // Portrait phone: width binds (22% of 375 = 82.5 < 15% of 667 = 100).
    expect(resolveHeroFont(spec, 375, 667)).toBeCloseTo(82.5, 5);
    // Same phone in landscape: height binds and the number shrinks, instead of
    // shoving the action button off the bottom.
    expect(resolveHeroFont(spec, 667, 375)).toBeCloseTo(56.25, 5);
  });

  it("never drops below the legibility floor", () => {
    expect(resolveHeroFont({ minPx: 44, vw: 22, svh: 15, maxPx: 140 }, 200, 200)).toBe(44);
  });
});

describe("overlay sizing on the smallest supported iPhone", () => {
  it("keeps both action circles a comfortable tap target at 375x667", () => {
    // The whole point of #221: the circle shrinks rather than leaving the
    // screen, but never below something you can hit with a chalked finger.
    expect(resolveClamp(WORKOUT_ACTION_CIRCLE, SE)).toBeCloseTo(113.39, 2);
    expect(resolveClamp(FORCE_ACTION_CIRCLE, SE)).toBeCloseTo(100.05, 2);
    for (const [name, spec] of ALL_CLAMPS) {
      if (!name.includes("circle")) continue;
      expect(resolveClamp(spec, SE), name).toBeGreaterThanOrEqual(MIN_TAP_PX * 2);
    }
  });

  it("reclaims height from the Force overlay's chrome", () => {
    // Banner padding, section gaps and the tag strip are what a 667px screen
    // cannot afford at full size; each gives up roughly a third.
    expect(resolveClamp(BANNER_PAD_Y, SE)).toBeCloseTo(13.34, 2);
    expect(resolveClamp(SECTION_GAP, SE)).toBeCloseTo(8.004, 3);
    expect(resolveClamp(TAG_STRIP_MAX, SE)).toBeCloseTo(66.7, 1);
  });

  it("leaves the chart its readable floor after the fixed chrome", () => {
    // The chart is the flexible element. Everything that is NOT the chart in
    // the Force overlay's own styling must still leave CHART_MIN_PX behind.
    const chrome =
      resolveClamp(FORCE_ACTION_CIRCLE, SE) +
      2 * resolveClamp(BANNER_PAD_Y, SE) +
      3 * resolveClamp(SECTION_GAP, SE) +
      resolveClamp(TAG_STRIP_MAX, SE);
    expect(SE - chrome).toBeGreaterThan(CHART_MIN_PX);
  });
});

describe("large screens keep the original design", () => {
  it("pins every clamp to its design ceiling on a big phone", () => {
    for (const [name, spec] of ALL_CLAMPS) {
      expect(resolveClamp(spec, BIG), name).toBe(spec.maxPx);
    }
    // A mini gives up only a couple of points — the shrink is concentrated on
    // the screens that actually run out of room.
    expect(resolveClamp(WORKOUT_ACTION_CIRCLE, MINI)).toBeCloseTo(129.2, 2);
    expect(resolveClamp(FORCE_ACTION_CIRCLE, MINI)).toBeCloseTo(114, 2);
  });

  it("leaves the portrait hero numbers where they were", () => {
    // Height only ever binds on a viewport shorter than the phones we ship to,
    // so 375-wide portrait keeps its existing width-driven size.
    expect(resolveHeroFont(WORKOUT_TIMER_FONT, 375, SE)).toBeCloseTo(82.5, 5);
    expect(resolveHeroFont(FORCE_TIMER_FONT, 375, SE)).toBeCloseTo(75, 5);
    expect(resolveHeroFont(ROUTINE_TIMER_FONT, 375, SE)).toBeCloseTo(75, 5);
    expect(resolveHeroFont(FORCE_HERO_SM_FONT, 375, SE)).toBeCloseTo(67.5, 5);
  });
});

describe("spec sanity", () => {
  it("orders every bound floor < ceiling", () => {
    for (const [name, spec] of ALL_CLAMPS) {
      expect(spec.minPx, name).toBeLessThan(spec.maxPx);
      expect(spec.preferredSvh, name).toBeGreaterThan(0);
    }
    for (const [name, spec] of ALL_FONTS) {
      expect(spec.minPx, name).toBeLessThan(spec.maxPx);
    }
  });
});
