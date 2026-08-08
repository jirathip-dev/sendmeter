import Sheet from "./Sheet";
import RecoveryStatsCard from "./RecoveryStatsCard";

/// Detail page for the recovery inputs behind the readiness score — opened from
/// the Readiness card (SL-39). The inputs live here rather than on the crowded
/// dashboard; the card is now a summary that drills into this.
export default function RecoverySheet({ onClose }: { onClose: () => void }) {
  return (
    <Sheet
      title="Recovery Inputs"
      subtitle="The raw HealthKit metrics your daily readiness score is computed from."
      onClose={onClose}
    >
      <RecoveryStatsCard />
    </Sheet>
  );
}
