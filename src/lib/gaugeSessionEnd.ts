import type { TindeqRecordingMeta } from "../types";

export interface EndGaugeSessionArgs {
  groupId: string;
  /// Fallback duration when no recordings have landed yet.
  wallClockMin: number;
  /// Groups already ended — checked-and-claimed synchronously, before the
  /// first `await` below.
  claimed: Set<string>;
  predictGroupRpe: (
    groupId: string,
  ) => Promise<{ predicted: { rpe: number }; recs: TindeqRecordingMeta[] }>;
  onLogSession: (input: {
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
    rpeConfirmed: false;
  }) => Promise<boolean>;
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

  const { predicted, recs } = await args.predictGroupRpe(groupId);
  const tags = [...new Set(recs.map((r) => r.tag).filter(Boolean))];
  const note = [
    `${recs.length} recording${recs.length === 1 ? "" : "s"}`,
    ...(tags.length ? [tags.join(", ")] : []),
  ].join(" · ");
  // Total time = the recordings' actual span (first rep start → last rep end),
  // not the raw wall-clock, so idle time before/after reps doesn't inflate it.
  // Falls back to the wall-clock estimate if the recordings aren't loaded yet.
  const spanMs = recs.length
    ? Math.max(...recs.map((r) => Date.parse(r.recordedAt) + r.durationMs)) -
      Math.min(...recs.map((r) => Date.parse(r.recordedAt)))
    : 0;
  const durationMin = recs.length
    ? Math.max(1, Math.round(spanMs / 60000))
    : wallClockMin;

  return args.onLogSession({
    durationMin,
    rpe: predicted.rpe,
    note,
    groupId,
    rpeConfirmed: false,
  });
}
