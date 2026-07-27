import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  noteLostRecordings,
  reportPersistFailure,
  takeLostRecordingsNotice,
  type NoticeStorage,
} from "./lostRecordings";

/// In-memory stand-in for localStorage — keeps these tests jsdom-free, like
/// the rest of `src/lib`.
function fakeStorage(): NoticeStorage & { size: () => number } {
  const map = new Map<string, string>();
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => void map.set(k, v),
    removeItem: (k) => void map.delete(k),
    size: () => map.size,
  };
}

/// A store whose writes always throw — the quota-exhausted case that this
/// whole module exists to describe.
function throwingStorage(): NoticeStorage {
  return {
    getItem: () => null,
    setItem: () => {
      throw new Error("QuotaExceededError");
    },
    removeItem: () => {},
  };
}

const at = () => "2026-07-27T10:00:00.000Z";

let warn: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  warn = vi.spyOn(console, "warn").mockImplementation(() => {});
});
afterEach(() => {
  warn.mockRestore();
});

describe("noteLostRecordings / takeLostRecordingsNotice", () => {
  it("records a loss and hands it back exactly once", () => {
    const storage = fakeStorage();
    expect(noteLostRecordings(1, storage, at)).toBe(true);
    expect(takeLostRecordingsNotice(storage)).toEqual({ count: 1, lastAt: at() });
    // Cleared on read — the user is told once, not on every foreground.
    expect(takeLostRecordingsNotice(storage)).toBeNull();
  });

  it("accumulates, so a protocol that loses every rep reports one real number", () => {
    const storage = fakeStorage();
    noteLostRecordings(1, storage, () => "2026-07-27T10:00:00.000Z");
    noteLostRecordings(1, storage, () => "2026-07-27T10:01:00.000Z");
    noteLostRecordings(1, storage, () => "2026-07-27T10:02:00.000Z");
    expect(takeLostRecordingsNotice(storage)).toEqual({
      count: 3,
      lastAt: "2026-07-27T10:02:00.000Z",
    });
  });

  it("reports false (rather than throwing) when the notice itself won't write", () => {
    expect(noteLostRecordings(1, throwingStorage(), at)).toBe(false);
  });

  it("treats absent/disabled storage as nothing to say", () => {
    expect(noteLostRecordings(1, null, at)).toBe(false);
    expect(takeLostRecordingsNotice(null)).toBeNull();
    expect(takeLostRecordingsNotice(fakeStorage())).toBeNull();
  });

  it("tolerates a corrupt record instead of surfacing a bogus count", () => {
    const storage = fakeStorage();
    storage.setItem("sendmeter:lost-recordings", "{not json");
    expect(takeLostRecordingsNotice(storage)).toBeNull();
    // …and starts a fresh count rather than inheriting the garbage.
    noteLostRecordings(1, storage, at);
    expect(takeLostRecordingsNotice(storage)).toEqual({ count: 1, lastAt: at() });
  });
});

describe("reportPersistFailure (#264)", () => {
  it("says nothing when the recording was queued and nothing was evicted", () => {
    const storage = fakeStorage();
    reportPersistFailure(
      "save-failed",
      { persisted: true, evicted: 0 },
      1200,
      storage,
      at,
    );
    expect(storage.size()).toBe(0);
    expect(warn).not.toHaveBeenCalled();
  });

  it("leaves a durable user notice when the recording has no home", () => {
    const storage = fakeStorage();
    reportPersistFailure(
      "salvage-on-unmount",
      { persisted: false, evicted: 0 },
      1200,
      storage,
      at,
    );
    expect(takeLostRecordingsNotice(storage)).toEqual({ count: 1, lastAt: at() });
    expect(warn).toHaveBeenCalledOnce();
  });

  it("records that the user could NOT be told when the notice write also fails", () => {
    reportPersistFailure(
      "salvage-on-unmount",
      { persisted: false, evicted: 0 },
      1200,
      throwingStorage(),
      at,
    );
    // The distinction that matters in monitoring: nobody knows this happened.
    expect(warn.mock.calls[0]?.[1]).toMatchObject({ lost: 1, noticeStored: false });
  });

  it("reports evictions to monitoring only — they are the queue's designed degradation", () => {
    const storage = fakeStorage();
    reportPersistFailure(
      "save-failed",
      { persisted: true, evicted: 2 },
      1200,
      storage,
      at,
    );
    expect(warn).toHaveBeenCalledOnce();
    expect(warn.mock.calls[0]?.[1]).toMatchObject({ evicted: 2, samples: 1200 });
    // No user notice: the rep they just pulled is safely queued.
    expect(takeLostRecordingsNotice(storage)).toBeNull();
  });
});
