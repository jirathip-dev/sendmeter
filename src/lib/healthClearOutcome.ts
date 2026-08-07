/// #494 (N4): "Clear health data & resync" hard-deletes health_metrics
/// (irreversible, see repo/health.ts's deleteHealthMetrics) THEN calls
/// resyncHealthHistory to rebuild it. `resyncHealthHistory` reporting
/// `ok: false` used to always mean the amber "resync failed — your history
/// wasn't rebuilt" banner, with a remedy (retry) that fails every time for a
/// user whose HealthKit history is genuinely empty — the native
/// `HealthResyncFoundNoDataError` doc comment explains why "zero rows back"
/// can't be told apart from "access denied" via public API, so a failed
/// resync alone is not enough signal.
///
/// There's a cheap discriminator sitting unused: how many rows the delete
/// step actually removed. If nothing existed before the clear (`deletedCount
/// === 0`) and the rebuild then finds nothing either, no data was lost —
/// that's the expected shape for an empty history, not the destructive
/// silent-failure #487 (F4) exists to catch (a rebuild that comes back empty
/// AFTER wiping real rows). Only treat the resync failure as real when there
/// was something to lose.
export function healthClearFailed(deletedCount: number, resynced: boolean): boolean {
  if (resynced) return false;
  return deletedCount > 0;
}
