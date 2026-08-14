import type { NewTindeqRecording, TindeqRecordingMeta } from "../types";
import type { PersistResult } from "./recordingQueue";
import { captureForceLatency } from "./monitoring";
import { clearRealtimeInsertMark, markRealtimeInsertStart } from "./forceLatency";
import type { RepSettlement } from "./gaugeSessionEnd";

// #613 — MAKE THE CAPTURE DURABLE BEFORE DEPENDING ON THE NETWORK.
//
// The pre-#613 save path wrote straight to Supabase and only published the rep
// to local state after the insert returned: every rep paid a full network round
// trip before it showed up, and a failed insert had to be re-queued afterwards.
// This module inverts the order:
//
//   1. persist durably FIRST (`persistRecordingDurable` — IndexedDB main queue,
//      localStorage lane only when IndexedDB is unavailable), so the rep is
//      safe on-device the moment its samples exist;
//   2. publish a local pending row immediately — the capture is visible, the
//      session count/curves see it, and the session may END without waiting for
//      the network;
//   3. insert to Supabase; on success reconcile the pending row with the
//      server row BY ID; on failure the row stays visibly pending and drains
//      through the existing idempotent queue (the same client-minted id makes
//      a retry a 23505 no-op, #106).
//
// The one hard rule this enforces: a recording that could NOT be persisted
// durably is reported through the #264 loss path (`onNotPersisted`), never
// called "queued" — nothing is holding it but the caller's memory.

/// What the durable-first save resolved to.
export type RecordingSaveOutcome =
  /// Durable, published, and confirmed by the server (row reconciled by id).
  | "saved"
  /// Durable + published locally, but the server insert failed — the rep stays
  /// pending and drains through the idempotent queue.
  | "pending"
  /// Neither durable store would take the rep — the #264 loss path.
  | "not-persisted"
  /// This exact rep was already published (a duplicate call for the same id).
  | "redundant";

export interface SaveRecordingInput {
  rec: NewTindeqRecording & { id: string };
  /// The durable write. For every await-capable path this is
  /// `persistRecordingDurable` — never a bare insert.
  persist: (rec: NewTindeqRecording & { id: string }) => Promise<PersistResult>;
  /// The network insert. Called only after `persist` succeeded.
  insert: (rec: NewTindeqRecording & { id: string }) => Promise<TindeqRecordingMeta>;
  /// Idempotence gate: has this exact rep already been published locally?
  /// Guards against a duplicate caller (the per-path claims are the primary
  /// dedupe; this is the second layer at the list itself).
  isPublished: (id: string) => boolean;
  /// Publish the durable-but-unconfirmed row. Must be SYNCHRONOUS — the caller
  /// typically writes a ref here so a session end in flight sees the capture.
  publishPending: (rec: NewTindeqRecording & { id: string }) => void;
  /// Reconcile the published row with the server-confirmed row, by id.
  reconcileSaved: (saved: TindeqRecordingMeta) => void;
  /// The durable persist was refused — report through the #264 path and show
  /// the honest "not saved" banner. Never phrase this as queued.
  onNotPersisted: (
    rec: NewTindeqRecording & { id: string },
    result: PersistResult,
  ) => void;
  /// The server insert failed after a durable persist. The local row stays
  /// pending; the queue drains it. `onNotPersisted` must NOT be called here.
  onInsertFailure: (error: unknown) => void;
  /// #613: signals an in-flight save to the session-end settlement.
  settlement?: RepSettlement;
}

/// The one durable-first save path every await-capable ForceView save site
/// funnels through (guided per-rep holds, free holds, adaptive, reverse-action
/// sets, manual and cadence attempts). Returns the resolved outcome; see
/// `RecordingSaveOutcome`.
export async function saveRecordingDurableFirst(
  input: SaveRecordingInput,
): Promise<RecordingSaveOutcome> {
  const { rec } = input;
  if (input.isPublished(rec.id)) return "redundant";
  // Claim the settlement slot before the first await — a session end that
  // races this save must wait for it (see RepSettlement).
  input.settlement?.begin();

  const persistT0 = performance.now();
  const result = await input.persist(rec);
  captureForceLatency("rep.persist", performance.now() - persistT0);

  if (!result.persisted) {
    input.onNotPersisted(rec, result);
    input.settlement?.finish();
    return "not-persisted";
  }

  // Durable + published: the capture is safe on-device now, so a session end
  // may snapshot it. The network insert is allowed to lag behind the session.
  input.publishPending(rec);
  input.settlement?.finish();

  try {
    // Mark the realtime-echo measurement just before the network insert, so
    // the provider can time how long our own write takes to bounce back
    // (`forceLatency.ts`).
    markRealtimeInsertStart();
    const insertT0 = performance.now();
    const saved = await input.insert(rec);
    captureForceLatency("rep.insert", performance.now() - insertT0);
    clearRealtimeInsertMark();
    input.reconcileSaved(saved);
    return "saved";
  } catch (error) {
    clearRealtimeInsertMark();
    input.onInsertFailure(error);
    return "pending";
  }
}

/// Build the local `TindeqRecordingMeta` for a rep that is durable but not yet
/// confirmed by the server — the row published the moment the IndexedDB write
/// lands, so the capture shows up before the network round trip finishes.
/// Reconcile replaces it by id when `insertRecording` returns.
export function pendingRecordingMeta(
  rec: NewTindeqRecording & { id: string },
): TindeqRecordingMeta {
  return {
    id: rec.id,
    // Every construction site stamps recordedAt (#487, F2 — see
    // recordedAtInvariant.test.ts); the fallback only guards a hypothetical
    // caller that skipped it.
    recordedAt: rec.recordedAt ?? new Date().toISOString(),
    durationMs: rec.durationMs,
    peakKg: rec.peakKg,
    avgKg: rec.avgKg,
    sampleCount: rec.samples.length,
    note: rec.note,
    tag: rec.tag,
    side: rec.side,
    groupId: rec.groupId,
    protocolRunId: rec.protocolRunId,
    setNo: rec.setNo,
    zone: rec.zone,
    source: rec.source ?? "dynamometer",
    externalLoadKg: rec.externalLoadKg ?? null,
    outcome: rec.outcome ?? null,
    plannedDurationMs: rec.plannedDurationMs ?? null,
    actualDurationMs: rec.actualDurationMs ?? null,
    repNo: rec.repNo ?? null,
    protocolMode: rec.protocolMode,
    targetKg: rec.targetKg ?? null,
    targetLowKg: rec.targetLowKg ?? null,
    targetHighKg: rec.targetHighKg ?? null,
    cadenceOutS: rec.cadenceOutS ?? null,
    cadenceReturnS: rec.cadenceReturnS ?? null,
    cadenceMarkers: rec.cadenceMarkers ?? null,
    setMetrics: rec.setMetrics ?? null,
    setupNote: rec.setupNote ?? "",
    capacityEvidence: rec.capacityEvidence ?? null,
    completedReps: rec.completedReps ?? null,
    completionStatus: rec.completionStatus ?? null,
  };
}
