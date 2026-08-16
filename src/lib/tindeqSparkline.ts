import type { TindeqSample } from "../types";
import type { LiveForceSample } from "./liveForceMirror";

/// Rolling time window over the raw Tindeq sample buffer, shaped for a live
/// sparkline — the same `{atMs, kg}` shape the watch-mirror sparkline uses
/// (relative `atMs` deltas are all the chart reads, so the device-relative
/// sample `t` maps straight onto it). The default window matches ForceGauge's
/// `WINDOW_MS` and the watch's `recentSamples` default, so the movement
/// sparkline and its own force gauge always show the same 10s window.
export function recentSparklineSamples(
  samples: TindeqSample[],
  windowMs = 10_000,
): LiveForceSample[] {
  const last = samples[samples.length - 1];
  if (!last) return [];
  const cutoff = last.t - windowMs;
  const out: LiveForceSample[] = [];
  for (const s of samples) {
    if (s.t < cutoff) continue;
    out.push({ atMs: s.t, kg: s.kg });
  }
  return out;
}
