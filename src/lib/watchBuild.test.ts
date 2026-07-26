import { describe, expect, it } from "vitest";
import {
  watchBuildLine,
  watchSyncLine,
  type WatchBuildInfo,
  type WatchBuildStatus,
  type WatchSyncStatus,
} from "./watchBuild";

function info(status: WatchBuildStatus, over: Partial<WatchBuildInfo> = {}): WatchBuildInfo {
  return {
    status,
    supported: true,
    activated: true,
    paired: true,
    appInstalled: true,
    phoneDisplay: "1.4.0 (57)",
    ...over,
  };
}

describe("watchBuildLine", () => {
  it("renders nothing without info (web)", () => {
    expect(watchBuildLine(null)).toBeNull();
  });

  it("shows the reported build and calls a match a match", () => {
    const line = watchBuildLine(
      info("match", { watchDisplay: "1.4.0 (57)", watchBuild: "57", reportedAt: 1_780_000_000 }),
    );
    expect(line).toEqual({
      text: "Watch 1.4.0 (57) · same build as this iPhone",
      tone: "muted",
      reportedAt: 1_780_000_000,
    });
  });

  it("flags a lagging watch as the actionable state", () => {
    // The whole point of #228: this is the case that silently revokes the
    // session family, so it must not read as muted background detail.
    const line = watchBuildLine(info("watch-behind", { watchDisplay: "1.3.0 (51)" }));
    expect(line?.text).toBe("Watch 1.3.0 (51) · behind this iPhone");
    expect(line?.tone).toBe("warning");
  });

  it("flags an ahead or unorderable difference too", () => {
    expect(watchBuildLine(info("watch-ahead", { watchDisplay: "1.5.0 (60)" }))?.tone).toBe(
      "warning",
    );
    expect(watchBuildLine(info("differs", { watchDisplay: "1.4.0 (local)" }))?.tone).toBe(
      "warning",
    );
  });

  it("never lets a watch that hasn't reported read as up to date", () => {
    const line = watchBuildLine(info("not-reported"));
    expect(line?.text).toBe("Watch · build not reported yet");
    expect(line?.text).not.toMatch(/same build/);
    expect(line?.tone).toBe("muted");
  });

  it("distinguishes not paired, no app, and not reported", () => {
    expect(watchBuildLine(info("not-paired", { paired: false }))?.text).toBe(
      "Watch · not paired",
    );
    expect(watchBuildLine(info("app-not-installed", { appInstalled: false }))?.text).toBe(
      "Watch · Sendmeter not installed",
    );
    expect(watchBuildLine(info("not-reported"))?.text).toBe("Watch · build not reported yet");
  });

  it("drops a stale build when the watch is no longer paired", () => {
    // The plugin keeps the last report across launches; once the watch is
    // gone, that build describes history, not the paired device.
    const line = watchBuildLine(
      info("not-paired", { paired: false, watchDisplay: "1.4.0 (57)", reportedAt: 1_780_000_000 }),
    );
    expect(line?.text).toBe("Watch · not paired");
    expect(line?.reportedAt).toBeUndefined();
  });

  it("says so when the session hasn't activated yet", () => {
    const line = watchBuildLine(info("unknown", { activated: false }));
    expect(line?.text).toBe("Watch · build unknown");
    expect(line?.tone).toBe("muted");
  });

  it("omits the timestamp when the watch never reported one", () => {
    expect(watchBuildLine(info("match", { watchDisplay: "1.4.0 (57)" }))?.reportedAt).toBeUndefined();
  });
});

function sync(status: WatchSyncStatus, over: Partial<WatchBuildInfo> = {}): WatchBuildInfo {
  return info("match", { watchDisplay: "1.4.0 (57)", syncStatus: status, ...over });
}

describe("watchSyncLine", () => {
  it("renders nothing without info (web)", () => {
    expect(watchSyncLine(null)).toBeNull();
  });

  it("renders nothing on a native shell that predates the field", () => {
    // A phone whose compiled-in plugin has no syncStatus knows nothing about
    // the queue — inventing a state for it would be a lie either way.
    expect(watchSyncLine(info("match", { watchDisplay: "1.4.0 (57)" }))).toBeNull();
  });

  it("reports a queue that is actually draining", () => {
    const line = watchSyncLine(sync("empty", { pendingSyncReportedAt: 1_780_000_000 }));
    expect(line).toEqual({
      text: "Watch queue · empty, everything synced",
      tone: "muted",
      reportedAt: 1_780_000_000,
    });
  });

  it("never lets a watch that has never reported read as an empty queue", () => {
    // The honest-states rule (#21/#228): silence and "nothing pending" are
    // different facts, and only one of them means the watch is fine.
    const line = watchSyncLine(sync("not-reported"));
    expect(line?.text).toBe("Watch queue · sync state not reported yet");
    expect(line?.text).not.toMatch(/empty|synced/);
    expect(line?.tone).toBe("muted");
    expect(line?.reportedAt).toBeUndefined();
  });

  it("counts pending items, singular and plural", () => {
    expect(watchSyncLine(sync("pending", { pendingSyncCount: 1 }))?.text).toBe(
      "Watch queue · 1 item pending sync",
    );
    expect(watchSyncLine(sync("pending", { pendingSyncCount: 3 }))?.text).toBe(
      "Watch queue · 3 items pending sync",
    );
  });

  it("keeps a handful of pending items muted", () => {
    // Normal right after an offline session — the queue drains on the watch's
    // next launch or foreground.
    expect(watchSyncLine(sync("pending", { pendingSyncCount: 2 }))?.tone).toBe("muted");
  });

  it("flags a backed-up queue as the actionable state", () => {
    // The point of #21: this is training data sitting on a wrist, invisible.
    const line = watchSyncLine(sync("backed-up", { pendingSyncCount: 9 }));
    expect(line?.text).toBe("Watch queue · 9 items pending sync");
    expect(line?.tone).toBe("warning");
  });

  it("says when a count describes the past rather than the present", () => {
    const line = watchSyncLine(
      sync("pending", {
        pendingSyncCount: 4,
        pendingSyncStale: true,
        pendingSyncReportedAt: 1_779_000_000,
      }),
    );
    // A three-day-old "4 pending" may well have drained since — and a watch
    // that stopped talking with items queued is worth flagging.
    expect(line?.text).toBe("Watch queue · 4 items pending sync at last report");
    expect(line?.tone).toBe("warning");
    expect(line?.reportedAt).toBe(1_779_000_000);
  });

  it("carries the report time so a count can be judged for age", () => {
    expect(
      watchSyncLine(sync("pending", { pendingSyncCount: 2, pendingSyncReportedAt: 1_780_000_000 }))
        ?.reportedAt,
    ).toBe(1_780_000_000);
  });

  it("stays silent when the pairing itself is the story", () => {
    // The build line already says "not paired" / "Sendmeter not installed" /
    // "build unknown"; repeating it as a queue state would be noise, and a
    // stale count from an unpaired watch is history.
    expect(watchSyncLine(sync("not-paired", { paired: false, pendingSyncCount: 3 }))).toBeNull();
    expect(watchSyncLine(sync("app-not-installed", { appInstalled: false }))).toBeNull();
    expect(watchSyncLine(sync("unknown", { activated: false }))).toBeNull();
  });
});
