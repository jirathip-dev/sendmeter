import { describe, it, expect } from "vitest";
import type { LiveWorkoutMessage } from "sendlog-auth-bridge";
import type { LiveWorkout } from "../types";
import {
  STALE_MS,
  WC_PLACEHOLDER_ID,
  appendHrPoint,
  messageToLive,
  preferFresher,
  rowToLive,
  visibleLiveWorkout,
  type HrLog,
} from "./liveWorkoutMirror";

const T0 = "2026-07-16T10:00:00.000Z";
const T1 = "2026-07-16T10:00:05.000Z";
const T2 = "2026-07-16T10:00:10.000Z";

function row(overrides: Partial<LiveWorkout> = {}): LiveWorkout {
  return {
    workoutId: "w1",
    status: "live",
    startedAt: T0,
    hr: 120,
    attemptCount: 1,
    activeKcal: null,
    elevationGainM: null,
    climbing: true,
    climbingSince: T0,
    restStartedAt: null,
    restTargetS: null,
    updatedAt: T1,
    ...overrides,
  };
}

describe("preferFresher", () => {
  it("incoming wins when strictly newer", () => {
    const prev = row({ updatedAt: T0 });
    const incoming = row({ updatedAt: T1 });
    expect(preferFresher(prev, incoming)).toBe(incoming);
  });

  it("prev wins when strictly newer than incoming", () => {
    const prev = row({ updatedAt: T2 });
    const incoming = row({ updatedAt: T0 });
    expect(preferFresher(prev, incoming)).toBe(prev);
  });

  it("incoming wins on an equal timestamp", () => {
    const prev = row({ updatedAt: T1 });
    const incoming = row({ updatedAt: T1, hr: 999 });
    expect(preferFresher(prev, incoming)).toBe(incoming);
  });

  it("incoming wins when prev is null", () => {
    const incoming = row();
    expect(preferFresher(null, incoming)).toBe(incoming);
  });
});

describe("messageToLive", () => {
  const msg: LiveWorkoutMessage = {
    status: "live",
    started_at: Date.parse(T0) / 1000,
    hr: 130,
    attempt_count: 2,
    active_kcal: 40,
    elevation_gain_m: 5,
    climbing: true,
    climbing_since: Date.parse(T1) / 1000,
    rest_started_at: undefined,
    rest_target_s: 60,
    updated_at: Date.parse(T2) / 1000,
  };

  it("converts epoch-seconds fields to ISO strings", () => {
    const live = messageToLive(msg, null);
    expect(live.startedAt).toBe(T0);
    expect(live.climbingSince).toBe(T1);
    expect(live.updatedAt).toBe(T2);
    expect(live.restStartedAt).toBeNull();
  });

  it("uses the wc placeholder id when there is no previous row", () => {
    expect(messageToLive(msg, null).workoutId).toBe(WC_PLACEHOLDER_ID);
  });

  it("keeps the previous row's workout id", () => {
    const prev = row({ workoutId: "real-id" });
    expect(messageToLive(msg, prev).workoutId).toBe("real-id");
  });

  it("falls back to prev.startedAt and now() when started_at is absent", () => {
    const rest: LiveWorkoutMessage = { ...msg, started_at: undefined };
    const prev = row({ startedAt: T0 });
    const live = messageToLive(rest, prev);
    expect(live.startedAt).toBe(T0);

    const liveNoPrev = messageToLive(rest, null);
    expect(typeof liveNoPrev.startedAt).toBe("string");
  });

  it("defaults attemptCount to 0 when absent", () => {
    const rest: LiveWorkoutMessage = { ...msg, attempt_count: undefined };
    expect(messageToLive(rest, null).attemptCount).toBe(0);
  });
});

describe("rowToLive", () => {
  it("maps a raw postgres row into a LiveWorkout", () => {
    const raw = {
      workout_id: "w9",
      status: "live",
      started_at: T0,
      hr: 140,
      attempt_count: 3,
      active_kcal: null,
      elevation_gain_m: null,
      climbing: false,
      climbing_since: null,
      rest_started_at: T1,
      rest_target_s: 90,
      updated_at: T2,
    };
    expect(rowToLive(raw)).toEqual({
      workoutId: "w9",
      status: "live",
      startedAt: T0,
      hr: 140,
      attemptCount: 3,
      activeKcal: null,
      elevationGainM: null,
      climbing: false,
      climbingSince: null,
      restStartedAt: T1,
      restTargetS: 90,
      updatedAt: T2,
    });
  });
});

describe("appendHrPoint", () => {
  it("appends points in order for the same workout", () => {
    let log: HrLog = { id: "w1", pts: [] };
    log = appendHrPoint(log, row({ updatedAt: T0, hr: 100 }));
    log = appendHrPoint(log, row({ updatedAt: T1, hr: 110 }));
    expect(log.pts).toEqual([
      { t: Date.parse(T0), hr: 100 },
      { t: Date.parse(T1), hr: 110 },
    ]);
  });

  it("drops a duplicate beat (same timestamp)", () => {
    let log: HrLog = { id: "w1", pts: [] };
    log = appendHrPoint(log, row({ updatedAt: T1, hr: 100 }));
    const after = appendHrPoint(log, row({ updatedAt: T1, hr: 105 }));
    expect(after).toBe(log);
  });

  it("drops an out-of-order beat (older than the last point)", () => {
    let log: HrLog = { id: "w1", pts: [] };
    log = appendHrPoint(log, row({ updatedAt: T2, hr: 100 }));
    const after = appendHrPoint(log, row({ updatedAt: T1, hr: 105 }));
    expect(after).toBe(log);
  });

  it("skips a non-live status", () => {
    const log: HrLog = { id: "w1", pts: [] };
    const after = appendHrPoint(log, row({ status: "ended", updatedAt: T1 }));
    expect(after).toBe(log);
  });

  it("skips a null hr", () => {
    const log: HrLog = { id: "w1", pts: [] };
    const after = appendHrPoint(log, row({ hr: null, updatedAt: T1 }));
    expect(after).toBe(log);
  });

  it("a genuinely new real workout id resets the series", () => {
    let log: HrLog = { id: "w1", pts: [] };
    log = appendHrPoint(log, row({ workoutId: "w1", updatedAt: T0, hr: 100 }));
    log = appendHrPoint(log, row({ workoutId: "w2", updatedAt: T1, hr: 120 }));
    expect(log).toEqual({ id: "w2", pts: [{ t: Date.parse(T1), hr: 120 }] });
  });

  it("a wc-placeholder -> real id transition preserves the accumulated series", () => {
    let log: HrLog = { id: "", pts: [] };
    log = appendHrPoint(
      log,
      row({ workoutId: WC_PLACEHOLDER_ID, updatedAt: T0, hr: 90 }),
    );
    log = appendHrPoint(
      log,
      row({ workoutId: WC_PLACEHOLDER_ID, updatedAt: T1, hr: 95 }),
    );
    expect(log.pts).toHaveLength(2);

    const afterRealRow = appendHrPoint(
      log,
      row({ workoutId: "real-id", updatedAt: T2, hr: 100 }),
    );
    expect(afterRealRow).toEqual({
      id: "real-id",
      pts: [
        { t: Date.parse(T0), hr: 90 },
        { t: Date.parse(T1), hr: 95 },
        { t: Date.parse(T2), hr: 100 },
      ],
    });
  });
});

describe("visibleLiveWorkout", () => {
  it("hides a null row", () => {
    expect(visibleLiveWorkout(null, { id: "", pts: [] }, Date.now())).toEqual([
      null,
      [],
    ]);
  });

  it("hides an ended row", () => {
    const r = row({ status: "ended" });
    expect(visibleLiveWorkout(r, { id: "", pts: [] }, Date.now())).toEqual([
      null,
      [],
    ]);
  });

  it("hides a row whose heartbeat is older than the stale cutoff", () => {
    const r = row({ updatedAt: T0 });
    const now = Date.parse(T0) + STALE_MS + 1;
    expect(visibleLiveWorkout(r, { id: r.workoutId, pts: [] }, now)).toEqual([
      null,
      [],
    ]);
  });

  it("shows a row exactly at the stale boundary", () => {
    const r = row({ updatedAt: T0 });
    const now = Date.parse(T0) + STALE_MS;
    const [visible] = visibleLiveWorkout(r, { id: r.workoutId, pts: [] }, now);
    expect(visible).toBe(r);
  });

  it("hides the HR series when it belongs to a different workout id", () => {
    const r = row({ workoutId: "w1", updatedAt: T0 });
    const pts = [{ t: Date.parse(T0), hr: 100 }];
    const [visible, series] = visibleLiveWorkout(
      r,
      { id: "w-old", pts },
      Date.parse(T0),
    );
    expect(visible).toBe(r);
    expect(series).toEqual([]);
  });

  it("shows the HR series when it belongs to the visible row", () => {
    const r = row({ workoutId: "w1", updatedAt: T0 });
    const pts = [{ t: Date.parse(T0), hr: 100 }];
    const [, series] = visibleLiveWorkout(r, { id: "w1", pts }, Date.parse(T0));
    expect(series).toBe(pts);
  });
});
