/// #494 (N4) / review finding F2: "Clear health data & resync" hard-deletes
/// health_metrics (irreversible, see repo/health.ts's deleteHealthMetrics)
/// THEN calls resyncHealthHistory to rebuild it. `resyncHealthHistory`
/// reporting `ok: false` used to always mean the amber "resync failed — your
/// history wasn't rebuilt" banner, with a remedy (retry) that fails every
/// time for a user whose HealthKit history is genuinely empty — the native
/// `HealthResyncFoundNoDataError` doc comment explains why "zero rows back"
/// can't be told apart from "access denied" via public API, so a failed
/// resync alone is not enough signal.
///
/// A first version of this fix routed `deletedCount === 0 && !resynced`
/// into the GREEN success branch ("Your device will re-sync fresh metrics
/// shortly") — wrong in the other direction, and worse: `deletedCount === 0`
/// does NOT distinguish "history was genuinely empty" from "HealthKit access
/// is denied" (a user who's never granted access also has zero rows, for
/// that reason). Claiming a resync is happening when access is denied is
/// the exact "claim success when it isn't" shape #487 (F4) exists to
/// prevent, now on native instead of web.
///
/// So this is a THIRD, neutral outcome, not a reclassification into
/// success: "nothing existed, nothing needed rebuilding" is true regardless
/// of whether the underlying cause was an empty history or a denied
/// permission — it must not promise a resync that isn't happening, and it
/// must not tell the user to retry a remedy (Clear & resync again) that
/// cannot fix a denied permission either. Only `deletedCount > 0 &&
/// !resynced` — real data existed and the rebuild came back empty — is the
/// actual data-loss shape worth the amber failure banner.
export type HealthClearOutcome = "resynced" | "nothingToClear" | "failed";

export function healthClearOutcome(
  deletedCount: number,
  resynced: boolean,
): HealthClearOutcome {
  if (resynced) return "resynced";
  if (deletedCount === 0) return "nothingToClear";
  return "failed";
}

/// #494 (N4) / review finding F4: the pure classification above was tested
/// in isolation, but `AccountSheet.runClearHealth` — the actual call site
/// that reads `deleteHealthMetrics`'/`resyncHealthHistory`'s return values
/// and decides what the user sees — had no test at all, which is exactly
/// where the F2 defect (routing the neutral case into the green success
/// toast) lived. This function IS that wiring, pulled out so it's the same
/// object under test as under production use, not a parallel re-derivation:
/// `runClearHealth` calls this with the two raw return values and does
/// nothing but forward the result into `setState`/`toast`.
export interface HealthClearResult {
  outcome: HealthClearOutcome;
  toast: string;
}

export function resolveHealthClearResult(
  deletedCount: number,
  resynced: boolean,
): HealthClearResult {
  const outcome = healthClearOutcome(deletedCount, resynced);
  const toast: Record<HealthClearOutcome, string> = {
    resynced: "Health data cleared · resyncing",
    nothingToClear: "Health data cleared — no Health history to resync.",
    failed:
      "Health data cleared, but the resync failed. Close this screen and run Clear & resync again.",
  };
  return { outcome, toast: toast[outcome] };
}
