import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  predictSessionRpe,
  repDepletion,
  RPE_DEPLETION,
  rpeForDepletion,
  sessionDepletion,
  type DepletionRep,
} from "./rpeDepletion";

interface ParityRep {
  peakKg: number;
  durationS: number;
  cf: number | null;
  wPrime: number | null;
}

interface ParityFixture {
  tolerances: {
    load: number;
    rpe: number;
    mapping: number;
  };
  loadToRpe: { load: number; expectedRpe: number }[];
  sessions: {
    id: string;
    reps: ParityRep[];
    expectedLoad: number | null;
    expectedRpe: number;
    expectedFromCurve: boolean;
  }[];
}

// Resolve from this module rather than process.cwd(), so the focused test and
// the full Vitest run consume the same committed file from any launch path.
const PARITY_FIXTURE_URL = new URL(
  "../../ios/App/SendLogWatchCore/Tests/SendLogWatchCoreTests/Fixtures/rpe-depletion-parity.json",
  import.meta.url,
);
const parityFixture = JSON.parse(
  readFileSync(PARITY_FIXTURE_URL, "utf8"),
) as ParityFixture;

const fixtureSession = (id: string) => {
  const vector = parityFixture.sessions.find((candidate) => candidate.id === id);
  if (!vector) throw new Error(`Missing RPE parity session: ${id}`);
  return vector;
};

const rep = (
  peakKg: number,
  durationS: number,
  cf: number | null,
  wPrime: number | null,
  isEffort = true,
): DepletionRep => ({ peakKg, durationS, cf, wPrime, isEffort });

describe("repDepletion", () => {
  it("is exactly 1.0 for a rep taken to failure ON the curve", () => {
    const vector = fixtureSession("one-battery-on-curve");
    const fixtureRep = vector.reps[0];
    if (!fixtureRep || vector.expectedLoad === null) {
      throw new Error("Invalid one-battery RPE parity vector");
    }
    expect(
      Math.abs(
        (repDepletion({ ...fixtureRep, isEffort: true }) ?? Number.NaN) -
          vector.expectedLoad,
      ),
    ).toBeLessThanOrEqual(parityFixture.tolerances.load);
  });

  it("scales linearly in force above CF and in duration", () => {
    expect(repDepletion(rep(39, 10, 30, 180))).toBeCloseTo(0.5, 10);
    expect(repDepletion(rep(48, 5, 30, 180))).toBeCloseTo(0.5, 10);
  });

  it("contributes nothing at or below CF (the known limitation)", () => {
    expect(repDepletion(rep(30, 60, 30, 180))).toBe(0);
    expect(repDepletion(rep(25, 60, 30, 180))).toBe(0);
  });

  it("is null without a usable curve", () => {
    expect(repDepletion(rep(48, 10, null, null))).toBeNull();
    expect(repDepletion(rep(48, 10, 30, null))).toBeNull();
    expect(repDepletion(rep(48, 10, null, 180))).toBeNull();
    // Degenerate fit — nothing to divide by.
    expect(repDepletion(rep(48, 10, 30, 0))).toBeNull();
  });

  it("treats a negative duration as zero rather than negative depletion", () => {
    expect(repDepletion(rep(48, -5, 30, 180))).toBe(0);
  });

  // #338: a non-effort rep (Prehab) is submaximal BY CONSTRUCTION, so its
  // depletion is a KNOWN zero — not an absence — regardless of whether the
  // tag has a fitted curve. This is the regressed branch: before the fix,
  // no cf/wPrime meant `null` (unmeasured) even for a rep whose protocol
  // guarantees near-zero effort.
  it("is a measured 0 for a non-effort rep with no curve at all (#338)", () => {
    expect(repDepletion(rep(48, 10, null, null, false))).toBe(0);
  });

  it("is 0 for a non-effort rep even when a curve exists and peakKg sits above cf (#338)", () => {
    expect(repDepletion(rep(48, 10, 30, 180, false))).toBe(0);
  });
});

describe("sessionDepletion", () => {
  it("sums each rep against ITS OWN tag's curve", () => {
    const load = sessionDepletion([
      rep(48, 10, 30, 180), // 1.0
      rep(30, 5, 20, 100), // 0.5
    ]);
    expect(load).toBeCloseTo(1.5, 10);
  });

  it("skips reps whose tag has no curve, keeping the ones that do", () => {
    const load = sessionDepletion([
      rep(48, 10, 30, 180), // 1.0
      rep(60, 30, null, null), // no curve — contributes nothing
    ]);
    expect(load).toBeCloseTo(1, 10);
  });

  it("is null (not 0) when NO rep had a curve", () => {
    expect(sessionDepletion([rep(48, 10, null, null)])).toBeNull();
    expect(sessionDepletion([])).toBeNull();
  });
});

describe("rpeForDepletion", () => {
  it("matches the published table, rounded to 0.1", () => {
    for (const { load, expectedRpe } of parityFixture.loadToRpe) {
      expect(Math.abs(rpeForDepletion(load) - expectedRpe)).toBeLessThanOrEqual(
        parityFixture.tolerances.mapping,
      );
    }
  });

  it("stays inside [1, 10] however deep the hole", () => {
    expect(rpeForDepletion(1000)).toBe(10);
    expect(rpeForDepletion(0)).toBe(1);
    expect(rpeForDepletion(-5)).toBe(1);
  });
});

describe("predictSessionRpe", () => {
  it.each(parityFixture.sessions)("matches shared vector: $id", (vector) => {
    const p = predictSessionRpe(
      vector.reps.map((value) => ({ ...value, isEffort: true })),
    );
    if (vector.expectedLoad === null) {
      expect(p.load).toBeNull();
    } else {
      expect(
        Math.abs((p.load ?? Number.NaN) - vector.expectedLoad),
      ).toBeLessThanOrEqual(parityFixture.tolerances.load);
    }
    expect(Math.abs(p.rpe - vector.expectedRpe)).toBeLessThanOrEqual(
      parityFixture.tolerances.rpe,
    );
    expect(p.fromCurve).toBe(vector.expectedFromCurve);
  });

  it("keeps the fixture fallback synchronized with the model tunable", () => {
    for (const vector of parityFixture.sessions.filter(
      ({ expectedFromCurve }) => !expectedFromCurve,
    )) {
      expect(vector.expectedRpe).toBe(RPE_DEPLETION.fallbackRpe);
    }
  });

  // #338 — acceptance criterion 4 (non-Prehab behaviour unchanged): an
  // ordinary (effort) hold on a tag with no CF fit still falls back to
  // fallbackRpe. Explicit `isEffort: true` so this pins the branch by name,
  // not by relying on the helper's default.
  it("an ordinary effort hold with no CF fit still falls back (#338)", () => {
    const p = predictSessionRpe([rep(48, 10, null, null, true)]);
    expect(p).toEqual({
      rpe: RPE_DEPLETION.fallbackRpe,
      fromCurve: false,
      load: null,
    });
  });

  // #338 — core acceptance criterion: a Prehab session logs the SAME
  // zero-depletion RPE whether or not its tag has a fitted CF curve. Before
  // the fix, the unfitted case fell all the way through to fallbackRpe (5)
  // instead of the RPE-1 the fitted case already (correctly) produced.
  it("a Prehab-shaped session predicts the same RPE whether or not its tag has a CF fit (#338)", () => {
    const prehabReps = (cf: number | null, wPrime: number | null) =>
      [
        rep(21, 30, cf, wPrime, false),
        rep(20, 30, cf, wPrime, false),
        rep(22, 30, cf, wPrime, false),
        rep(21, 30, cf, wPrime, false),
      ];
    const fitted = predictSessionRpe(prehabReps(30, 180)); // tag HAS a CF fit
    const unfitted = predictSessionRpe(prehabReps(null, null)); // tag has NO CF fit
    const expected = { rpe: 1, fromCurve: true, load: 0 };
    expect(fitted).toEqual(expected);
    expect(unfitted).toEqual(expected);
  });
});
