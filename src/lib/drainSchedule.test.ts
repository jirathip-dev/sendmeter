import { describe, it, expect, vi } from "vitest";
import { scheduleQueueDrain, type DrainScheduleHandles } from "./drainSchedule";

/// Plain fakes — no jsdom. Captures what was registered so a test can fire it
/// directly, and tracks whether cleanup actually ran.
function fakeHandles() {
  let foregroundCb: (() => void) | null = null;
  let intervalCb: (() => void) | null = null;
  let capturedIntervalMs: number | null = null;
  let foregroundCancelled = false;
  let intervalCancelled = false;
  const handles: DrainScheduleHandles = {
    onForeground(cb) {
      foregroundCb = cb;
      return () => {
        foregroundCancelled = true;
      };
    },
    setInterval(cb, ms) {
      intervalCb = cb;
      capturedIntervalMs = ms;
      return () => {
        intervalCancelled = true;
      };
    },
  };
  return {
    handles,
    fireForeground: () => foregroundCb?.(),
    fireInterval: () => intervalCb?.(),
    intervalMs: () => capturedIntervalMs,
    foregroundCancelled: () => foregroundCancelled,
    intervalCancelled: () => intervalCancelled,
  };
}

describe("scheduleQueueDrain (#484 F2)", () => {
  it("drains immediately — the pre-existing mount trigger", () => {
    const runDrain = vi.fn();
    const { handles } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 60_000);
    expect(runDrain).toHaveBeenCalledTimes(1);
  });

  // PROVED to fail on the old App.tsx: its effect had no foreground/visibility
  // listener at all, so nothing but the initial mount ever called
  // `drainPendingRecordingsQueue`.
  it("drains again on every foreground signal, not just once at schedule time", () => {
    const runDrain = vi.fn();
    const { handles, fireForeground } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 60_000);
    fireForeground();
    fireForeground();
    expect(runDrain).toHaveBeenCalledTimes(3); // 1 initial + 2 foreground
  });

  // PROVED to fail on the old App.tsx: it also had no interval. This is the
  // scenario named in #484 itself — a tab that goes offline, comes back into
  // signal, and is NEVER backgrounded in between, so no foreground/visibility
  // event fires either.
  it("drains on a plain interval even with no foreground signal at all", () => {
    const runDrain = vi.fn();
    const { handles, fireInterval } = fakeHandles();
    scheduleQueueDrain(runDrain, handles, 60_000);
    fireInterval();
    fireInterval();
    expect(runDrain).toHaveBeenCalledTimes(3); // 1 initial + 2 interval ticks
  });

  it("registers the interval with the requested period", () => {
    const { handles, intervalMs } = fakeHandles();
    scheduleQueueDrain(vi.fn(), handles, 45_000);
    expect(intervalMs()).toBe(45_000);
  });

  it("cancels both the foreground listener and the interval on cleanup", () => {
    const { handles, foregroundCancelled, intervalCancelled } = fakeHandles();
    const cancel = scheduleQueueDrain(vi.fn(), handles, 60_000);
    expect(foregroundCancelled()).toBe(false);
    expect(intervalCancelled()).toBe(false);
    cancel();
    expect(foregroundCancelled()).toBe(true);
    expect(intervalCancelled()).toBe(true);
  });
});
