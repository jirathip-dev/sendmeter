/// #487 (F4) / review findings 2 & 6: the "Clear health data & resync" flow
/// hard-deletes health_metrics (irreversible — see repo/health.ts's
/// deleteHealthMetrics) THEN calls resyncHealthHistory to rebuild it. This is
/// the one line in AccountSheet that decides whether the user is told the
/// truth about what happened next: a green "resyncing" claim when the
/// rebuild actually failed is exactly the CLAUDE.md #264 pattern this issue
/// exists to close, on the one irreversible action in the app.
///
/// Pulled out of AccountSheet as its own component specifically so this
/// decision is unit-testable: AccountSheet's `cleared`/`resyncFailed` are
/// internal `useState`, and this repo's component tests render via
/// `renderToStaticMarkup` (no jsdom, no simulated clicks) — that can only
/// exercise a component's initial render for given PROPS, never a state
/// transition. Making `resyncFailed` a prop here is what makes the honest-vs-
/// dishonest branch reachable from a test at all.
///
/// `native` is a prop for the same reason (#494 N5): the success copy used
/// to unconditionally say "Your device will re-sync fresh metrics" even on
/// web, where `resyncHealthHistory` is a documented no-op (health ingestion
/// is iPhone-only — see CLAUDE.md) — nothing on that device is about to
/// resync anything. `#487`'s own test PINNED that false string; fixing it
/// needs the platform reachable from a render, same as `resyncFailed`.
export default function HealthClearedStatus({
  resyncFailed,
  native,
}: {
  resyncFailed: boolean;
  native: boolean;
}) {
  if (resyncFailed) {
    return (
      <div style={{ fontSize: "var(--t-sm)", color: "var(--warning)", lineHeight: 1.5 }}>
        Health data cleared, but the resync failed — your history wasn't
        rebuilt. Reopening the app only refreshes today's score, not the rest
        of your history. Close this screen and run Clear & resync again to
        retry — safe, since there's nothing left to delete.
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
