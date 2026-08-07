import { describe, expect, it } from "vitest";
import {
  uploadWarningPresentation,
  watchStatusPresentation,
  type WatchBuildInfo,
  type WatchBuildStatus,
  type WatchQuarantineStatus,
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

describe("watchStatusPresentation (#369 Account card)", () => {
  it("makes pairing and installation states readable without diagnostics", () => {
    expect(watchStatusPresentation(info("not-paired", { paired: false }))).toMatchObject({
      title: "No watch paired",
      tone: "muted",
    });
    expect(
      watchStatusPresentation(info("app-not-installed", { appInstalled: false })),
    ).toMatchObject({
      title: "App not installed",
      tone: "warning",
    });
    expect(watchStatusPresentation(info("not-reported"))).toMatchObject({
      title: "Connected & installed",
      detail: "The watch app has not reported its build yet.",
    });
    expect(watchStatusPresentation(info("unknown", { activated: false }))).toMatchObject({
      title: "Checking watch status",
      tone: "muted",
    });
  });

  it.each([
    ["match", "Build matches this iPhone.", "positive"],
    ["watch-behind", "The watch build is behind this iPhone.", "warning"],
    ["watch-ahead", "The watch build is ahead of this iPhone.", "warning"],
    ["differs", "The watch build differs from this iPhone.", "warning"],
  ] as const)("presents %s as connected with its verdict", (status, detail, tone) => {
    const presentation = watchStatusPresentation(
      info(status, {
        watchDisplay: "1.4.0 (57)",
        phoneDisplay: "1.4.0 (58)",
        reportedAt: 1_780_000_000,
      }),
    );
    expect(presentation).toMatchObject({
      title: "Connected & installed",
      tone,
      watchDisplay: "1.4.0 (57)",
      phoneDisplay: "1.4.0 (58)",
      reportedAt: 1_780_000_000,
    });
    expect(presentation?.detail).toContain(detail);
  });

  it("keeps stale build metadata out of non-current pairing states", () => {
    const presentation = watchStatusPresentation(
      info("not-paired", {
        paired: false,
        watchDisplay: "old watch build",
        reportedAt: 1_700_000_000,
      }),
    );
    expect(presentation).not.toHaveProperty("watchDisplay");
    expect(presentation).not.toHaveProperty("reportedAt");
  });

  it("only selects watch-status metadata from the native result", () => {
    const nativeResult = {
      ...info("match", { watchDisplay: "1.4.0 (57)" }),
      accessToken: "credential-must-not-render",
      email: "private@example.test",
      workout: { attempts: ["private-payload"] },
      health: { hrv: 99 },
    } as WatchBuildInfo;
    const rendered = JSON.stringify(watchStatusPresentation(nativeResult));
    expect(rendered).not.toMatch(/credential|private@example|attempts|hrv/);
  });
});

function sync(status: WatchSyncStatus, over: Partial<WatchBuildInfo> = {}): WatchBuildInfo {
  return info("match", { watchDisplay: "1.4.0 (57)", syncStatus: status, ...over });
}

function phone(
  pending: number | null,
  stuck: number | null = 0,
): { pending: number | null; stuck: number | null } {
  return { pending, stuck };
}

describe("uploadWarningPresentation (#369 History banner)", () => {
  it("stays quiet while both queues are empty or not read yet", () => {
    expect(
      uploadWarningPresentation(
        sync("empty", { pendingSyncCount: 0, pendingSyncStale: false }),
        phone(0),
      ),
    ).toBeNull();
    expect(uploadWarningPresentation(null, phone(null, null))).toBeNull();
    expect(uploadWarningPresentation(sync("not-reported"), phone(0))).toBeNull();
  });

  it("shows current pending watch items and disappears after a live zero report", () => {
    const pending = uploadWarningPresentation(
      sync("pending", { pendingSyncCount: 2, pendingSyncStale: false }),
      phone(0),
    );
    expect(pending?.items).toEqual([
      expect.objectContaining({
        source: "watch",
        text: "Apple Watch · 2 items waiting to upload.",
      }),
    ]);
    expect(
      uploadWarningPresentation(
        sync("empty", { pendingSyncCount: 0, pendingSyncStale: false }),
        phone(0),
      ),
    ).toBeNull();
  });

  it("never phrases a stale pending count as current", () => {
    const warning = uploadWarningPresentation(
      sync("backed-up", {
        pendingSyncCount: 7,
        pendingSyncStale: true,
        pendingSyncReportedAt: 1_779_000_000,
      }),
      phone(0),
    );
    expect(warning?.items[0]).toMatchObject({
      text: "Apple Watch last reported 7 items waiting to upload.",
      reportedAt: 1_779_000_000,
    });
    expect(warning?.items[0]?.text).not.toContain("Apple Watch · 7");
  });

  it("flags a stale empty report without claiming the queue is still empty", () => {
    const warning = uploadWarningPresentation(
      sync("empty", {
        pendingSyncCount: 0,
        pendingSyncStale: true,
        pendingSyncReportedAt: 1_779_000_000,
      }),
      phone(0),
    );
    expect(warning?.title).toBe("Check Apple Watch uploads");
    expect(warning?.items[0]?.text).toBe(
      "Apple Watch has not reported upload status recently.",
    );
    expect(warning?.items[0]?.detail).toContain("last report showed no items waiting");
  });

  it("includes only non-empty iPhone uploads and combines both devices", () => {
    const phoneOnly = uploadWarningPresentation(null, phone(1));
    expect(phoneOnly?.items[0]?.text).toBe(
      "This iPhone · 1 Force recording waiting to upload.",
    );

    const combined = uploadWarningPresentation(
      sync("pending", { pendingSyncCount: 3 }),
      phone(2),
    );
    expect(combined?.items.map((item) => item.source)).toEqual(["watch", "phone"]);
    expect(combined?.items[1]?.text).toBe(
      "This iPhone · 2 Force recordings waiting to upload.",
    );
  });

  // #475 F1: quarantine was invisible everywhere before this — the count
  // was written to a cache slot nothing read. These pin the distinct,
  // non-"waiting to upload" presentation.
  function quarantined(
    status: WatchQuarantineStatus,
    over: Partial<WatchBuildInfo> = {},
  ): WatchBuildInfo {
    return info("match", { watchDisplay: "1.4.0 (57)", quarantineStatus: status, ...over });
  }

  it("stays quiet while quarantine is none or not yet reported", () => {
    expect(
      uploadWarningPresentation(quarantined("none", { quarantinedSyncCount: 0 }), 0),
    ).toBeNull();
    expect(uploadWarningPresentation(quarantined("not-reported"), 0)).toBeNull();
  });

  it("never phrases a quarantined item as waiting to upload", () => {
    const warning = uploadWarningPresentation(
      quarantined("stuck", { quarantinedSyncCount: 2, quarantinedSyncReportedAt: 1_779_500_000 }),
      0,
    );
    expect(warning?.items).toEqual([
      expect.objectContaining({
        source: "watch-quarantined",
        text: "Apple Watch · 2 workouts could not be uploaded and will not retry.",
        reportedAt: 1_779_500_000,
      }),
    ]);
    expect(warning?.items[0]?.text).not.toMatch(/waiting to upload/);
    // The generic fallback title, not "Uploads waiting" — nothing here is
    // waiting for anything.
    expect(warning?.title).toBe("Check Apple Watch uploads");
  });

  it("shows both a pending item and a quarantined item at once, distinctly", () => {
    const warning = uploadWarningPresentation(
      info("match", {
        watchDisplay: "1.4.0 (57)",
        syncStatus: "pending",
        pendingSyncCount: 1,
        quarantineStatus: "stuck",
        quarantinedSyncCount: 1,
      }),
      0,
    );
    expect(warning?.items.map((item) => item.source)).toEqual(["watch", "watch-quarantined"]);
    expect(warning?.items[0]?.text).toContain("waiting to upload");
    expect(warning?.items[1]?.text).toContain("could not be uploaded and will not retry");
  });

  // #475 F13: the two QuarantineReason cases need different, true copy —
  // conflating them told a "will not retry" user something false when the
  // only thing wrong was gym wifi (or the reverse).
  it("shows only the retrying item when every quarantined workout is still auto-retrying", () => {
    const warning = uploadWarningPresentation(
      quarantined("stuck", { quarantinedSyncCount: 2, quarantinedStuckSyncCount: 2 }),
      0,
    );
    expect(warning?.items).toEqual([
      expect.objectContaining({
        source: "watch-quarantined-retrying",
        text: "Apple Watch · 2 workouts having trouble uploading — retrying automatically.",
      }),
    ]);
    expect(warning?.items[0]?.text).not.toMatch(/will not retry/);
    expect(warning?.items[0]?.detail).toContain("No action needed");
  });

  it("splits into both a permanent item and a retrying item when the counts differ", () => {
    const warning = uploadWarningPresentation(
      quarantined("stuck", {
        quarantinedSyncCount: 3,
        quarantinedStuckSyncCount: 1,
        quarantinedStuckSyncReportedAt: 1_779_600_000,
      }),
      0,
    );
    expect(warning?.items.map((item) => item.source)).toEqual([
      "watch-quarantined",
      "watch-quarantined-retrying",
    ]);
    // 3 total, 1 retrying -> 2 permanent, not 3.
    expect(warning?.items[0]?.text).toBe(
      "Apple Watch · 2 workouts could not be uploaded and will not retry.",
    );
    expect(warning?.items[1]?.text).toBe(
      "Apple Watch · 1 workout having trouble uploading — retrying automatically.",
    );
    expect(warning?.items[1]?.reportedAt).toBe(1_779_600_000);
  });

  it("defaults an unknown breakdown to the cautious permanent framing, not silently to retrying", () => {
    // An older watch build / plugin reports only the combined total — the
    // subset is genuinely unknown, which must not read as "0 retrying".
    const warning = uploadWarningPresentation(
      quarantined("stuck", { quarantinedSyncCount: 4, quarantinedStuckSyncCount: undefined }),
      0,
    );
    expect(warning?.items).toEqual([
      expect.objectContaining({
        source: "watch-quarantined",
        text: "Apple Watch · 4 workouts could not be uploaded and will not retry.",
      }),
    ]);
  // #484 — the #475 F1 lesson: a stuck count must have a reader of its own.
  describe("a stuck iPhone queue (#484)", () => {
    it("renders its own item, distinct from a pending one, with 'Uploads waiting' as the title", () => {
      const warning = uploadWarningPresentation(null, { pending: 0, stuck: 1 });
      expect(warning?.items).toEqual([
        expect.objectContaining({
          source: "phone-stuck",
          text: "This iPhone · 1 Force recording stuck — the server keeps rejecting it and it won't retry automatically.",
        }),
      ]);
      expect(warning?.title).toBe("Uploads waiting");
    });

    it("renders alongside a pending item rather than replacing it", () => {
      const warning = uploadWarningPresentation(null, { pending: 2, stuck: 1 });
      expect(warning?.items.map((i) => i.source)).toEqual(["phone-stuck", "phone"]);
    });

    it("pluralizes correctly at more than one stuck recording", () => {
      const warning = uploadWarningPresentation(null, { pending: 0, stuck: 3 });
      expect(warning?.items[0]?.text).toBe(
        "This iPhone · 3 Force recordings stuck — the server keeps rejecting them and they won't retry automatically.",
      );
    });

    it("stays quiet when stuck is 0 or not yet known", () => {
      expect(uploadWarningPresentation(null, { pending: 0, stuck: 0 })).toBeNull();
      expect(uploadWarningPresentation(null, { pending: 0, stuck: null })).toBeNull();
    });
  });
});
