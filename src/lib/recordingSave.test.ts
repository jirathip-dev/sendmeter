import { describe, it, expect, vi } from "vitest";
import {
  pendingRecordingMeta,
  saveRecordingDurableFirst,
} from "./recordingSave";
import { createRepSettlement } from "./gaugeSessionEnd";
import type { NewTindeqRecording, TindeqRecordingMeta } from "../types";
import type { PersistResult } from "./recordingQueue";

function rec(id = "id-1"): NewTindeqRecording & { id: string } {
  return {
    id,
    recordedAt: "2026-07-29T10:00:00.000Z",
    durationMs: 7000,
    peakKg: 32.1,
    avgKg: 28.4,
    note: "",
    tag: "FDP",
    side: "left",
    groupId: "group-1",
    protocolRunId: null,
    setNo: null,
    zone: null,
    samples: [
      { t: 0, kg: 10 },
      { t: 500, kg: 20 },
      { t: 1000, kg: 30 },
    ],
  };
}

function savedMeta(id = "id-1"): TindeqRecordingMeta {
  return {
    id,
    recordedAt: "2026-07-29T10:00:00.000Z",
    durationMs: 7000,
    peakKg: 32.1,
    avgKg: 28.4,
    sampleCount: 3,
    note: "",
    tag: "FDP",
    side: "left",
    groupId: "group-1",
    protocolRunId: null,
    setNo: null,
    zone: null,
    source: "dynamometer",
  };
}

const persisted: PersistResult = { persisted: true, evicted: 0 };
const refused: PersistResult = { persisted: false, evicted: 0 };

function deferred<T>() {
  let resolve: (v: T) => void = () => {};
  let reject: (e: unknown) => void = () => {};
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function handlers(overrides: Partial<Parameters<typeof saveRecordingDurableFirst>[0]> = {}) {
  const publishPending = vi.fn();
  const reconcileSaved = vi.fn();
  const onNotPersisted = vi.fn();
  const onInsertFailure = vi.fn();
  const input = {
    rec: rec(),
    persist: vi.fn(async (): Promise<PersistResult> => persisted),
    insert: vi.fn(async (): Promise<TindeqRecordingMeta> => savedMeta()),
    isPublished: vi.fn(() => false),
    publishPending,
    reconcileSaved,
    onNotPersisted,
    onInsertFailure,
    ...overrides,
  };
  return { input, publishPending, reconcileSaved, onNotPersisted, onInsertFailure };
}

describe("saveRecordingDurableFirst (#613 — durable before the network)", () => {
  it("persists → publishes the pending row → inserts → reconciles by id", async () => {
    const { input, publishPending, reconcileSaved } = handlers();
    const gate = deferred<TindeqRecordingMeta>();
    const insert = vi.fn(() => gate.promise);
    input.insert = insert;

    const outcome = saveRecordingDurableFirst(input);
    await Promise.resolve(); // let the durable persist resolve

    // The pending row is published BEFORE the server confirms.
    expect(input.persist).toHaveBeenCalledWith(input.rec);
    expect(publishPending).toHaveBeenCalledWith(input.rec);
    expect(insert).toHaveBeenCalledWith(input.rec);
    expect(reconcileSaved).not.toHaveBeenCalled();

    gate.resolve(savedMeta());
    expect(await outcome).toBe("saved");
    expect(reconcileSaved).toHaveBeenCalledWith(savedMeta());
  });

  it("a failed server insert returns 'pending' and leaves the row pending — never reported as lost", async () => {
    const { input, onNotPersisted, onInsertFailure } = handlers({
      insert: vi.fn(async () => {
        throw new Error("JWT expired");
      }),
    });
    const outcome = await saveRecordingDurableFirst(input);
    expect(outcome).toBe("pending");
    expect(onInsertFailure).toHaveBeenCalledTimes(1);
    // The rep IS durable — the #264 loss path (onNotPersisted) must not fire.
    expect(onNotPersisted).not.toHaveBeenCalled();
  });

  it("a refused durable write returns 'not-persisted' and never reaches the network", async () => {
    const { input, onNotPersisted } = handlers({
      persist: vi.fn(async (): Promise<PersistResult> => refused),
    });
    const outcome = await saveRecordingDurableFirst(input);
    expect(outcome).toBe("not-persisted");
    expect(onNotPersisted).toHaveBeenCalledWith(input.rec, refused);
    expect(input.insert).not.toHaveBeenCalled();
  });

  it("is idempotent — a second call for an already-published id is 'redundant'", async () => {
    const published = new Set<string>();
    const { input } = handlers({
      isPublished: vi.fn((id: string) => published.has(id)),
      publishPending: vi.fn((r: NewTindeqRecording & { id: string }) => {
        published.add(r.id);
      }),
    });
    expect(await saveRecordingDurableFirst(input)).toBe("saved");
    expect(await saveRecordingDurableFirst(input)).toBe("redundant");
    expect(input.persist).toHaveBeenCalledTimes(1);
    expect(input.insert).toHaveBeenCalledTimes(1);
  });

  it("an in-flight save holds the settlement only until durable + published — the insert may lag the session end", async () => {
    const { input } = handlers();
    const gate = deferred<TindeqRecordingMeta>();
    input.insert = () => gate.promise;
    const settlement = createRepSettlement();
    input.settlement = settlement;

    const outcome = saveRecordingDurableFirst(input);
    // Not settled yet — the durable write is still in flight.
    await Promise.resolve();
    await Promise.resolve();
    // persist resolved, publish happened, insert still pending — the session
    // end can already proceed (bounded by local storage, never the network).
    await expect(settlement.waitForIdle()).resolves.toBeUndefined();
    gate.resolve(savedMeta());
    expect(await outcome).toBe("saved");
  });

  it("a refused durable write finishes the settlement too", async () => {
    const { input } = handlers({
      persist: vi.fn(async (): Promise<PersistResult> => refused),
    });
    const settlement = createRepSettlement();
    input.settlement = settlement;
    await expect(saveRecordingDurableFirst(input)).resolves.toBe("not-persisted");
    await expect(settlement.waitForIdle()).resolves.toBeUndefined();
  });
});

describe("pendingRecordingMeta (#613)", () => {
  it("maps a NewTindeqRecording to a locally-usable TindeqRecordingMeta", () => {
    const meta = pendingRecordingMeta(rec());
    expect(meta).toMatchObject({
      id: "id-1",
      recordedAt: "2026-07-29T10:00:00.000Z",
      durationMs: 7000,
      peakKg: 32.1,
      avgKg: 28.4,
      sampleCount: 3,
      tag: "FDP",
      side: "left",
      groupId: "group-1",
      zone: null,
      source: "dynamometer",
      protocolMode: undefined,
    });
  });

  it("defaults source to dynamometer when absent", () => {
    const meta = pendingRecordingMeta({ ...rec(), source: undefined });
    expect(meta.source).toBe("dynamometer");
  });

  it("preserves manual source so isMeasuredRecording reads it honestly", () => {
    const meta = pendingRecordingMeta({ ...rec(), source: "manual", peakKg: null });
    expect(meta.source).toBe("manual");
    expect(meta.peakKg).toBeNull();
  });

  it("is a construction site that carries recordedAt (the #487 rule)", () => {
    expect(pendingRecordingMeta(rec()).recordedAt).toBe("2026-07-29T10:00:00.000Z");
  });
});
