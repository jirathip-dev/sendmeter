import Sheet from "./Sheet";
import RecoveryStatsCard from "./RecoveryStatsCard";

/// Detail page for the recovery inputs behind the readiness score — opened from
/// the Readiness card (SL-39). The inputs live here rather than on the crowded
/// dashboard; the card is now a summary that drills into this.
export default function RecoverySheet({ onClose }: { onClose: () => void }) {
  return (
    <Sheet onClose={onClose}>
      <div style={{ fontFamily: "Inter, sans-serif", fontSize: "var(--t-xl)", fontWeight: 800 }}>
        Recovery Inputs
      </div>
      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 16 }}>
        The raw HealthKit metrics your daily readiness score is computed from.
      </div>
      <RecoveryStatsCard />
      <div style={{ marginTop: 12 }}>
        <button className="btn-ghost" onClick={onClose}>Close</button>
      </div>
    </Sheet>
  );
}
