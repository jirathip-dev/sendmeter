import { beforeEach, describe, expect, it, vi } from "vitest";
import { MUTE_SELECTOR, TAP_SLOP_PX, type TapElementLike } from "./tapHaptics";

/// What the native layer was asked to do. The plugin itself is mocked — the
/// only thing a headless run can prove is WHICH call was made (or that none
/// was), never how it feels.
const h = vi.hoisted(() => ({
  native: false,
  reject: false,
  throwSync: false,
  calls: [] as string[],
}));

vi.mock("@capacitor/core", () => ({
  Capacitor: { isNativePlatform: () => h.native },
}));

vi.mock("@capacitor/haptics", () => {
  const record = (what: string) => {
    if (h.throwSync) throw new Error("plugin exploded");
    h.calls.push(what);
    return h.reject ? Promise.reject(new Error("no engine")) : Promise.resolve();
  };
  return {
    Haptics: {
      impact: (o: { style: string }) => record(`impact:${o.style}`),
      notification: (o: { type: string }) => record(`notification:${o.type}`),
    },
    ImpactStyle: { Heavy: "HEAVY", Medium: "MEDIUM", Light: "LIGHT" },
    NotificationType: { Success: "SUCCESS", Warning: "WARNING", Error: "ERROR" },
  };
});

/// A fresh copy of the module — its gesture tracker is module state, so each
/// scenario needs its own.
async function loadHaptics(opts: { native?: boolean } = {}) {
  h.native = opts.native ?? true;
  h.reject = false;
  h.throwSync = false;
  h.calls = [];
  vi.resetModules();
  return await import("./haptics");
}

// --- A stand-in DOM ---------------------------------------------------------
// There is no jsdom in this suite, and CSS matching is the browser's job
// anyway. These fakes cover the wiring that IS ours: which pointer events
// resolve to a tick, and which are swallowed.

type Kind = "tap" | "mute" | "none";

function el(kind: Kind, attrs: Record<string, string> = {}): TapElementLike {
  const self: TapElementLike = {
    closest: () => (kind === "none" ? null : self),
    matches: (sel) => sel === MUTE_SELECTOR && kind === "mute",
    getAttribute: (n) => attrs[n] ?? null,
    hasAttribute: (n) => n in attrs,
  };
  return self;
}

interface FakeEvent {
  pointerId: number;
  clientX: number;
  clientY: number;
  target: unknown;
}

function fakeDocument() {
  const listeners = new Map<string, ((e: FakeEvent) => void)[]>();
  const doc = {
    addEventListener(type: string, fn: (e: FakeEvent) => void) {
      listeners.set(type, [...(listeners.get(type) ?? []), fn]);
    },
    removeEventListener(type: string, fn: (e: FakeEvent) => void) {
      listeners.set(type, (listeners.get(type) ?? []).filter((f) => f !== fn));
    },
  };
  const dispatch = (type: string, e: Partial<FakeEvent> = {}) => {
    for (const fn of listeners.get(type) ?? [])
      fn({ pointerId: 1, clientX: 100, clientY: 100, target: null, ...e });
  };
  const count = () => [...listeners.values()].reduce((n, l) => n + l.length, 0);
  return { doc: doc as unknown as Document, dispatch, count };
}

/// down → up on the same spot, with `target` under the finger.
function tap(
  dispatch: (t: string, e?: Partial<FakeEvent>) => void,
  target: TapElementLike,
) {
  dispatch("pointerdown", { target });
  dispatch("pointerup", { target });
}

beforeEach(() => {
  vi.resetModules();
});

describe("the native call", () => {
  it("does nothing at all on web", async () => {
    const { selectionHaptic, tapHaptic, confirmHaptic, sheetHaptic } =
      await loadHaptics({ native: false });
    selectionHaptic();
    tapHaptic();
    confirmHaptic();
    sheetHaptic();
    expect(h.calls).toEqual([]);
  });

  it("uses Light for a tap and selection, Medium for a confirm", async () => {
    const { selectionHaptic } = await loadHaptics();
    selectionHaptic();
    expect(h.calls).toEqual(["impact:LIGHT"]);

    const tapOnly = await loadHaptics();
    tapOnly.tapHaptic();
    expect(h.calls).toEqual(["impact:LIGHT"]);

    const confirmOnly = await loadHaptics();
    confirmOnly.confirmHaptic();
    expect(h.calls).toEqual(["impact:MEDIUM"]);
  });

  it("never lets a haptic failure reach the action it accompanies", async () => {
    const { selectionHaptic } = await loadHaptics();
    h.reject = true;
    expect(() => selectionHaptic()).not.toThrow();
    expect(h.calls).toEqual(["impact:LIGHT"]); // asked for, then rejected
    h.reject = false;
    h.throwSync = true;
    h.calls = [];
    expect(() => selectionHaptic()).not.toThrow();
    expect(h.calls).toEqual([]);
  });

  it("leaves the chart-scrub tick unguarded — it ticks per data point", async () => {
    const { selectionHaptic } = await loadHaptics();
    selectionHaptic();
    selectionHaptic();
    selectionHaptic();
    expect(h.calls).toHaveLength(3);
  });
});

describe("the delegated listener", () => {
  it("installs once and uninstalls cleanly", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, count } = fakeDocument();
    const off = installTapHaptics(doc);
    const n = count();
    expect(n).toBeGreaterThan(0);
    // A second install must not double every listener (and so every tick).
    expect(installTapHaptics(doc)).toBe(off);
    expect(count()).toBe(n);
    off();
    expect(count()).toBe(0);
  });

  it("ticks a tap on an interactive element, exactly once", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("tap"));
    expect(h.calls).toEqual(["impact:LIGHT"]);
  });

  it("gives a data-haptic=medium control the heavier tick", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("tap", { "data-haptic": "medium" }));
    expect(h.calls).toEqual(["impact:MEDIUM"]);
  });

  // Risk 1: a refused-but-clickable Start control (#222).
  it("gives a blocked tap a pattern of its own, never the accepted one", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("tap", { "aria-disabled": "true" }));
    expect(h.calls).toEqual(["notification:WARNING"]);
  });

  it("says nothing for a tap on plain, non-interactive content", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("none"));
    dispatch("pointerdown", { target: "not an element" });
    dispatch("pointerup", { target: "not an element" });
    expect(h.calls).toEqual([]);
  });

  // Risk 3: useChartHover owns the scrub tick; the card under it must not add
  // a second one.
  it("says nothing inside a mute boundary (chart scrub, opted-out control)", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("mute"));
    expect(h.calls).toEqual([]);
  });

  // Risk 4: pointerdown also starts every scroll and drag.
  it("says nothing when a scroll starts on a button", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    const target = el("tap");
    dispatch("pointerdown", { target });
    dispatch("pointermove", { clientY: 100 + TAP_SLOP_PX + 40, target });
    dispatch("pointerup", { clientY: 100 + TAP_SLOP_PX + 40, target });
    expect(h.calls).toEqual([]);
  });

  it("says nothing when the browser takes the gesture over", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    const target = el("tap");
    dispatch("pointerdown", { target });
    dispatch("pointercancel", { target });
    dispatch("pointerup", { target });
    expect(h.calls).toEqual([]);
  });

  // Risk 2: the sheet a button opens mounts inside the same gesture and calls
  // sheetHaptic() — one tap, one tick.
  it("does not tick again for a sheet opened by the tap that already ticked", async () => {
    const { installTapHaptics, sheetHaptic } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("tap"));
    sheetHaptic();
    expect(h.calls).toEqual(["impact:LIGHT"]);
  });

  it("lets a sheet opened from a non-tappable trigger take the tick", async () => {
    const { installTapHaptics, sheetHaptic } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("none"));
    sheetHaptic();
    // …and only once, however many times the effect re-runs (StrictMode).
    sheetHaptic();
    expect(h.calls).toEqual(["impact:LIGHT"]);
  });

  it("stays silent for a sheet that appears with no gesture behind it", async () => {
    const { sheetHaptic } = await loadHaptics();
    sheetHaptic();
    expect(h.calls).toEqual([]);
  });

  it("gives each new gesture its own tick", async () => {
    const { installTapHaptics } = await loadHaptics();
    const { doc, dispatch } = fakeDocument();
    installTapHaptics(doc);
    tap(dispatch, el("tap"));
    tap(dispatch, el("tap"));
    expect(h.calls).toEqual(["impact:LIGHT", "impact:LIGHT"]);
  });
});
