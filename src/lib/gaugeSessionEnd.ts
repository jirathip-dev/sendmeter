import type { TindeqRecordingMeta } from "../types";
import type { TagCurve } from "./repo/tindeq";
import { computeGroupDurationMin } from "./duration";
import { predictSessionRpe, type PredictedRpe } from "./rpeDepletion";
import {
  isDepletionEffortRecording,
  recordingCapacityModality,
} from "./zoneHistory";

export interface EndGaugeSessionArgs {
  groupId: string;
  /// Fallback duration when no recordings have landed yet.
  wallClockMin: number;
  /// Groups already ended — checked-and-claimed synchronously, before the
  /// first `await` below.
  claimed: Set<string>;
  /// #613: the RPE prediction now reads the last successfully fetched tag-curve
  /// registry (a ForceView ref), never a fresh network call — it resolves
  /// immediately, so ending a session cannot stall on `fetchTagCurves()`. (The
  /// `Promise` return is a type-level convenience: the implementation awaits
  /// nothing.) Returns the recordings snapshot too, so note/duration read the
  /// same list the prediction did.
  predictGroupRpe: (groupId: string) => Promise<{
    predicted: PredictedRpe;
    recs: TindeqRecordingMeta[];
  }>;
  onLogSession: (input: {
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
    rpeConfirmed: false;
  }) => Promise<boolean>;
  /// #613: in-flight per-rep saves the session end must wait for before
  /// snapshotting `recs` — a Finish tap or a disconnect can race the final
  /// rep's durable write, and the prediction/duration snapshot must not miss
  /// it. The waits resolve the moment each save is DURABLE and published (the
  /// network insert is allowed to lag the session), so this is bounded by
  /// local storage latency, not the network.
  settlement?: RepSettlement;
}

/// #295: ends a gauge session and auto-logs it immediately — no confirm step.
/// `claimed` guards against a duplicate insert for the same `groupId`: the
/// disconnect effect's 150ms-deferred `endSession()` and a Finish tap can
/// both run from a render whose closure still sees an active session (a
/// setState can't retroactively null another in-flight closure's captured
/// value), so both would otherwise reach `onLogSession`. The claim MUST
/// happen before the first `await`, or two concurrent calls can both read
/// "not yet claimed" and both proceed. Returns `null` when a call loses the
/// race (nothing logged), else `onLogSession`'s result.
export async function endGaugeSession(
  args: EndGaugeSessionArgs,
): Promise<boolean | null> {
  const { groupId, wallClockMin, claimed } = args;
  if (claimed.has(groupId)) return null;
  claimed.add(groupId);

  // #613: the snapshot that prediction, note and duration read must include
  // every rep whose durable save is still settling (a Finish/disconnect races
  // the final rep's write). Waiting here — after the claim — is the one place
  // the session end can block, and it is bounded by local persistence, never
  // the network: each in-flight save finishes its durable write + local
  // publish before the settlement resolves.
  if (args.settlement) await args.settlement.waitForIdle();

  const { predicted, recs } = await args.predictGroupRpe(groupId);
  const tags = [...new Set(recs.map((r) => r.tag).filter(Boolean))];
  const note = [
    `${recs.length} recording${recs.length === 1 ? "" : "s"}`,
    ...(tags.length ? [tags.join(", ")] : []),
  ].join(" · ");
  // Total time = the recordings' actual span (first rep start → last rep end),
  // not the raw wall-clock, so idle time before/after reps doesn't inflate it.
  // Falls back to the wall-clock estimate if the recordings aren't loaded
  // yet. #487 (F3): computeGroupDurationMin clamps to the DB's 1..600
  // duration_min bound (src/lib/duration.ts) — insertTindeqSession also
  // clamps at the write itself, so this couldn't reach the DB out of range,
  // but computing it pre-clamped here keeps the two duration paths
  // (recalcTindeqSessionDuration is the other) sharing one implementation.
  const durationMin = computeGroupDurationMin(recs) ?? wallClockMin;

  return args.onLogSession({
    durationMin,
    rpe: predicted.rpe,
    note,
    groupId,
    rpeConfirmed: false,
  });
}

/// #613: predict a gauge session's RPE from the session's recordings snapshot
/// and the last successfully fetched tag-curve registry — SYNCHRONOUSLY, with
/// no network. The curve registry is a plain cache (the Force view refreshes
/// it in the background and on every fresh fit), so a tag with no cached curve
/// falls back immediately instead of waiting out a fetch. Extracted from
/// ForceView's `predictGroupRpe` so the cache→prediction mapping is pure and
/// testable; the fallback semantics are `predictSessionRpe`'s own.
export function predictGaugeSessionRpe(
  recs: readonly TindeqRecordingMeta[],
  curves: readonly TagCurve[],
): PredictedRpe {
  const byTagModality = new Map(
    curves.map((curve) => [`${curve.name}|${curve.modality}`, curve]),
  );
  return predictSessionRpe(
    recs.map((r) => ({
      peakKg: r.peakKg!,
      durationS: r.durationMs / 1000,
      cf:
        byTagModality.get(`${r.tag}|${recordingCapacityModality(r)}`)?.cf ?? null,
      wPrime:
        byTagModality.get(`${r.tag}|${recordingCapacityModality(r)}`)?.wPrime ??
        null,
      isEffort: isDepletionEffortRecording(r),
    })),
  );
}

/// #613: tracks how many per-rep durable saves are still in flight, so the
/// session-end path can wait for the final rep before snapshotting. `begin()`
/// MUST run synchronously before the save's first await (the same claim-before-
/// await rule as `claimed` above); `finish()` runs once the rep is durable and
/// locally published, so `waitForIdle()` resolves when every captured rep is
/// safe on-device — never when the network insert completes.
export interface RepSettlement {
  begin(): void;
  finish(): void;
  waitForIdle(): Promise<void>;
}

export function createRepSettlement(): RepSettlement {
  let inFlight = 0;
  const waiters: (() => void)[] = [];
  return {
    begin() {
      inFlight += 1;
    },
    finish() {
      inFlight = Math.max(0, inFlight - 1);
      if (inFlight === 0) {
        while (waiters.length > 0) waiters.shift()!();
      }
    },
    waitForIdle() {
      const idle =
        inFlight === 0
          ? Promise.resolve()
          : new Promise<void>((resolve) => waiters.push(resolve));
      // Let the pending React state updates from `finish()` commit before the
      // caller snapshots: the caller's recordings list is a ref kept in sync
      // with state by an effect, so the render must land first. React 18
      // flushes async-setState in a microtask; a macrotask after it
      // deterministically observes the committed render.
      return idle.then(
        () => new Promise<void>((resolve) => setTimeout(resolve, 0)),
      );
    },
  };
}
