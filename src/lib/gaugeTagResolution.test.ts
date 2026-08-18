import { describe, it, expect } from "vitest";
import {
  GAUGE_LAST_SIDE_KEY,
  GAUGE_LAST_TAG_KEY,
  loadLastUsedGaugeLabel,
  rememberGaugeLabelSelection,
  resolveRecordingGaugeLabel,
  resolveRecordingSide,
  resolveRecordingTag,
  saveLastUsedGaugeLabel,
  type GaugeLabelStorage,
} from "./gaugeTagResolution";

/// In-memory stand-in for localStorage — keeps these tests jsdom-free (this
/// project's vitest config runs in node), mirroring zoneSelection.test.ts's
/// "jsdom-free, in-memory stand-in" convention.
function fakeStorage(): GaugeLabelStorage & { entries: () => Map<string, string> } {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    entries: () => map,
  };
}

function throwingStorage(): GaugeLabelStorage {
  return {
    getItem: () => null,
    setItem: () => {
      throw new Error("QuotaExceededError");
    },
  };
}

describe("resolveRecordingTag (#684 persist boundary)", () => {
  it("an explicit selection always wins", () => {
    expect(resolveRecordingTag("FDP", "Crimp")).toBe("FDP");
    expect(resolveRecordingTag("FDP", null)).toBe("FDP");
    expect(resolveRecordingTag("  new tag  ", "Crimp")).toBe("new tag");
  });

  it("an empty explicit field falls back to the remembered last-used tag", () => {
    expect(resolveRecordingTag("", "Crimp")).toBe("Crimp");
    expect(resolveRecordingTag("   ", "Crimp")).toBe("Crimp");
  });

  it("with neither, the recording is untagged ('') — never allTags[0]", () => {
    expect(resolveRecordingTag("", null)).toBe("");
    expect(resolveRecordingTag("", "")).toBe("");
  });
});

describe("resolveRecordingSide", () => {
  it("an explicit side always wins", () => {
    expect(resolveRecordingSide("left", "right")).toBe("left");
    expect(resolveRecordingSide("left", "")).toBe("left");
  });

  it("an empty explicit side falls back to the remembered last-used side", () => {
    expect(resolveRecordingSide("", "right")).toBe("right");
  });

  it("with neither, the side is unspecified ('')", () => {
    expect(resolveRecordingSide("", "")).toBe("");
    expect(resolveRecordingSide("", null)).toBe("");
  });
});

describe("loadLastUsedGaugeLabel", () => {
  it("reads the remembered pair", () => {
    const storage = fakeStorage();
    storage.setItem(GAUGE_LAST_TAG_KEY, "Crimp");
    storage.setItem(GAUGE_LAST_SIDE_KEY, "right");
    expect(loadLastUsedGaugeLabel(storage)).toEqual({ tag: "Crimp", side: "right" });
  });

  it("trims a remembered tag", () => {
    const storage = fakeStorage();
    storage.setItem(GAUGE_LAST_TAG_KEY, "  FDP  ");
    expect(loadLastUsedGaugeLabel(storage).tag).toBe("FDP");
  });

  it("treats absent storage as nothing remembered", () => {
    expect(loadLastUsedGaugeLabel(fakeStorage())).toEqual({ tag: "", side: "" });
    expect(loadLastUsedGaugeLabel(null)).toEqual({ tag: "", side: "" });
  });

  it("tolerates a corrupt record instead of throwing", () => {
    const storage = fakeStorage();
    storage.setItem(GAUGE_LAST_TAG_KEY, "{not a tag");
    expect(loadLastUsedGaugeLabel(storage)).toEqual({ tag: "{not a tag", side: "" });
  });

  it("validates the persisted side against the TindeqSide union — a corrupt value degrades to '' instead of poisoning the queue (#684 F5)", () => {
    // The DB column is constrained: `check (side in ('', 'left', 'right',
    // 'both'))` — any other string would flow through resolveRecordingSide
    // (which only checks truthiness) into rec.side and fail the insert with
    // 23514, stranding the durable rep in the retry queue forever. A
    // hand-edited / corrupted value must read as "no side remembered".
    const storage = fakeStorage();
    storage.setItem(GAUGE_LAST_TAG_KEY, "Crimp");
    storage.setItem(GAUGE_LAST_SIDE_KEY, "ambidextrous");
    expect(loadLastUsedGaugeLabel(storage)).toEqual({ tag: "Crimp", side: "" });
  });

  it("keeps every legal TindeqSide value on read", () => {
    for (const side of ["", "left", "right", "both"] as const) {
      const storage = fakeStorage();
      storage.setItem(GAUGE_LAST_TAG_KEY, "Crimp");
      storage.setItem(GAUGE_LAST_SIDE_KEY, side);
      expect(loadLastUsedGaugeLabel(storage).side).toBe(side);
    }
  });

  it("never throws when storage is disabled", () => {
    expect(loadLastUsedGaugeLabel(throwingStorage())).toEqual({ tag: "", side: "" });
  });
});

describe("saveLastUsedGaugeLabel", () => {
  it("persists the pair under both keys", () => {
    const storage = fakeStorage();
    saveLastUsedGaugeLabel("Crimp", "right", storage);
    expect(storage.getItem(GAUGE_LAST_TAG_KEY)).toBe("Crimp");
    expect(storage.getItem(GAUGE_LAST_SIDE_KEY)).toBe("right");
  });

  it("persists a trimmed tag", () => {
    const storage = fakeStorage();
    saveLastUsedGaugeLabel("  FDP  ", "", storage);
    expect(storage.getItem(GAUGE_LAST_TAG_KEY)).toBe("FDP");
  });

  it("ignores disabled storage rather than throwing", () => {
    expect(() => saveLastUsedGaugeLabel("FDP", "", throwingStorage())).not.toThrow();
    expect(() => saveLastUsedGaugeLabel("FDP", "", null)).not.toThrow();
  });
});

describe("rememberGaugeLabelSelection (#684 F2 — the remember rule lives HERE, testable, not in an inline component closure)", () => {
  it("picking a side while the exercise field is empty keeps the remembered tag", () => {
    // The F2 failure: `handlePendingSide("right")` used to write
    // { tag: "", side: "right" }, destroying the remembered "Crimp" the very
    // tap was meant to rely on. The merge carries the remembered tag through.
    const storage = fakeStorage();
    const merged = rememberGaugeLabelSelection(
      { tag: "", side: "right" },
      { tag: "Crimp", side: "left" },
      storage,
    );
    expect(merged).toEqual({ tag: "Crimp", side: "right" });
    expect(storage.getItem(GAUGE_LAST_TAG_KEY)).toBe("Crimp");
    expect(storage.getItem(GAUGE_LAST_SIDE_KEY)).toBe("right");
  });

  it("picking an exercise while the side is empty keeps the remembered side", () => {
    // The symmetric F2 shape: `handlePendingTag("FDP")` with side unset must
    // not reset the remembered side to "".
    const storage = fakeStorage();
    const merged = rememberGaugeLabelSelection(
      { tag: "FDP", side: "" },
      { tag: "Crimp", side: "left" },
      storage,
    );
    expect(merged).toEqual({ tag: "FDP", side: "left" });
    expect(storage.getItem(GAUGE_LAST_TAG_KEY)).toBe("FDP");
    expect(storage.getItem(GAUGE_LAST_SIDE_KEY)).toBe("left");
  });

  it("an explicit pair fully overwrites the remembered one", () => {
    const storage = fakeStorage();
    const merged = rememberGaugeLabelSelection(
      { tag: "Half crimp", side: "both" },
      { tag: "Crimp", side: "left" },
      storage,
    );
    expect(merged).toEqual({ tag: "Half crimp", side: "both" });
    expect(storage.getItem(GAUGE_LAST_TAG_KEY)).toBe("Half crimp");
    expect(storage.getItem(GAUGE_LAST_SIDE_KEY)).toBe("both");
  });

  it("persists the merged pair and returns it (so the caller can mirror a ref without re-reading storage)", () => {
    const storage = fakeStorage();
    const merged = rememberGaugeLabelSelection(
      { tag: "  FDP  ", side: "right" },
      { tag: "Crimp", side: "" },
      storage,
    );
    // tag trimmed, side written, nothing clobbered
    expect(merged).toEqual({ tag: "FDP", side: "right" });
    expect(storage.getItem(GAUGE_LAST_TAG_KEY)).toBe("FDP");
    expect(storage.getItem(GAUGE_LAST_SIDE_KEY)).toBe("right");
  });
});

describe("resolveRecordingGaugeLabel", () => {
  it("resolves the full pair: explicit wins, last-used falls back, untagged last", () => {
    expect(resolveRecordingGaugeLabel({ tag: "FDP", side: "left" }, { tag: "Crimp", side: "right" }))
      .toEqual({ tag: "FDP", side: "left" });
    expect(resolveRecordingGaugeLabel({ tag: "", side: "" }, { tag: "Crimp", side: "right" }))
      .toEqual({ tag: "Crimp", side: "right" });
    expect(resolveRecordingGaugeLabel({ tag: "", side: "" }, { tag: "", side: "" }))
      .toEqual({ tag: "", side: "" });
  });
});
