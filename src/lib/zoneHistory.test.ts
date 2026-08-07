import { describe, expect, it } from "vitest";
import {
  balanceScopeCounts,
  classifyZone,
  classifyZoneLoaded,
  curveCandidateRecordings,
  CURVE_BIAS_RATIO,
  dominantZone,
  effortPeakKg,
  isDepletionEffortRecording,
  isEffortRecording,
  isMeasuredRecording,
  isRecoveredRecording,
  recommendZone,
  recordingCapacityModality,
  recordingZone,
  TIE_BAND_SETS,
  zoneSetDurationS,
  zoneSets,
  zoneTrainingSets,
} from "./zoneHistory";
import type { ForceCurveModel, TrainingQuality } from "./force-curve";

describe("isMeasuredRecording (#367)", () => {
  it("requires dynamometer provenance and both measured statistics", () => {
    expect(isMeasuredRecording({ source: "dynamometer", peakKg: 30, avgKg: 25 })).toBe(true);
    expect(isMeasuredRecording({ source: "manual", peakKg: 30, avgKg: 25 })).toBe(false);
    expect(isMeasuredRecording({ source: "dynamometer", peakKg: null, avgKg: 25 })).toBe(false);
    expect(isMeasuredRecording({ source: "dynamometer", peakKg: 30, avgKg: null })).toBe(false);
  });
});

describe("capacity modality partitioning (#422)", () => {
  const measured = (
    id: string,
    protocolMode?: "hold" | "reverse_action",
    capacityEvidence?: boolean | null,
  ) => ({
    id,
    durationMs: 30_000,
    tag: "FDP",
    side: "left" as const,
    zone: "endurance" as const,
    peakKg: 30,
    avgKg: 25,
    source: "dynamometer" as const,
    protocolMode,
    capacityEvidence,
  });

  it("treats historical null/hold rows as Static and Reverse Action only as Reverse Action", () => {
    expect(recordingCapacityModality({})).toBe("static");
    expect(recordingCapacityModality({ protocolMode: "hold" })).toBe("static");
    expect(recordingCapacityModality({ protocolMode: "reverse_action" })).toBe("reverse_action");
  });

  it("never lets Static and Reverse Action rows enter each other's curve or PR", () => {
    const rows = [measured("legacy"), measured("hold", "hold"), measured("reverse", "reverse_action")];
    expect(curveCandidateRecordings(rows, "FDP", "left", "static").map((r) => r.id)).toEqual([
      "legacy",
      "hold",
    ]);
    expect(curveCandidateRecordings(rows, "FDP", "left", "reverse_action").map((r) => r.id)).toEqual([
      "reverse",
    ]);
    expect(effortPeakKg(rows, "FDP", "left", "static")).toBe(30);
    expect(effortPeakKg(rows, "FDP", "left", "reverse_action")).toBe(30);
  });

  it("keeps historical Reverse Action evidence but excludes new ordinary prescribed sets", () => {
    const rows = [
      measured("historical", "reverse_action", null),
      measured("capacity", "reverse_action", true),
      measured("ordinary", "reverse_action", false),
    ];
    expect(curveCandidateRecordings(rows, "FDP", "left", "reverse_action").map((r) => r.id)).toEqual([
      "historical",
      "capacity",
    ]);
  });

  it("excludes cadence-only rows from both models regardless of stamped mode", () => {
    const cadence = {
      ...measured("cadence", "reverse_action", true),
      source: "manual" as const,
      peakKg: null,
      avgKg: null,
    };
    expect(curveCandidateRecordings([cadence], "FDP", "left", "reverse_action")).toEqual([]);
    expect(effortPeakKg([cadence], "FDP", "left", "reverse_action")).toBeNull();
  });
});

describe("zoneSetDurationS (#320)", () => {
  it("endurance still reads 240s despite the 1×8 shape flip", () => {
    // Was holdS(30) × reps(8) = 240 pre-#320; reps flipped to 1 and sets to
    // 8, so the plain holdS × reps would silently drop to 30 and inflate
    // endurance training-balance 8× — this is the regression the issue
    // calls out as the one that would pass unnoticed.
    expect(zoneSetDurationS("endurance")).toBe(240);
  });

  it("other zones are unchanged by the endurance-only special case", () => {
    expect(zoneSetDurationS("power")).toBe(30);
    expect(zoneSetDurationS("strength")).toBe(50);
    expect(zoneSetDurationS("power-endurance")).toBe(42);
  });
});

describe("classifyZone (SL-100)", () => {
  it("buckets by hold duration around the zone anchors", () => {
    expect(classifyZone(0.5)).toBeNull();
    expect(classifyZone(5)).toBe("power");
    expect(classifyZone(6)).toBe("power");
    expect(classifyZone(7)).toBe("power-endurance");
    expect(classifyZone(8.5)).toBe("power-endurance");
    expect(classifyZone(10)).toBe("strength");
    expect(classifyZone(20)).toBe("strength");
    expect(classifyZone(30)).toBe("endurance");
    expect(classifyZone(90)).toBe("endurance");
  });
});

describe("recordingZone (#259)", () => {
  it("uses the zone the recording was performed under when it has one", () => {
    // 12s would be inferred as strength; recorded as power, it IS power.
    expect(recordingZone({ durationMs: 12_000, zone: "power" })).toEqual({
      zone: "power",
      source: "recorded",
    });
  });

  it("falls back to the duration inference when the zone is null", () => {
    expect(recordingZone({ durationMs: 12_000, zone: null })).toEqual({
      zone: "strength",
      source: "inferred",
    });
  });

  it("treats an absent zone field the same as null (pre-#259 shapes)", () => {
    expect(recordingZone({ durationMs: 5_000 })).toEqual({
      zone: "power",
      source: "inferred",
    });
  });

  it("honours a recorded zone at any duration — only an inference can fail", () => {
    // The sub-1s stray-blip rule exists to throw away accidental taps in a
    // GUESS. A recorded zone is a fact about how the hold was performed, so
    // it isn't second-guessed; nothing else can produce a null `zone` with
    // source "recorded".
    expect(recordingZone({ durationMs: 400, zone: "strength" })).toEqual({
      zone: "strength",
      source: "recorded",
    });
    expect(recordingZone({ durationMs: 400, zone: null })).toEqual({
      zone: null,
      source: "inferred",
    });
  });

  it("recognizes a recorded 'prehab' zone (#325) — never inferred, always a fact", () => {
    // 30s would infer as endurance; recorded as prehab, it IS prehab — the
    // exact divergence writing the zone exists to guarantee.
    expect(recordingZone({ durationMs: 30_000, zone: "prehab" })).toEqual({
      zone: "prehab",
      source: "recorded",
    });
  });

  it("recognizes a recorded 'warmup' zone — never duration-infers its sets", () => {
    expect(recordingZone({ durationMs: 5_000, zone: "warmup" })).toEqual({
      zone: "warmup",
      source: "recorded",
    });
    expect(recordingZone({ durationMs: 10_000, zone: "warmup" })).toEqual({
      zone: "warmup",
      source: "recorded",
    });
  });
});

describe("isEffortRecording (#325)", () => {
  it("is false for a recorded Prehab hold — never a maximal-intent effort", () => {
    expect(isEffortRecording({ durationMs: 30_000, zone: "prehab" })).toBe(false);
  });

  it("is false for Warm-up capacity evidence, but keeps its real RPE depletion", () => {
    const warmup = { durationMs: 10_000, zone: "warmup" as const };
    expect(isEffortRecording(warmup)).toBe(false);
    expect(isDepletionEffortRecording(warmup)).toBe(true);
    expect(isDepletionEffortRecording({ durationMs: 30_000, zone: "prehab" })).toBe(false);
  });

  it("is true for every trainable zone, recorded or inferred, at any duration", () => {
    expect(isEffortRecording({ durationMs: 5_000, zone: "power" })).toBe(true);
    expect(isEffortRecording({ durationMs: 12_000, zone: null })).toBe(true); // infers as strength
    expect(isEffortRecording({ durationMs: 30_000, zone: null })).toBe(true); // infers as endurance
  });

  it("is true for a null-zone sub-1s blip — unclassified is not the same as excluded", () => {
    expect(isEffortRecording({ durationMs: 400, zone: null })).toBe(true);
  });
});

describe("isRecoveredRecording (#486 review — F4)", () => {
  it("is true for a true whole-buffer blob: no protocol run, no recorded zone, exact salvage note", () => {
    expect(
      isRecoveredRecording({ note: "Recovered after sign-out", zone: null, protocolRunId: null }),
    ).toBe(true);
    expect(
      isRecoveredRecording({
        note: "Recovered after connection loss",
        zone: null,
        protocolRunId: undefined,
      }),
    ).toBe(true);
  });

  it("is FALSE for a reconstructed adaptive/reverse-action hold carrying the identical note text — F4's over-exclusion", () => {
    // buildAdaptiveStaticSalvage / buildUnclaimedReverseActionSalvage: a
    // precisely time-sliced hold/set with a real protocolRunId and a
    // recorded zone, that can carry the exact same note a true blob does.
    // Note text alone cannot tell them apart — the zone/protocolRunId
    // conjunction is what does.
    expect(
      isRecoveredRecording({
        note: "Recovered after sign-out",
        zone: "strength",
        protocolRunId: "run-1",
      }),
    ).toBe(false);
    expect(
      isRecoveredRecording({
        note: "Recovered after connection loss",
        zone: "power",
        protocolRunId: "run-2",
      }),
    ).toBe(false);
  });

  it("is FALSE for a composite note (the adaptive salvage's actual shape) even with no protocol run", () => {
    // Exact match, not prefix — "Recovered after sign-out · Hands-free
    // protocol attempt failed" is a different string entirely.
    expect(
      isRecoveredRecording({
        note: "Recovered after sign-out · Hands-free protocol attempt failed",
        zone: null,
        protocolRunId: null,
      }),
    ).toBe(false);
  });

  it("is FALSE for an ordinary un-noted free hold (the common zone:null/protocolRunId:null case)", () => {
    expect(
      isRecoveredRecording({ note: "", zone: null, protocolRunId: null }),
    ).toBe(false);
    expect(
      isRecoveredRecording({ note: undefined, zone: null, protocolRunId: null }),
    ).toBe(false);
  });

  it("is FALSE for a user's own unrelated note, even one sharing the 'Recovered after' prefix", () => {
    // F3: note is user-editable (EditRecordingSheet). Exact match — not the
    // old startsWith — so an ordinary training-log phrase can't collide.
    expect(
      isRecoveredRecording({
        note: "Recovered after 3 min rest",
        zone: null,
        protocolRunId: null,
      }),
    ).toBe(false);
  });
});

describe("effortPeakKg (#325)", () => {
  const rec = (
    peakKg: number,
    tag: string,
    side: "left" | "right",
    zone: "prehab" | null = null,
    durationMs = 5_000,
  ) => ({ peakKg, avgKg: peakKg * 0.9, tag, side, zone, durationMs, source: "dynamometer" as const });

  it("is null with no tag selected", () => {
    expect(effortPeakKg([rec(40, "FDP", "left")], null, "left")).toBeNull();
  });

  it("is null when there is no recording for the tag/side yet", () => {
    expect(effortPeakKg([], "FDP", "left")).toBeNull();
  });

  it("ignores a Prehab hold that would otherwise become the PR by walkover", () => {
    // No real effort has ever been recorded for this tag/side — only a
    // submax Prehab hold at ~0.29×maxF. A naive Math.max would crown IT the
    // PR, and every future `pctBasis: "pr"` preset would then target a
    // fraction of a fraction of true capacity.
    const recs = [rec(11.6, "FDP", "left", "prehab")];
    expect(effortPeakKg(recs, "FDP", "left")).toBeNull();
  });

  it("ignores a Warm-up hold that would otherwise become the PR by walkover", () => {
    const warmupOnly = [{
      peakKg: 28,
      tag: "FDP",
      side: "left" as const,
      zone: "warmup" as const,
      durationMs: 10_000,
      avgKg: 25,
      source: "dynamometer" as const,
    }];
    expect(effortPeakKg(warmupOnly, "FDP", "left")).toBeNull();
  });

  it("takes the best EFFORT peak, ignoring a higher Prehab reading and other tags/sides", () => {
    const recs = [
      rec(40, "FDP", "left"),
      rec(45, "FDP", "left"), // the real PR
      rec(90, "FDP", "left", "prehab"), // impossible in practice, but even so: never wins
      rec(99, "FDP", "right"), // wrong side
      rec(99, "3F", "left"), // wrong tag
    ];
    expect(effortPeakKg(recs, "FDP", "left")).toBe(45);
  });

  it("with side null, pools both sides", () => {
    const recs = [rec(40, "FDP", "left"), rec(48, "FDP", "right")];
    expect(effortPeakKg(recs, "FDP", null)).toBe(48);
  });

  it("#486 review F1: a salvage/recovery blob's PEAK still counts toward the PR — only the curve fit excludes it", () => {
    // The blob's duration/avg are contaminated by inter-rep rests (what the
    // curve fit consumes); its peakKg is a genuine instantaneous max over
    // real samples and is unaffected. Dropping it here would silently lower
    // the user's PR and re-prescribe every %-of-PR preset lighter with no
    // UI indication — the exact regression the review caught (62 -> 55 kg).
    const cleanRep = { peakKg: 55, avgKg: 50, tag: "FDP", side: "left" as const, zone: "strength" as const, durationMs: 10_000, source: "dynamometer" as const, protocolRunId: null };
    const blob = { peakKg: 62, avgKg: 30, tag: "FDP", side: "left" as const, zone: null, durationMs: 536_000, source: "dynamometer" as const, note: "Recovered after connection loss", protocolRunId: null };
    expect(effortPeakKg([cleanRep, blob], "FDP", "left")).toBe(62);
  });
});

describe("curveCandidateRecordings (#325)", () => {
  const rec = (
    id: string,
    durationMs: number,
    tag: string,
    side: "left" | "right",
    zone: "prehab" | "strength" | null = null,
  ) => ({ id, durationMs, tag, side, zone, peakKg: 30, avgKg: 25, source: "dynamometer" as const });

  it("is empty with no tag selected", () => {
    expect(curveCandidateRecordings([rec("r1", 20_000, "FDP", "left")], null, "left")).toEqual([]);
  });

  it("excludes a Prehab hold even as the longest single effort in the pool", () => {
    // This is the guarantee ForceView's curve fit depends on: a 30s Prehab
    // hold at 0.70×CF must never reach `pickCurveRecordings`, or CF ratchets
    // down every session (see the doc on `isEffortRecording`).
    const trainingHold = rec("t1", 20_000, "FDP", "left", "strength");
    const prehabHold = rec("p1", 30_000, "FDP", "left", "prehab");
    const picked = curveCandidateRecordings([trainingHold, prehabHold], "FDP", "left");
    expect(picked.map((r) => r.id)).toEqual(["t1"]);
  });

  it("scopes to the given tag/side, and pools both sides when side is null", () => {
    const recs = [
      rec("left", 20_000, "FDP", "left", "strength"),
      rec("right", 20_000, "FDP", "right", "strength"),
      rec("otherTag", 20_000, "3F", "left", "strength"),
    ];
    expect(curveCandidateRecordings(recs, "FDP", "left").map((r) => r.id)).toEqual(["left"]);
    expect(curveCandidateRecordings(recs, "FDP", null).map((r) => r.id)).toEqual(["left", "right"]);
  });

  it("#486 review F4: excludes a true blob but admits a reconstructed hold carrying the identical note", () => {
    const blob = {
      id: "blob",
      durationMs: 536_000,
      tag: "FDP",
      side: "left" as const,
      zone: null,
      protocolRunId: null,
      note: "Recovered after sign-out",
      peakKg: 62,
      avgKg: 30,
      source: "dynamometer" as const,
    };
    // buildUnclaimedReverseActionSalvage's actual shape: same literal note
    // text as the blob, but a real protocolRunId and a recorded zone — a
    // legitimate per-set reconstruction, not a raw buffer slice.
    const reconstructed = {
      id: "reconstructed",
      durationMs: 8_000,
      tag: "FDP",
      side: "left" as const,
      zone: "strength" as const,
      protocolRunId: "run-42",
      note: "Recovered after sign-out",
      peakKg: 40,
      avgKg: 35,
      source: "dynamometer" as const,
    };
    const picked = curveCandidateRecordings([blob, reconstructed], "FDP", "left");
    expect(picked.map((r) => r.id)).toEqual(["reconstructed"]);
  });
});

describe("balanceScopeCounts (#325)", () => {
  it("excludes Prehab holds from both the total and the recorded count", () => {
    // 2 trainable holds (1 recorded, 1 inferred) + 2 Prehab holds — Prehab is
    // ALWAYS recorded (never inferred), so a naive count over every hold
    // would read "4 of 4 recorded"; the balance only ever credited the 2
    // trainable holds, so the copy must match that, not the raw count.
    const recs = [
      { durationMs: 10_000, zone: "strength" as const },
      { durationMs: 12_000, zone: null }, // inferred as strength
      { durationMs: 30_000, zone: "prehab" as const },
      { durationMs: 30_000, zone: "prehab" as const },
    ];
    expect(balanceScopeCounts(recs)).toEqual({ effortCount: 2, recordedCount: 1 });
  });

  it("reads as fully recorded when every effort hold carries its own zone", () => {
    const recs = [
      { durationMs: 10_000, zone: "strength" as const },
      { durationMs: 30_000, zone: "prehab" as const },
    ];
    expect(balanceScopeCounts(recs)).toEqual({ effortCount: 1, recordedCount: 1 });
  });

  it("returns zero counts when only Prehab holds are in scope", () => {
    const recs = [
      { durationMs: 30_000, zone: "prehab" as const },
      { durationMs: 30_000, zone: "prehab" as const },
    ];
    expect(balanceScopeCounts(recs)).toEqual({ effortCount: 0, recordedCount: 0 });
  });

  it("excludes Warm-up holds from both scope counts", () => {
    expect(
      balanceScopeCounts([
        { durationMs: 5_000, zone: "warmup" },
        { durationMs: 10_000, zone: "warmup" },
      ]),
    ).toEqual({ effortCount: 0, recordedCount: 0 });
  });

  it("#486 review F2: counts a salvage/recovery blob — stays consistent with zoneSets, which was never filtering it out", () => {
    // Training balance is out of scope for #486 (only curveCandidateRecordings
    // excludes a blob); balanceScopeCounts and zoneSets must agree on whether
    // it's counted, or this function's own doc comment ("would make both
    // sentences literally false") becomes true of the fix instead of the bug.
    const cleanRep = { durationMs: 10_000, zone: "strength" as const };
    const blob = { durationMs: 536_000, zone: null, note: "Recovered after connection loss" };
    const counts = balanceScopeCounts([cleanRep, blob]);
    expect(counts.effortCount).toBe(2);
    // zoneSets buckets the blob's ~536s as endurance (inferred from raw
    // duration) — the same bucket balanceScopeCounts's effortCount now
    // agrees it belongs in, matching "N holds fed the numbers below" to the
    // holds the bars actually total.
    const sets = zoneSets([cleanRep, blob]);
    expect(sets.endurance).toBeGreaterThan(0);
  });
});

/// The proof that #259 shifted no historical data. Every recording that
/// exists today has no zone column value, so `recordingZone` must reproduce
/// `classifyZone` for all of them — not approximately, identically. The
/// legacy rule is re-implemented here verbatim rather than imported, so this
/// still fails if someone "helpfully" changes classifyZone too.
describe("null-zone fallback is byte-for-byte today's behaviour (#259)", () => {
  function legacyClassify(durationS: number): TrainingQuality | null {
    if (durationS < 1) return null;
    if (durationS <= 6) return "power";
    if (durationS <= 8.5) return "power-endurance";
    if (durationS <= 20) return "strength";
    return "endurance";
  }
  function legacyZoneSets(recs: { durationMs: number }[]) {
    const secondsByZone: Record<TrainingQuality, number> = {
      power: 0,
      strength: 0,
      "power-endurance": 0,
      endurance: 0,
    };
    for (const r of recs) {
      const durationS = r.durationMs / 1000;
      const zone = legacyClassify(durationS);
      if (!zone) continue;
      secondsByZone[zone] += durationS;
    }
    // Divisors written out from ZONE_PROTOCOLS (holdS × reps) as they stand;
    // #259 doesn't touch them, so a change here would be a different bug and
    // should fail this test loudly rather than be absorbed.
    return {
      power: secondsByZone.power / (5 * 6),
      strength: secondsByZone.strength / (10 * 5),
      "power-endurance": secondsByZone["power-endurance"] / (7 * 6),
      endurance: secondsByZone.endurance / (30 * 8),
    };
  }

  // 0.0s → 60.0s in 0.1s steps: every band boundary, both sides of each.
  const DURATIONS_MS = Array.from({ length: 601 }, (_, i) => i * 100);

  it("resolves every duration to exactly what classifyZone resolves it to", () => {
    for (const durationMs of DURATIONS_MS) {
      const expected = legacyClassify(durationMs / 1000);
      // Both existing row shapes: the column absent (older client types) and
      // explicitly null (what the DB returns for un-backfilled rows).
      expect(recordingZone({ durationMs }).zone).toBe(expected);
      expect(recordingZone({ durationMs, zone: null }).zone).toBe(expected);
      expect(recordingZone({ durationMs }).source).toBe("inferred");
      expect(classifyZone(durationMs / 1000)).toBe(expected);
    }
  });

  it("gives zoneSets the identical numbers it gave before the column existed", () => {
    const recs = DURATIONS_MS.map((durationMs) => ({ durationMs }));
    expect(zoneSets(recs)).toEqual(legacyZoneSets(recs));
    expect(zoneSets(recs.map((r) => ({ ...r, zone: null })))).toEqual(
      legacyZoneSets(recs),
    );
    // …and for a realistic mixed history, not just the sweep.
    const history = [
      { durationMs: 5_000 },
      { durationMs: 5_200 },
      { durationMs: 7_100 },
      { durationMs: 9_900 },
      { durationMs: 13_600 },
      { durationMs: 31_400 },
      { durationMs: 400 },
    ];
    expect(zoneSets(history)).toEqual(legacyZoneSets(history));
  });

  it("only diverges once a recording actually carries a zone", () => {
    // Same hold, twice: 12s inferred is strength, 12s recorded as power is
    // power — and the seconds move with it, wholesale.
    const inferred = zoneSets([{ durationMs: 12_000 }]);
    const recorded = zoneSets([{ durationMs: 12_000, zone: "power" as const }]);
    expect(inferred.strength).toBeCloseTo(12 / 50, 10);
    expect(inferred.power).toBe(0);
    expect(recorded.power).toBeCloseTo(12 / 30, 10);
    expect(recorded.strength).toBe(0);
  });

  it("windows recorded holds by the same rule as inferred ones", () => {
    const recs = [
      { recordedAt: "2026-07-20T10:00:00Z", durationMs: 12_000, zone: "power" as const },
      { recordedAt: "2026-05-01T10:00:00Z", durationMs: 12_000, zone: "power" as const },
    ];
    const sets = zoneTrainingSets(recs, NOW, 28);
    expect(sets.power).toBeCloseTo(12 / 30, 10); // only the in-window one
  });
});

describe("classifyZoneLoaded (SL-97b)", () => {
  const refs = { maxF: 40, cf: 20 };

  it("falls back to the duration-only classifier with no resolved kg", () => {
    expect(classifyZoneLoaded(7, null, refs)).toBe(classifyZone(7));
    expect(classifyZoneLoaded(10, null, refs)).toBe(classifyZone(10));
  });

  it("falls back to the duration-only classifier with no maxF", () => {
    expect(classifyZoneLoaded(10, 34, { maxF: null, cf: 20 })).toBe(classifyZone(10));
  });

  it("still returns null for a sub-1s blip regardless of load", () => {
    expect(classifyZoneLoaded(0.5, 34, refs)).toBeNull();
  });

  it("≤ critical force is always endurance, even at a short hold", () => {
    // 15kg is below CF 20 — a hold this light is sustainable, not powerful,
    // no matter how short the hold happened to be.
    expect(classifyZoneLoaded(5, 15, refs)).toBe("endurance");
    expect(classifyZoneLoaded(5, 20, refs)).toBe("endurance"); // == CF counts too
  });

  it("power: ≥90% maxF and ≤6s", () => {
    expect(classifyZoneLoaded(5, 37, refs)).toBe("power"); // 0.925 · maxF
    expect(classifyZoneLoaded(6, 36, refs)).toBe("power"); // exactly 0.9 · maxF
  });

  it("strength: ≥80% maxF and ≤20s (worked example: maxF 40, cf 20, 10s @ 34kg)", () => {
    // Threshold matches the Strength zone's own band low (zoneTarget: 0.8·maxF,
    // #105/SL-103) so a preset only badges Strength when it actually reaches
    // that zone's load.
    expect(classifyZoneLoaded(10, 34, refs)).toBe("strength"); // 0.85 · maxF
    expect(classifyZoneLoaded(20, 32, refs)).toBe("strength"); // exactly 0.8 · maxF
  });

  it("a load just under the Strength band falls to power-endurance, not a fuzzy Strength badge", () => {
    // 30kg = 0.75·maxF — under the old (incidental) 0.75 threshold this
    // badged "Strength" despite sitting below the zone's own 0.8 low; it now
    // re-badges Power Endurance, which matches what the load actually is.
    expect(classifyZoneLoaded(20, 30, refs)).toBe("power-endurance");
  });

  it("power-endurance: above CF but under the power/strength thresholds, ≤20s", () => {
    expect(classifyZoneLoaded(10, 24, refs)).toBe("power-endurance"); // 0.6 · maxF
    expect(classifyZoneLoaded(5, 24, refs)).toBe("power-endurance"); // short but under 0.9 · maxF
  });

  it("endurance: above CF and > 20s, even without a strength-level load", () => {
    expect(classifyZoneLoaded(25, 24, refs)).toBe("endurance");
  });

  it("re-classifies live as the resolved load drops at a fixed hold time", () => {
    // The worked example from the PR: maxF 40, cf 20, hold fixed at 10s.
    expect(classifyZoneLoaded(10, 34, refs)).toBe("strength"); // 100% intensity, 34kg
    expect(classifyZoneLoaded(10, 24, refs)).toBe("power-endurance"); // ~70% intensity, 24kg
  });
});

const rec = (recordedAt: string, durationMs: number) => ({ recordedAt, durationMs });
const NOW = new Date("2026-07-21T12:00:00Z");

describe("zoneTrainingSets (SL-100, #182)", () => {
  it("sums hold duration per zone, normalised by that zone's protocol set length", () => {
    const sets = zoneTrainingSets(
      [
        rec("2026-07-20T10:00:00Z", 5000), // power, 5s
        rec("2026-07-20T10:05:00Z", 5200), // power, 5.2s, same day
        rec("2026-07-19T10:00:00Z", 5000), // power, 5s, different day → 15.2s total
        rec("2026-07-18T10:00:00Z", 30000), // endurance, 30s
      ],
      NOW,
    );
    // power set = 6 reps × 5s = 30s; endurance set = 8 reps × 30s = 240s.
    expect(sets.power).toBeCloseTo(15.2 / 30, 5);
    expect(sets.endurance).toBeCloseTo(30 / 240, 5);
    expect(sets.strength).toBe(0);
  });

  it("gives partial credit for a short warm-up instead of requiring a full session (#182)", () => {
    const sets = zoneTrainingSets(
      [rec("2026-07-20T10:00:00Z", 5000), rec("2026-07-20T10:01:00Z", 5000)],
      NOW,
    );
    expect(sets.power).toBeGreaterThan(0);
    expect(sets.power).toBeLessThan(1);
  });

  it("ignores holds older than the window", () => {
    const sets = zoneTrainingSets([rec("2026-05-01T10:00:00Z", 5000)], NOW, 28);
    expect(sets.power).toBe(0);
  });

  it("excludes an in-window Prehab hold from every zone (#325)", () => {
    const sets = zoneTrainingSets(
      [{ ...rec("2026-07-20T10:00:00Z", 30_000), zone: "prehab" as const }],
      NOW,
    );
    expect(sets).toEqual({
      power: 0,
      strength: 0,
      "power-endurance": 0,
      endurance: 0,
    });
  });
});

describe("zoneSets (#214)", () => {
  it("sums/normalises per zone with no window filtering — an ancient recordedAt still counts", () => {
    const sets = zoneSets([
      { durationMs: 5000 }, // power, 5s
      { durationMs: 5200 }, // power, 5.2s
      { durationMs: 30000 }, // endurance, 30s
    ]);
    // power set = 6 reps × 5s = 30s; endurance set = 8 reps × 30s = 240s.
    expect(sets.power).toBeCloseTo(10.2 / 30, 5);
    expect(sets.endurance).toBeCloseTo(30 / 240, 5);
    expect(sets.strength).toBe(0);
    expect(sets["power-endurance"]).toBe(0);
  });

  it("ignores sub-1s blips and returns all-zeros for an empty array", () => {
    expect(zoneSets([])).toEqual({
      power: 0,
      strength: 0,
      "power-endurance": 0,
      endurance: 0,
    });
    expect(zoneSets([{ durationMs: 500 }])).toEqual({
      power: 0,
      strength: 0,
      "power-endurance": 0,
      endurance: 0,
    });
  });

  it("excludes Prehab holds from every zone's total (#325) — recorded outside training balance BY DESIGN", () => {
    // Un-tagged, this 30s hold would infer as endurance — proof that writing
    // the zone is what keeps it out of training balance, not its duration.
    const sets = zoneSets([{ durationMs: 30_000, zone: "prehab" as const }]);
    expect(sets).toEqual({
      power: 0,
      strength: 0,
      "power-endurance": 0,
      endurance: 0,
    });
  });

  it("matches zoneTrainingSets when nothing falls outside the window (no time-window behavior lost)", () => {
    const recs = [
      rec("2026-07-20T10:00:00Z", 5000),
      rec("2026-07-19T10:00:00Z", 30000),
    ];
    expect(zoneTrainingSets(recs, NOW)).toEqual(zoneSets(recs));
  });
});

describe("dominantZone (#214)", () => {
  it("returns the highest-count zone — the issue's own numbers (Power 4 / Endurance 0.8) yield power", () => {
    expect(
      dominantZone({ power: 4, strength: 0, "power-endurance": 0, endurance: 0.8 }),
    ).toBe("power");
  });

  it("returns null when all zero", () => {
    expect(
      dominantZone({ power: 0, strength: 0, "power-endurance": 0, endurance: 0 }),
    ).toBeNull();
  });

  it("breaks ties deterministically by ZONE_ORDER (power, strength, power-endurance, endurance)", () => {
    expect(
      dominantZone({ power: 2, strength: 2, "power-endurance": 0, endurance: 0 }),
    ).toBe("power");
    expect(
      dominantZone({ power: 0, strength: 2, "power-endurance": 2, endurance: 0 }),
    ).toBe("strength");
    expect(
      dominantZone({ power: 0, strength: 0, "power-endurance": 2, endurance: 2 }),
    ).toBe("power-endurance");
  });
});

const model = (cf: number | null, maxF: number): ForceCurveModel => ({
  points: [{ windowS: 5, kg: maxF }],
  maxF,
  cf,
  wPrime: cf === null ? null : 500,
});

describe("recommendZone (SL-100, #182)", () => {
  it("returns null with no training at all", () => {
    expect(
      recommendZone({ power: 0, strength: 0, "power-endurance": 0, endurance: 0 }, null),
    ).toBeNull();
  });

  it("picks the least-trained zone", () => {
    const r = recommendZone(
      { power: 3, strength: 2, "power-endurance": 1, endurance: 0 },
      null,
    );
    expect(r?.zone).toBe("endurance");
    expect(r?.reason).toContain("0 endurance sets");
  });

  it("with no bias, picks the true minimum among banded candidates, not the first in ZONE_ORDER", () => {
    // All four zones sit within the 0.5-set tie band of each other, so all
    // are candidates — but with no curve model to bias the pick, the result
    // must be the actual minimum (strength, 1.0), not `power` merely because
    // it's first in ZONE_ORDER.
    const r = recommendZone(
      { power: 1.2, strength: 1.0, "power-endurance": 1.4, endurance: 1.4 },
      null,
    );
    expect(r?.zone).toBe("strength");
    expect(r?.reason).toContain("1 strength set");
  });

  it("bias can pick a within-band zone that isn't the strict minimum", () => {
    // strength (1.0) is the true minimum; power-endurance (1.3) is within
    // the 0.5-set band and on the bias side, so a low CF ratio should still
    // steer the pick to power-endurance over the untied power/endurance.
    const r = recommendZone(
      { power: 3, strength: 1.0, "power-endurance": 1.3, endurance: 3 },
      model(20, 60), // CF 20 of 60 peak → 33% (<35%) → endurance side
    );
    expect(r?.zone).toBe("power-endurance");
  });

  it("breaks ties toward the endurance side when CF is a low fraction of peak", () => {
    // power & endurance tied at 0; CF 20 of 60 peak → 33% (<35%) → endurance
    const r = recommendZone(
      { power: 0, strength: 2, "power-endurance": 2, endurance: 0 },
      model(20, 60),
    );
    expect(r?.zone).toBe("endurance");
    expect(r?.reason).toContain("CF is 33% of peak");
  });

  it("breaks ties toward the strength side when CF is a high fraction of peak", () => {
    // power & endurance tied at 0; CF 45 of 60 → 75% (>35%) → power
    const r = recommendZone(
      { power: 0, strength: 2, "power-endurance": 2, endurance: 0 },
      model(45, 60),
    );
    expect(r?.zone).toBe("power");
  });
});

describe("recommendZone explanation payload (#214)", () => {
  it("reports the candidates and the minimum the pick came from", () => {
    const r = recommendZone(
      { power: 3, strength: 2, "power-endurance": 1, endurance: 0 },
      null,
    );
    expect(r?.detail.minSets).toBe(0);
    // Only endurance (0) is within 0.5 sets of the minimum.
    expect(r?.detail.tied).toEqual(["endurance"]);
    expect(r?.detail.unbiasedZone).toBe("endurance");
    expect(r?.detail.curveRatio).toBeNull();
    expect(r?.detail.curveBias).toBeNull();
    expect(r?.detail.biasChangedPick).toBe(false);
  });

  it("reports the curve ratio and which side it steers toward, and whether it moved the pick", () => {
    const r = recommendZone(
      { power: 0, strength: 2, "power-endurance": 2, endurance: 0 },
      model(20, 60), // CF 20 of 60 peak → 33% → endurance side
    );
    expect(r?.zone).toBe("endurance");
    expect(r?.detail.tied).toEqual(["power", "endurance"]);
    // Unbiased, the tie between two zeros resolves to power (first-seen
    // minimum); the curve is what moved it to endurance.
    expect(r?.detail.unbiasedZone).toBe("power");
    expect(r?.detail.curveRatio).toBeCloseTo(20 / 60, 5);
    expect(r?.detail.curveBias).toBe("endurance");
    expect(r?.detail.biasChangedPick).toBe(true);
  });

  it("says the curve did NOT move the pick when it agrees with the unbiased one", () => {
    const r = recommendZone(
      { power: 0, strength: 2, "power-endurance": 2, endurance: 0 },
      model(45, 60), // 75% → strength side; unbiased pick is already power
    );
    expect(r?.zone).toBe("power");
    expect(r?.detail.unbiasedZone).toBe("power");
    expect(r?.detail.curveBias).toBe("strength");
    expect(r?.detail.biasChangedPick).toBe(false);
  });

  it("puts the bias boundary exactly at CURVE_BIAS_RATIO", () => {
    // Ratio exactly 0.35 is NOT below the threshold → strength side.
    const at = recommendZone(
      { power: 0, strength: 2, "power-endurance": 2, endurance: 0 },
      model(CURVE_BIAS_RATIO * 60, 60),
    );
    expect(at?.detail.curveBias).toBe("strength");
    expect(TIE_BAND_SETS).toBe(0.5);
  });
});

describe("recommendZone picks the least-trained zone on the biased side", () => {
  it("prefers the lower of two in-band biased zones, not the first in ZONE_ORDER", () => {
    // power-endurance (0.8) is the true minimum, so an unbiased pick returns it.
    // power (1.2) and strength (0.9) are both within the 0.5 band AND both on
    // the strength side, so the bias must choose between them — and it must
    // choose strength, the lower. Picking `tied.find(...)` would return power
    // because ZONE_ORDER lists it first. Asserting "strength" therefore fails
    // for the unbiased pick ("power-endurance") and for the find-based pick
    // ("power") alike.
    const r = recommendZone(
      { power: 1.2, strength: 0.9, "power-endurance": 0.8, endurance: 5 },
      model(45, 60), // CF 45 of 60 → 75% (>35%) → strength side
    );
    expect(r?.zone).toBe("strength");
  });
});
