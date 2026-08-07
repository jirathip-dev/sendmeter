import type { HealthClearOutcome } from "../lib/healthClearOutcome";

/// #487 (F4) / review findings 2 & 6: the "Clear health data & resync" flow
/// hard-deletes health_metrics (irreversible — see repo/health.ts's
/// deleteHealthMetrics) THEN calls resyncHealthHistory to rebuild it. This is
/// the one component that decides whether the user is told the truth about
/// what happened next: a green "resyncing" claim when the rebuild actually
/// failed is exactly the CLAUDE.md #264 pattern this issue exists to close,
/// on the one irreversible action in the app.
///
/// Pulled out of AccountSheet as its own component specifically so this
/// decision is unit-testable: AccountSheet's `clearOutcome` is internal
/// `useState`, and this repo's component tests render via
/// `renderToStaticMarkup` (no jsdom, no simulated clicks) — that can only
/// exercise a component's initial render for given PROPS, never a state
/// transition. Making `outcome` a prop here is what makes every branch
/// reachable from a test at all.
///
/// #494 (N4) / review finding F2: `outcome` is a THREE-state
/// `HealthClearOutcome`, not a `resyncFailed` boolean — a resync that
/// reports failure (`ok: false`) can mean either "there was nothing to
/// rebuild" (a genuinely empty HealthKit history) or "HealthKit access is
/// denied" (also zero rows), and those two cannot be told apart from here.
/// A first version of this fix routed BOTH into the green "resyncing"
/// success copy — wrong, since a denied-access user then gets told a resync
/// is happening when it isn't, on the one irreversible action in the app.
/// The `nothingToClear` branch is the honest middle ground: true regardless
/// of which of the two caused it, promises no resync, and does not send the
/// user chasing the "run it again" remedy that only fixes the `failed` case.
///
/// `native` is a prop for the same "must be reachable from a render" reason
/// (#494 N5): the success copy used to unconditionally say "Your device
/// will re-sync fresh metrics" even on web, where `resyncHealthHistory` is a
/// documented no-op (health ingestion is iPhone-only — see CLAUDE.md) —
/// nothing on that device is about to resync anything. `#487`'s own test
/// PINNED that false string; fixing it needs the platform reachable here,
/// same as `outcome`.
export default function HealthClearedStatus({
  outcome,
  native,
}: {
  outcome: HealthClearOutcome;
  native: boolean;
}) {
  if (outcome === "failed") {
    return (
      <div style={{ fontSize: "var(--t-sm)", color: "var(--warning)", lineHeight: 1.5 }}>
        Health data cleared, but the resync failed — your history wasn't
        rebuilt. Reopening the app only refreshes today's score, not the rest
        of your history. Close this screen and run Clear & resync again to
        retry — safe, since there's nothing left to delete.
      </div>
    );
  }
  if (outcome === "nothingToClear") {
    return (
      <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", lineHeight: 1.5 }}>
        There was no Health history stored to clear or resync.
      </div>
    );
  }
  if (!native) {
    return (
      <div style={{ fontSize: "var(--t-sm)", color: "var(--success)", lineHeight: 1.5 }}>
        Health data cleared. Resyncing only happens on the iPhone app — open
        it to rebuild your recent history from Apple Health.
      </div>
    );
  }
  return (
    <div style={{ fontSize: "var(--t-sm)", color: "var(--success)", lineHeight: 1.5 }}>
      Health data cleared. Your device will re-sync fresh metrics from Apple
      Health shortly.
    </div>
  );
}
