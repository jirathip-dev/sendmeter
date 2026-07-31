import {
  computeForceCurve,
  pickCurveRecordings,
  type ForceCurveModel,
} from "./force-curve";
import { predictSessionRpe } from "./rpeDepletion";
import { curveCandidateRecordings, isEffortRecording } from "./zoneHistory";
import type { RecordedZone } from "./force-curve";
import type { TindeqSample, TindeqSide } from "../types";

/**
 * Read-only chronological backtest for issue #322.
 *
 * This deliberately calls the production curve picker, fitter and RPE model
 * instead of copying their equations. It models the persisted all-sides curve
 * that the phone/watch use: a session is predicted from the curves available
 * BEFORE its recordings, then those recordings may refit their tags. A failed
 * refit leaves the previous persisted curve intact, matching ForceView.
 */

export interface RpeStabilityRecording {
  id: string;
  userId: string;
  recordedAt: string;
  durationMs: number;
  peakKg: number;
  avgKg: number;
  tag: string;
  side: TindeqSide;
  groupId: string | null;
  zone: RecordedZone | null;
  samples: TindeqSample[];
}

export interface RpeStabilitySession {
  id: string;
  userId: string;
  groupId: string;
  type: string;
  rpe: number;
  rpeConfirmed: boolean;
}

interface CurveEvidence {
  pickedRecordings: number;
  distinctLongWindows: number;
  longestEffortS: number;
}

export interface RpeStabilitySessionResult {
  sessionId: string;
  storedRpe: number;
  rpeConfirmed: boolean;
  baselineRpe: number;
  effortReps: number;
  measuredEffortReps: number;
  fullyMeasuredAtBaseline: boolean;
  relevantRefits: number;
  latestRpe: number;
  latestAbsDelta: number;
  maximumAbsDelta: number;
  latestWPrimeOnlyAbsDelta: number;
  maximumWPrimeOnlyAbsDelta: number;
  latestCfOnlyAbsDelta: number;
  maximumCfOnlyAbsDelta: number;
  /// Bottleneck evidence across the tags used by this session.
  pickedRecordings: number | null;
  distinctLongWindows: number | null;
  longestEffortS: number | null;
}

export interface DriftStats {
  count: number;
  median: number | null;
  p90: number | null;
  overHalfPoint: { count: number; pct: number };
  overOnePoint: { count: number; pct: number };
}

export interface RpeStabilityStratum {
  label: string;
  maximumDrift: DriftStats;
}

export interface RpeStabilityReport {
  totalMatchedSessions: number;
  sessionsWithEffort: number;
  fullyMeasuredAtBaseline: number;
  notFullyMeasuredAtBaseline: number;
  sessionsWithRelevantRefit: number;
  maximumDrift: DriftStats;
  latestDrift: DriftStats;
  maximumWPrimeOnlyDrift: DriftStats;
  maximumCfOnlyDrift: DriftStats;
  byLongestEffort: RpeStabilityStratum[];
  byDistinctLongWindows: RpeStabilityStratum[];
  byReviewStatus: RpeStabilityStratum[];
  sessions: RpeStabilitySessionResult[];
}

interface PredictionCoverage {
  rpe: number;
  effortReps: number;
  measuredEffortReps: number;
  fullyMeasured: boolean;
}

interface TrackedSession {
  recordings: RpeStabilityRecording[];
  tags: Set<string>;
  baselineCurves: Map<string, ForceCurveModel>;
  result: RpeStabilitySessionResult;
}

function prediction(
  recordings: RpeStabilityRecording[],
  curves: Map<string, ForceCurveModel>,
): PredictionCoverage {
  let effortReps = 0;
  let measuredEffortReps = 0;
  const reps = recordings.map((recording) => {
    const isEffort = isEffortRecording(recording);
    const curve = curves.get(recording.tag);
    if (isEffort) {
      effortReps++;
      if (curve?.cf != null && curve.wPrime != null && curve.wPrime > 0) {
        measuredEffortReps++;
      }
    }
    return {
      peakKg: recording.peakKg,
      durationS: recording.durationMs / 1000,
      cf: curve?.cf ?? null,
      wPrime: curve?.wPrime ?? null,
      isEffort,
    };
  });
  return {
    rpe: predictSessionRpe(reps).rpe,
    effortReps,
    measuredEffortReps,
    fullyMeasured: effortReps > 0 && measuredEffortReps === effortReps,
  };
}

function refitTag(
  tag: string,
  recordings: RpeStabilityRecording[],
  nowMs: number,
): { model: ForceCurveModel; evidence: CurveEvidence } | null {
  const candidates = curveCandidateRecordings(recordings, tag, null);
  const picked = pickCurveRecordings(candidates, nowMs);
  const model = computeForceCurve(picked.map((recording) => recording.samples));
  if (model?.cf == null || model.wPrime == null || model.wPrime <= 0) return null;
  return {
    model,
    evidence: {
      pickedRecordings: picked.length,
      distinctLongWindows: model.points.filter((point) => point.windowS >= 10).length,
      longestEffortS: picked.reduce(
        (longest, recording) => Math.max(longest, recording.durationMs / 1000),
        0,
      ),
    },
  };
}

function eventTime(recordings: RpeStabilityRecording[]): number {
  const times = recordings.map((recording) => Date.parse(recording.recordedAt));
  if (times.some((time) => !Number.isFinite(time))) {
    throw new Error("RPE stability input contains an invalid recordedAt timestamp.");
  }
  return Math.max(...times);
}

function roundedDelta(a: number, b: number): number {
  return Math.round(Math.abs(a - b) * 10) / 10;
}

function counterfactualCurves(
  tags: Set<string>,
  baseline: Map<string, ForceCurveModel>,
  current: Map<string, ForceCurveModel>,
  varying: "cf" | "wPrime",
): Map<string, ForceCurveModel> {
  const result = new Map<string, ForceCurveModel>();
  for (const tag of tags) {
    const before = baseline.get(tag);
    const after = current.get(tag);
    if (!before || !after) continue;
    result.set(tag, {
      ...before,
      cf: varying === "cf" ? after.cf : before.cf,
      wPrime: varying === "wPrime" ? after.wPrime : before.wPrime,
    });
  }
  return result;
}

function quantile(values: number[], q: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const position = (sorted.length - 1) * q;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  const value =
    lower === upper
      ? sorted[lower]!
      : sorted[lower]! + (sorted[upper]! - sorted[lower]!) * (position - lower);
  return Math.round(value * 100) / 100;
}

export function driftStats(values: number[]): DriftStats {
  const count = values.length;
  const overHalfPoint = values.filter((value) => value > 0.5).length;
  const overOnePoint = values.filter((value) => value > 1).length;
  const pct = (n: number) => (count === 0 ? 0 : Math.round((n / count) * 1000) / 10);
  return {
    count,
    median: quantile(values, 0.5),
    p90: quantile(values, 0.9),
    overHalfPoint: { count: overHalfPoint, pct: pct(overHalfPoint) },
    overOnePoint: { count: overOnePoint, pct: pct(overOnePoint) },
  };
}

function strata(
  sessions: RpeStabilitySessionResult[],
  definitions: { label: string; includes: (session: RpeStabilitySessionResult) => boolean }[],
): RpeStabilityStratum[] {
  return definitions.map(({ label, includes }) => ({
    label,
    maximumDrift: driftStats(
      sessions.filter(includes).map((session) => session.maximumAbsDelta),
    ),
  }));
}

export function analyzeRpeStability(input: {
  recordings: RpeStabilityRecording[];
  sessions: RpeStabilitySession[];
}): RpeStabilityReport {
  const sessionByGroup = new Map(
    input.sessions
      .filter((session) => session.type === "tindeq")
      .map((session) => [`${session.userId}|${session.groupId}`, session]),
  );
  const recordingsByUser = new Map<string, RpeStabilityRecording[]>();
  for (const recording of input.recordings) {
    const list = recordingsByUser.get(recording.userId);
    if (list) list.push(recording);
    else recordingsByUser.set(recording.userId, [recording]);
  }

  const results: RpeStabilitySessionResult[] = [];
  for (const [userId, userRecordings] of recordingsByUser) {
    const byEvent = new Map<string, RpeStabilityRecording[]>();
    for (const recording of userRecordings) {
      const eventKey = recording.groupId
        ? `group:${recording.groupId}`
        : `recording:${recording.id}`;
      const list = byEvent.get(eventKey);
      if (list) list.push(recording);
      else byEvent.set(eventKey, [recording]);
    }
    const events = [...byEvent.entries()]
      .map(([key, recordings]) => ({ key, recordings, at: eventTime(recordings) }))
      .sort((a, b) => a.at - b.at || a.key.localeCompare(b.key));

    const priorRecordings: RpeStabilityRecording[] = [];
    const curves = new Map<string, ForceCurveModel>();
    const curveEvidence = new Map<string, CurveEvidence>();
    const tracked: TrackedSession[] = [];

    for (const event of events) {
      const groupId = event.key.startsWith("group:") ? event.key.slice(6) : null;
      const session = groupId ? sessionByGroup.get(`${userId}|${groupId}`) : undefined;
      if (session) {
        const baseline = prediction(event.recordings, curves);
        const tags = new Set(
          event.recordings
            .filter(isEffortRecording)
            .map((recording) => recording.tag),
        );
        const evidence = [...tags].map((tag) => curveEvidence.get(tag));
        const completeEvidence = evidence.length > 0 && evidence.every(Boolean);
        const result: RpeStabilitySessionResult = {
          sessionId: session.id,
          storedRpe: session.rpe,
          rpeConfirmed: session.rpeConfirmed,
          baselineRpe: baseline.rpe,
          effortReps: baseline.effortReps,
          measuredEffortReps: baseline.measuredEffortReps,
          fullyMeasuredAtBaseline: baseline.fullyMeasured,
          relevantRefits: 0,
          latestRpe: baseline.rpe,
          latestAbsDelta: 0,
          maximumAbsDelta: 0,
          latestWPrimeOnlyAbsDelta: 0,
          maximumWPrimeOnlyAbsDelta: 0,
          latestCfOnlyAbsDelta: 0,
          maximumCfOnlyAbsDelta: 0,
          pickedRecordings: completeEvidence
            ? Math.min(...evidence.map((item) => item!.pickedRecordings))
            : null,
          distinctLongWindows: completeEvidence
            ? Math.min(...evidence.map((item) => item!.distinctLongWindows))
            : null,
          longestEffortS: completeEvidence
            ? Math.min(...evidence.map((item) => item!.longestEffortS))
            : null,
        };
        results.push(result);
        tracked.push({
          recordings: event.recordings,
          tags,
          baselineCurves: new Map(
            [...tags]
              .map((tag) => [tag, curves.get(tag)] as const)
              .filter((entry): entry is readonly [string, ForceCurveModel] => Boolean(entry[1])),
          ),
          result,
        });
      }

      priorRecordings.push(...event.recordings);
      const changedTags = new Set(
        event.recordings
          .filter(isEffortRecording)
          .map((recording) => recording.tag),
      );
      const successfulRefits = new Set<string>();
      for (const tag of changedTags) {
        const fitted = refitTag(tag, priorRecordings, event.at);
        // Production only persists usable fits; an unusable recompute does
        // not erase the last good registry value.
        if (!fitted) continue;
        curves.set(tag, fitted.model);
        curveEvidence.set(tag, fitted.evidence);
        successfulRefits.add(tag);
      }

      if (successfulRefits.size === 0) continue;
      for (const item of tracked) {
        if (!item.result.fullyMeasuredAtBaseline) continue;
        if (![...item.tags].some((tag) => successfulRefits.has(tag))) continue;
        const updated = prediction(item.recordings, curves);
        if (!updated.fullyMeasured) continue;
        const delta = roundedDelta(updated.rpe, item.result.baselineRpe);
        const wPrimeOnly = prediction(
          item.recordings,
          counterfactualCurves(item.tags, item.baselineCurves, curves, "wPrime"),
        );
        const cfOnly = prediction(
          item.recordings,
          counterfactualCurves(item.tags, item.baselineCurves, curves, "cf"),
        );
        if (!wPrimeOnly.fullyMeasured || !cfOnly.fullyMeasured) continue;
        const wPrimeDelta = roundedDelta(wPrimeOnly.rpe, item.result.baselineRpe);
        const cfDelta = roundedDelta(cfOnly.rpe, item.result.baselineRpe);
        item.result.relevantRefits++;
        item.result.latestRpe = updated.rpe;
        item.result.latestAbsDelta = delta;
        item.result.maximumAbsDelta = Math.max(item.result.maximumAbsDelta, delta);
        item.result.latestWPrimeOnlyAbsDelta = wPrimeDelta;
        item.result.maximumWPrimeOnlyAbsDelta = Math.max(
          item.result.maximumWPrimeOnlyAbsDelta,
          wPrimeDelta,
        );
        item.result.latestCfOnlyAbsDelta = cfDelta;
        item.result.maximumCfOnlyAbsDelta = Math.max(
          item.result.maximumCfOnlyAbsDelta,
          cfDelta,
        );
      }
    }
  }

  const withEffort = results.filter((session) => session.effortReps > 0);
  const measured = withEffort.filter((session) => session.fullyMeasuredAtBaseline);
  const evaluated = measured.filter((session) => session.relevantRefits > 0);
  return {
    totalMatchedSessions: results.length,
    sessionsWithEffort: withEffort.length,
    fullyMeasuredAtBaseline: measured.length,
    notFullyMeasuredAtBaseline: withEffort.filter(
      (session) => !session.fullyMeasuredAtBaseline,
    ).length,
    sessionsWithRelevantRefit: evaluated.length,
    maximumDrift: driftStats(evaluated.map((session) => session.maximumAbsDelta)),
    latestDrift: driftStats(evaluated.map((session) => session.latestAbsDelta)),
    maximumWPrimeOnlyDrift: driftStats(
      evaluated.map((session) => session.maximumWPrimeOnlyAbsDelta),
    ),
    maximumCfOnlyDrift: driftStats(
      evaluated.map((session) => session.maximumCfOnlyAbsDelta),
    ),
    byLongestEffort: strata(evaluated, [
      { label: "<30s", includes: (session) => (session.longestEffortS ?? Infinity) < 30 },
      {
        label: "30–59s",
        includes: (session) =>
          (session.longestEffortS ?? -Infinity) >= 30 &&
          (session.longestEffortS ?? Infinity) < 60,
      },
      { label: "60s+", includes: (session) => (session.longestEffortS ?? -Infinity) >= 60 },
    ]),
    byDistinctLongWindows: strata(evaluated, [
      {
        label: "3 windows",
        includes: (session) => session.distinctLongWindows === 3,
      },
      {
        label: "4–5 windows",
        includes: (session) =>
          (session.distinctLongWindows ?? -Infinity) >= 4 &&
          (session.distinctLongWindows ?? Infinity) <= 5,
      },
      {
        label: "6+ windows",
        includes: (session) => (session.distinctLongWindows ?? -Infinity) >= 6,
      },
    ]),
    byReviewStatus: strata(evaluated, [
      { label: "unconfirmed", includes: (session) => !session.rpeConfirmed },
      { label: "confirmed", includes: (session) => session.rpeConfirmed },
    ]),
    sessions: results,
  };
}
