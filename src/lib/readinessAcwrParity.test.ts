import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  ACUTE_SPAN_DAYS,
  CHRONIC_SPAN_DAYS,
  computeAcwr,
  ewmaLoadState,
  getACWRStatus,
  suggestPhaseStepBack,
} from "./metrics";
import { ZONE_COLORS } from "./readinessZones";
import { daysAgo, today } from "./dates";
import type { Session } from "../types";

/// Cross-pinning fixture for the readiness/ACWR math that is implemented in
/// four codebases (web src/lib, native-plugins/sendlog-health-core,
/// ios/App/SendLogWatchCore, native/SendmeterNative). The canonical file lives
/// in the watch's test Fixtures (the same home as
/// rpe-depletion-parity.json); byte-identical copies live in the other two
/// Swift packages' Fixtures. Every suite reads the SAME bytes and asserts the
/// inputs -> expected vectors below, so a silent drift in any implementation
/// fails its own suite instead of shipping as a quiet 1.54-vs-1.37.
const REPO = join(import.meta.dirname, "..", "..");

const CANONICAL_FIXTURE = join(
  REPO,
  "ios", "App", "SendLogWatchCore", "Tests", "SendLogWatchCoreTests",
  "Fixtures", "readiness-acwr-parity.json",
);

/// The other two Swift packages bundle their own byte-identical copy (SwiftPM
/// `resources:` requires the file inside the package). This test pins all
/// three to the canonical bytes so a copy can never silently diverge — the
/// same KEEP-IN-SYNC discipline as iosKeepInSyncInvariants.test.ts.
const SWIFT_COPIES = [
  join(
    REPO,
    "native-plugins", "sendlog-health-core", "Tests", "SendLogHealthCoreTests",
    "Fixtures", "readiness-acwr-parity.json",
  ),
  join(
    REPO,
    "native", "SendmeterNative", "Tests", "SendmeterCoreTests",
    "Fixtures", "readiness-acwr-parity.json",
  ),
];

interface AcwrStatusVector {
  id: string;
  ratio: number | null;
  status: string;
}
interface AcwrRatioVector {
  id: string;
  dailyLoads: number[];
  expected: number | null;
}
interface ReadinessVector {
  id: string;
  inputs: Record<string, unknown>;
  acwr: number | null;
  expectedScore: number | null;
  expectedZone: string | null;
}
interface ParityFixture {
  spans: {
    acuteDays: number;
    chronicDays: number;
    lookbackDays: number;
    readinessRecoverBelow: number;
    readinessPushAbove: number;
  };
  acwrStatus: AcwrStatusVector[];
  acwrRatio: AcwrRatioVector[];
  readiness: ReadinessVector[];
}

const canonical = JSON.parse(
  readFileSync(CANONICAL_FIXTURE, "utf8"),
) as ParityFixture;

function session(date: string, load: number): Session {
  return {
    id: `s-${date}-${load}`,
    date,
    type: "board",
    typeLabel: "Board",
    duration: 60,
    rpe: 5,
    rpeConfirmed: true,
    load,
    note: "",
    phase: "capacity",
    groupId: null,
    workoutSource: null,
  };
}

/// Maps a fixture dailyLoads series (oldest -> newest) onto Session rows the
/// web's computeAcwr/ewmaLoadState can consume. `computeAcwr` always looks
/// back a fixed 90 days via `daysAgo`, so non-90-length vectors that are
/// meant to fill the window (empty/all-zero) are handled by the
/// `fill` flag — a naive length mismatch would silently shift which day each
/// load lands on.
function sessionsFromDailyLoads(series: number[], fill: boolean): Session[] {
  if (fill) {
    const padded: number[] = [];
    for (let i = 0; i < 90 - series.length; i++) padded.push(0);
    series = padded.concat(series);
  }
  return series.map((load, i) =>
    session(daysAgo(series.length - 1 - i), load),
  );
}

describe("readiness/ACWR parity fixture (web)", () => {
  it("pins the 7/28-day EWMA spans the ratio is built from", () => {
    expect(ACUTE_SPAN_DAYS).toBe(canonical.spans.acuteDays);
    expect(CHRONIC_SPAN_DAYS).toBe(canonical.spans.chronicDays);
  });

  it("classifies every ACWR status vector at the 0.7/0.8/1.3/1.5 boundaries", () => {
    for (const v of canonical.acwrStatus) {
      expect(getACWRStatus(v.ratio).label, v.id).toBe(
        v.status === "noData"
          ? "No data"
          : v.status === "underTraining"
            ? "Under-training"
            : v.status === "low"
              ? "Low"
              : v.status === "optimal"
                ? "Optimal"
                : v.status === "caution"
                  ? "Caution"
                  : "Danger",
      );
    }
  });

  it("computes the same ACWR EWMA ratio as the shared fixture (incl. warm-up window)", () => {
    for (const v of canonical.acwrRatio) {
      // Vectors come pre-padded to the 90-day window except the explicit
      // empty vector; computeAcwr derives its acute/chronic sums from the
      // same lookup so we only assert the EWMA ratio here.
      const sessions = sessionsFromDailyLoads(v.dailyLoads, v.dailyLoads.length !== 0);
      const r = computeAcwr(sessions);
      if (v.expected === null) {
        expect(r.acwr, v.id).toBeNull();
      } else {
        expect(r.acwr, v.id).not.toBeNull();
        expect(r.acwr!, v.id).toBeCloseTo(v.expected, 9);
      }
      // ewmaLoadState's acute/chronic pair is the SAME ratio — not a second
      // opinion (issue #189 guard).
      const state = ewmaLoadState(sessions);
      if (v.expected === null) {
        expect(state, v.id).toBeNull();
      } else {
        expect(state, v.id).not.toBeNull();
        expect(state!.acute / state!.chronic, v.id).toBeCloseTo(v.expected, 9);
      }
    }
  });

  it("maps each readiness zone to the shared color (consumed by every surface)", () => {
    for (const v of canonical.readiness) {
      // A nil zone (empty-data readiness) has no color mapping — the web
      // renders "No data" separately; every real zone must tint consistently.
      if (!v.expectedZone) continue;
      expect(ZONE_COLORS[v.expectedZone], v.id).toBe(
        v.expectedZone === "push"
          ? "var(--success)"
          : v.expectedZone === "maintain"
            ? "var(--warning)"
            : "var(--danger)",
      );
    }
  });

  it("treats the recover boundary as exclusive (score == recoverBelow is not low)", () => {
    // Pin the web's LOW_READINESS_THRESHOLD (=40, kept in sync with
    // RecoveryTunables.zoneRecoverBelow) against the fixture's recover
    // boundary. Exactly 40 is not below it, so no step-back suggestion.
    const history = [
      { date: today(), readiness: canonical.spans.readinessRecoverBelow },
      { date: daysAgo(1), readiness: canonical.spans.readinessRecoverBelow },
      { date: daysAgo(2), readiness: canonical.spans.readinessRecoverBelow },
    ];
    expect(suggestPhaseStepBack(history, "power")).toEqual({
      suggested: false,
      streakDays: 0,
    });
  });

  it("keeps all three Swift copies byte-identical to the canonical fixture", () => {
    const canonicalBytes = readFileSync(CANONICAL_FIXTURE, "utf8");
    for (const copy of SWIFT_COPIES) {
      expect(readFileSync(copy, "utf8"), copy).toBe(canonicalBytes);
    }
  });
});
