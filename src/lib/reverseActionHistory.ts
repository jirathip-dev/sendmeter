import type {
  CadenceMarker,
  ReverseActionSetMetrics,
} from "../types";

export interface ReverseActionMetricItem {
  label: string;
  value: string;
  explanation: string;
}

function finite(value: number | null | undefined): value is number {
  return value !== null && value !== undefined && Number.isFinite(value);
}

function percent(value: number | null): string {
  return finite(value) ? `${value.toFixed(1)}%` : "—";
}

/// Stable History copy for the set-level metrics stored with every Reverse
/// Action trace. Keeping this pure makes missing/partial values and the
/// prescribed-clock limitation reviewable without rendering React.
export function reverseActionMetricItems(
  metrics: ReverseActionSetMetrics | null,
  peakKg: number | null,
): ReverseActionMetricItem[] {
  return [
    {
      label: "Mean",
      value: finite(metrics?.meanKg) ? `${metrics.meanKg.toFixed(1)} kg` : "—",
      explanation: "Time-weighted mean while the trace was loaded.",
    },
    {
      label: "CV",
      value: percent(metrics?.coefficientVariationPct ?? null),
      explanation: "Force variability; lower is steadier.",
    },
    {
      label: "In target",
      value: percent(metrics?.inTargetPct ?? null),
      explanation: "Loaded time inside the saved target band.",
    },
    {
      label: "Tension",
      value: finite(metrics?.timeUnderTensionMs)
        ? `${(metrics.timeUnderTensionMs / 1_000).toFixed(1)}s`
        : "—",
      explanation: "Time at or above the loaded-force threshold.",
    },
    {
      label: "Drift",
      value: percent(metrics?.driftPct ?? null),
      explanation: "Late-quarter mean versus early-quarter mean.",
    },
    {
      label: "Cadence",
      value: percent(metrics?.cadenceAdherencePct ?? null),
      explanation: "Recorded trace duration versus prescribed set duration; not motion detection.",
    },
    {
      label: "Peak",
      value: finite(peakKg) ? `${peakKg.toFixed(1)} kg` : "—",
      explanation: "Highest sampled force; secondary to sustained-set quality.",
    },
  ];
}

export function cadenceMarkerLabel(marker: CadenceMarker): string {
  return `${marker.rep} ${marker.direction === "out" ? "CONCENTRIC" : "ECCENTRIC"}`;
}
