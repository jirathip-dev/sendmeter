import { describe, it, expect, vi } from "vitest";
import {
  PENDING_BACKED_UP,
  notifyPendingUploadsChanged,
  pendingUploadsLine,
  subscribePendingUploads,
} from "./pendingUploads";

describe("pendingUploadsLine (#269 — the honest-states rule)", () => {
  it("says the depth isn't known yet rather than claiming empty", () => {
    // Both stores are async to count, so there is a real moment where we do
    // not know. Rendering that as "everything synced" would be a lie told at
    // exactly the wrong time.
    const line = pendingUploadsLine(null);
    expect(line.text).toMatch(/not read yet/);
    expect(line.tone).toBe("muted");
  });

  it("says an empty queue is empty rather than rendering nothing", () => {
    const line = pendingUploadsLine({ pending: 0, stuck: 0 });
    expect(line.text).toMatch(/empty, everything synced/);
    expect(line.tone).toBe("muted");
  });

  it("counts a single pending recording in the singular", () => {
    expect(pendingUploadsLine({ pending: 1, stuck: 0 }).text).toBe(
      "This device · 1 recording pending sync",
    );
  });

  it("stays muted for a backlog that's just waiting on signal", () => {
    const line = pendingUploadsLine({ pending: PENDING_BACKED_UP - 1, stuck: 0 });
    expect(line.text).toBe(
      `This device · ${PENDING_BACKED_UP - 1} recordings pending sync`,
    );
    // A rep or two waiting is normal; alarming about it would train the user
    // to ignore the row.
    expect(line.tone).toBe("muted");
  });

  it("warns once the backlog is deep enough to mean it isn't draining", () => {
    expect(pendingUploadsLine({ pending: PENDING_BACKED_UP, stuck: 0 }).tone).toBe("warning");
    expect(pendingUploadsLine({ pending: PENDING_BACKED_UP + 20, stuck: 0 }).tone).toBe(
      "warning",
    );
  });

  it("uses the same threshold the watch uses for its own queue", () => {
    // WatchSyncReport.backedUpThreshold in SendLogWatchCore — the two lines sit
    // next to each other in the account sheet and must not disagree about what
    // "a lot" means.
    expect(PENDING_BACKED_UP).toBe(5);
  });

  // #484 — the #475 F1 lesson applied here: a stuck count must have a reader,
  // never fold silently into "pending" or vanish.
  describe("a stuck count (#484)", () => {
    it("renders on its own, warning, when nothing else is pending", () => {
      const line = pendingUploadsLine({ pending: 0, stuck: 1 });
      expect(line.text).toBe("This device · 1 recording stuck, not retrying");
      expect(line.tone).toBe("warning");
    });

    it("renders alongside a pending count rather than replacing it", () => {
      const line = pendingUploadsLine({ pending: 2, stuck: 3 });
      expect(line.text).toBe(
        "This device · 2 pending sync, 3 recordings stuck, not retrying",
      );
      expect(line.tone).toBe("warning");
    });

    it("warns even below the backed-up threshold — stuck is never routine", () => {
      const line = pendingUploadsLine({ pending: 0, stuck: 1 });
      expect(line.tone).toBe("warning");
    });
  });
});

describe("subscribePendingUploads", () => {
  it("notifies every subscriber, and stops after unsubscribe", () => {
    const a = vi.fn();
    const b = vi.fn();
    const offA = subscribePendingUploads(a);
    const offB = subscribePendingUploads(b);

    notifyPendingUploadsChanged();
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);

    offA();
    notifyPendingUploadsChanged();
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(2);
    offB();
  });

  it("does not let one throwing subscriber stop the others", () => {
    // This fires from useTindeq's unmount cleanup, where an exception would
    // take out the rest of the teardown — including the BLE disconnect.
    const boom = vi.fn(() => {
      throw new Error("stale subscriber");
    });
    const ok = vi.fn();
    const offBoom = subscribePendingUploads(boom);
    const offOk = subscribePendingUploads(ok);

    expect(() => notifyPendingUploadsChanged()).not.toThrow();
    expect(ok).toHaveBeenCalledTimes(1);
    offBoom();
    offOk();
  });

  it("tolerates a subscriber unsubscribing during the notification", () => {
    const later = vi.fn();
    const offLater = subscribePendingUploads(later);
    const offFirst = subscribePendingUploads(() => offLater());
    expect(() => notifyPendingUploadsChanged()).not.toThrow();
    offFirst();
  });
});
