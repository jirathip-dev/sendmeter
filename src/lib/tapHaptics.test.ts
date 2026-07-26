import { describe, expect, it } from "vitest";
import {
  candidateFor,
  createGestureTracker,
  hapticForCandidate,
  MUTE_SELECTOR,
  TAP_SLOP_PX,
  type TapElementLike,
} from "./tapHaptics";

/// A stand-in for a DOM element: the suite runs in node (no jsdom), and the
/// interesting rules are "what does the resolver do with what `closest` found"
/// — not CSS matching itself, which is the browser's job. `closest` is
/// scripted per case; whether the match is a mute boundary is explicit.
function fakeEl(
  attrs: Record<string, string> = {},
  opts: { mute?: boolean } = {},
): TapElementLike {
  const el: TapElementLike = {
    closest: () => el,
    matches: (sel) => sel === MUTE_SELECTOR && opts.mute === true,
    getAttribute: (n) => attrs[n] ?? null,
    hasAttribute: (n) => n in attrs,
  };
  return el;
}

const nothingUnder = (): TapElementLike => ({
  closest: () => null,
  matches: () => false,
  getAttribute: () => null,
  hasAttribute: () => false,
});

describe("hapticForCandidate — what a tap is worth", () => {
  it("gives an ordinary interactive element the light tick", () => {
    expect(hapticForCandidate({})).toBe("light");
  });

  it("gives a confirm/destructive action the medium tick", () => {
    expect(hapticForCandidate({ haptic: "medium" })).toBe("medium");
  });

  // The #222 rule, and the whole reason this is a function rather than a
  // boolean: a Start control that is refused (aria-disabled but deliberately
  // still clickable, so the tap can toast why) must NOT feel like the accepted
  // tap next to it.
  it("gives a REFUSED but clickable control its own pattern, not the light tick", () => {
    const blocked = hapticForCandidate({ ariaDisabled: "true" });
    expect(blocked).toBe("blocked");
    expect(blocked).not.toBe(hapticForCandidate({}));
  });

  it("stays silent for a genuinely inert control — the click never happens", () => {
    expect(hapticForCandidate({ disabled: true })).toBeNull();
    // A busy ConfirmDialog: `data-haptic="medium"` is still on the button, but
    // `disabled` wins — no medium tick for a tap that does nothing.
    expect(hapticForCandidate({ haptic: "medium", disabled: true })).toBeNull();
  });

  it("stays silent for an opted-out control and for a mute boundary", () => {
    expect(hapticForCandidate({ haptic: "off" })).toBeNull();
    expect(hapticForCandidate({ muted: true })).toBeNull();
    expect(hapticForCandidate(null)).toBeNull();
  });

  it("treats aria-disabled=false as a normal, accepted tap", () => {
    expect(hapticForCandidate({ ariaDisabled: "false" })).toBe("light");
  });
});

describe("candidateFor", () => {
  it("reads the deciding attributes off the nearest match", () => {
    expect(candidateFor(fakeEl({ "data-haptic": "medium" }))).toEqual({
      haptic: "medium",
      ariaDisabled: null,
      disabled: false,
    });
    expect(candidateFor(fakeEl({ disabled: "" }))?.disabled).toBe(true);
  });

  // The nearest-match rule is what keeps a chart-scrub area inside a tappable
  // card (ReadinessCard's sparkline) from firing the card's tick on top of the
  // per-point one useChartHover already fires.
  it("returns a muted candidate when the nearest match is a mute boundary", () => {
    expect(candidateFor(fakeEl({}, { mute: true }))).toEqual({ muted: true });
    expect(hapticForCandidate(candidateFor(fakeEl({}, { mute: true })))).toBeNull();
  });

  it("returns null for a tap on nothing interactive", () => {
    expect(candidateFor(nothingUnder())).toBeNull();
    expect(candidateFor(null)).toBeNull();
  });

  it("never throws out into the pointer path if the selector can't be parsed", () => {
    const hostile: TapElementLike = {
      closest: () => {
        throw new SyntaxError("unsupported selector");
      },
      matches: () => false,
      getAttribute: () => null,
      hasAttribute: () => false,
    };
    expect(candidateFor(hostile)).toBeNull();
  });
});

const P = { pointerId: 1, x: 100, y: 100 };

describe("createGestureTracker — one tick per gesture, resolved at lift-off", () => {
  it("ticks a tap on lift, once", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    expect(t.up(P.pointerId)).toBe("light");
    // A second up (or a stray one) has nothing left to give.
    expect(t.up(P.pointerId)).toBeNull();
  });

  it("carries the element's kind through, so a confirm stays medium", () => {
    const t = createGestureTracker();
    t.down(P, "medium", 0);
    expect(t.up(P.pointerId)).toBe("medium");
  });

  // Risk 4: pointerdown fires at the start of scrolls and drags too. A scroll
  // that merely BEGINS on a button must stay silent.
  it("stays silent when the pointer travels past the tap slop", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    t.move({ ...P, y: P.y + TAP_SLOP_PX + 1 });
    expect(t.up(P.pointerId)).toBeNull();
  });

  it("still ticks a slightly sloppy tap", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    t.move({ ...P, y: P.y + TAP_SLOP_PX - 1 });
    expect(t.up(P.pointerId)).toBe("light");
  });

  it("stays silent when the browser claims the gesture (scroll → pointercancel)", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    t.cancel(P.pointerId);
    expect(t.up(P.pointerId)).toBeNull();
  });

  it("ignores a second finger's movement and lift", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    t.move({ pointerId: 2, x: 400, y: 400 });
    expect(t.up(2)).toBeNull();
    expect(t.up(P.pointerId)).toBe("light");
  });

  it("stays silent for a tap on nothing interactive", () => {
    const t = createGestureTracker();
    t.down(P, null, 0);
    expect(t.up(P.pointerId)).toBeNull();
  });

  // Risk 2: a button nested in a tappable card, or a component that also ticks
  // explicitly, must not fire twice. Both paths go through the same gesture.
  it("swallows an explicit claim once the delegated tick has fired", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    expect(t.up(P.pointerId)).toBe("light");
    // e.g. the opened sheet's mount effect, same tap.
    expect(t.claim(10)).toBe(false);
  });

  it("swallows the delegated tick once an explicit claim has taken it", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    expect(t.claim(5)).toBe(true);
    expect(t.up(P.pointerId)).toBeNull();
  });

  it("swallows a repeated explicit claim in the same gesture (StrictMode remount)", () => {
    const t = createGestureTracker();
    t.down(P, null, 0);
    expect(t.claim(1)).toBe(true);
    expect(t.claim(1)).toBe(false);
  });

  it("hands the next gesture its own tick", () => {
    const t = createGestureTracker();
    t.down(P, "light", 0);
    expect(t.up(P.pointerId)).toBe("light");
    t.down(P, "light", 500);
    expect(t.up(P.pointerId)).toBe("light");
  });

  // A drag-to-close release: nothing interactive under the finger at
  // pointerdown, so the gesture is still unspent when the handler claims it.
  it("lets a gesture that started on nothing be claimed on release", () => {
    const t = createGestureTracker();
    t.down(P, null, 0);
    expect(t.up(P.pointerId)).toBeNull();
    expect(t.claim(20)).toBe(true);
  });

  describe("freshness window (a sheet mounting)", () => {
    it("ticks when a gesture just happened", () => {
      const t = createGestureTracker();
      t.down(P, null, 1_000);
      expect(t.claim(1_100, { requireGestureWithinMs: 1_500 })).toBe(true);
    });

    it("stays silent for a sheet that appears with no tap behind it", () => {
      const t = createGestureTracker();
      // No gesture at all — an auto-prompt on launch.
      expect(t.claim(1_000, { requireGestureWithinMs: 1_500 })).toBe(false);
    });

    it("stays silent when the last gesture is stale", () => {
      const t = createGestureTracker();
      t.down(P, null, 1_000);
      expect(t.claim(9_000, { requireGestureWithinMs: 1_500 })).toBe(false);
    });
  });
});
