import { describe, expect, it } from "vitest";
import { watchBuildLine, type WatchBuildInfo, type WatchBuildStatus } from "./watchBuild";

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
