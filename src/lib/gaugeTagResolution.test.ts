import { describe, it, expect } from "vitest";
import {
  GAUGE_LAST_SIDE_KEY,
  GAUGE_LAST_TAG_KEY,
  loadLastUsedGaugeLabel,
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

  it("never lets the display fallback surface: allTags is not even an input", () => {
    // The signature has no allTags param — the only way `allTags[0]` can
    // reach a saved rep is to pass it as the explicit selection.
    expect(resolveRecordingTag("", null)).toBe("");
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
