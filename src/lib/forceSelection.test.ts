import { describe, expect, it } from "vitest";
import {
  restoredSelection,
  selectZoneOutcome,
  withPresetSelected,
  withZoneSelected,
} from "./forceSelection";
import type { ForceSelection } from "./forceSelection";
import type { ZoneSelection } from "./zoneSelection";
import type { TindeqPreset } from "../types";

const preset: TindeqPreset = {
  id: "p1",
  name: "Custom",
  holdS: 7,
  reps: 6,
  sets: 3,
  restRepsS: 3,
  restSetsS: 180,
  targetKg: null,
  targetPct: null,
  pctBasis: "pr",
  pctStep: 0,
  targetCurve: false,
  alternateSides: false,
};

const otherPreset: TindeqPreset = { ...preset, id: "p2", name: "Custom 2" };

const zoneSel: ZoneSelection = {
  target: { kg: 30, lowKg: 27, highKg: 33, workS: 7, label: "Strength" },
  protocol: { ...preset, id: "zone:strength" },
};

const otherZoneSel: ZoneSelection = {
  target: { kg: 40, lowKg: 36, highKg: 44, workS: 10, label: "Power" },
  protocol: { ...preset, id: "zone:power" },
};

const empty: ForceSelection = { zoneSel: null, preset: null };

// #296 — arming one of {zone, custom preset} must disarm the other; the
// fullscreen previously read whichever `activeProtocol`'s precedence
// favored (custom preset always won) regardless of which was armed last.
describe("withZoneSelected / withPresetSelected (#296)", () => {
  it("arming a zone while a preset is armed clears the preset", () => {
    const next = withZoneSelected({ zoneSel: null, preset }, zoneSel);
    expect(next.zoneSel).toBe(zoneSel);
    expect(next.preset).toBeNull();
  });

  it("arming a preset while a zone is armed clears the zone", () => {
    const next = withPresetSelected({ zoneSel, preset: null }, preset);
    expect(next.preset).toBe(preset);
    expect(next.zoneSel).toBeNull();
  });

  it("deselecting a zone (arm null) only clears the zone field, nothing else", () => {
    // `preset` non-null here is an impossible state under normal usage (the
    // two are kept exclusive by the caller) — deliberately used to prove the
    // null branch spreads `current` rather than resetting both fields.
    const state: ForceSelection = { zoneSel, preset };
    const next = withZoneSelected(state, null);
    expect(next.zoneSel).toBeNull();
    expect(next.preset).toBe(preset);
  });

  it("deselecting a preset (arm null) only clears the preset field, nothing else", () => {
    const state: ForceSelection = { zoneSel, preset };
    const next = withPresetSelected(state, null);
    expect(next.preset).toBeNull();
    expect(next.zoneSel).toBe(zoneSel);
  });

  it("re-arming an already-armed zone (intensity/alternate-sides) is a no-op on preset, which stays null", () => {
    const state: ForceSelection = { zoneSel, preset: null };
    const next = withZoneSelected(state, otherZoneSel);
    expect(next.zoneSel).toBe(otherZoneSel);
    expect(next.preset).toBeNull();
  });

  it("re-selecting a preset while no zone is armed touches nothing extra", () => {
    const state: ForceSelection = { zoneSel: null, preset };
    const next = withPresetSelected(state, otherPreset);
    expect(next.preset).toBe(otherPreset);
    expect(next.zoneSel).toBeNull();
  });

  it("arming null on an already-empty selection stays empty", () => {
    expect(withZoneSelected(empty, null)).toEqual(empty);
    expect(withPresetSelected(empty, null)).toEqual(empty);
  });
});

// #296 follow-up: the self-review caught two races reintroducing the
// original bug — a mount-time restore racing a zone armed while the presets
// fetch was still in flight, and a persisted-preset key surviving that same
// race. Both are exercised as pure decisions here since PresetManager's
// effect-timing side of the fix (refs holding the latest selectedId/onRestore,
// synced via useLayoutEffect rather than useEffect so the sync is committed
// before the fetch's `.then()` microtask can ever observe a stale ref) can't
// itself be exercised without a live DOM (this repo has no jsdom/testing-library,
// per useTindeq.test.ts).
describe("selectZoneOutcome (#296 follow-up)", () => {
  it("arming a zone clears the persisted-preset flag even when preset state was already null", () => {
    const outcome = selectZoneOutcome({ zoneSel: null, preset: null }, zoneSel);
    expect(outcome.selection.zoneSel).toBe(zoneSel);
    expect(outcome.selection.preset).toBeNull();
    expect(outcome.clearsPersistedPreset).toBe(true);
  });

  it("arming a zone while a preset is armed also clears the persisted flag", () => {
    const outcome = selectZoneOutcome({ zoneSel: null, preset }, zoneSel);
    expect(outcome.clearsPersistedPreset).toBe(true);
  });

  it("deselecting a zone (arm null) does not clear the persisted-preset flag", () => {
    const outcome = selectZoneOutcome({ zoneSel, preset: null }, null);
    expect(outcome.selection.zoneSel).toBeNull();
    expect(outcome.clearsPersistedPreset).toBe(false);
  });
});

describe("restoredSelection (#296 follow-up)", () => {
  it("restores the persisted preset when nothing is armed", () => {
    const next = restoredSelection(empty, preset);
    expect(next.preset).toBe(preset);
    expect(next.zoneSel).toBeNull();
  });

  it("a restore arriving after a zone is armed leaves the zone armed and the preset unarmed", () => {
    const next = restoredSelection({ zoneSel, preset: null }, preset);
    expect(next.zoneSel).toBe(zoneSel);
    expect(next.preset).toBeNull();
  });

  it("a restore arriving after a preset was already armed directly leaves that preset in place", () => {
    const next = restoredSelection({ zoneSel: null, preset: otherPreset }, preset);
    expect(next.preset).toBe(otherPreset);
    expect(next.zoneSel).toBeNull();
  });
});
