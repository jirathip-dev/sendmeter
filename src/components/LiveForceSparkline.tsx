import { useEffect, useRef, useState } from "react";
import { useSvgScale } from "../hooks/useSvgScale";
import type { LiveForceSample } from "../hooks/useLiveForce";

const H = 44;
const PAD = { top: 4, right: 2, bottom: 2, left: 2 };
// A gap this big between consecutive accumulated points means real dead time
// (the rest between reps, or the watch screen closing briefly) rather than
// just the ~500ms beat cadence — split into separate line runs there instead
// of drawing a straight line across the pause, same idea as WorkoutHrChart's
// sensor-gap runs.
const RUN_GAP_MS = 1_500;

/// Live sparkline for the phone's "Live on watch" Force mirror (SL-95,
/// follow-up to SL-87). Purely decorative/at-a-glance — no hover, no axes —
/// unlike the fuller HR/recording charts it's styled after: `samples` is
/// already the accumulated rolling buffer from useLiveForce (wall-clock
/// `atMs`, oldest first).
export default function LiveForceSparkline({ samples }: { samples: LiveForceSample[] }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const [W, setW] = useState(300);
  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setW(Math.max(120, el.clientWidth)));
    ro.observe(el);
    setW(Math.max(120, el.clientWidth));
    return () => ro.disconnect();
  }, []);

  // Hooks must run unconditionally — compute safe fallbacks and bail out
  // (render nothing) below, after useSvgScale, when there's not enough data.
  const t0 = samples[0]?.atMs ?? 0;
  const tMax = (samples.length ? samples[samples.length - 1]!.atMs - t0 : 0) || 1;
  const kgMax = Math.max(...samples.map((s) => s.kg), 10) * 1.15;
  const { x: px, y: py } = useSvgScale(W, H, PAD, 0, tMax, 0, kgMax);

  if (samples.length < 2) return null;

  // Split into runs at real gaps (rest between reps, or the watch briefly
  // going unreachable) so the line doesn't bridge dead time.
  const runs: LiveForceSample[][] = [];
  let run: LiveForceSample[] = [samples[0]!];
  for (let i = 1; i < samples.length; i++) {
    const s = samples[i]!;
    if (s.atMs - samples[i - 1]!.atMs > RUN_GAP_MS) {
      if (run.length > 1) runs.push(run);
      run = [];
    }
    run.push(s);
  }
  if (run.length > 1) runs.push(run);

  const baseline = H - PAD.bottom;
  const areaPath = (r: LiveForceSample[]) =>
    `M ${px(r[0]!.atMs - t0).toFixed(1)},${baseline} ` +
    r.map((s) => `L ${px(s.atMs - t0).toFixed(1)},${py(s.kg).toFixed(1)}`).join(" ") +
    ` L ${px(r[r.length - 1]!.atMs - t0).toFixed(1)},${baseline} Z`;
  const linePoints = (r: LiveForceSample[]) =>
    r.map((s) => `${px(s.atMs - t0).toFixed(1)},${py(s.kg).toFixed(1)}`).join(" ");

  return (
    <div ref={hostRef} style={{ width: "100%", marginTop: 10 }}>
      <svg viewBox={`0 0 ${W} ${H}`} style={{ width: "100%", height: H, display: "block" }}>
        {runs.map((r, i) => (
          <g key={i}>
            <path d={areaPath(r)} fill="#5B5FC7" opacity="0.12" />
            <polyline
              points={linePoints(r)}
              fill="none"
              stroke="#5B5FC7"
              strokeWidth="1.5"
              vectorEffect="non-scaling-stroke"
            />
          </g>
        ))}
      </svg>
    </div>
  );
}
