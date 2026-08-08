import { useState } from "react";
import { useChartHover } from "../hooks/useChartHover";
import { QUALITIES } from "../lib/force-curve";
import type { ForceCurveModel, TrainingQuality } from "../lib/force-curve";
import { recommendZone, zoneTrainingSets } from "../lib/zoneHistory";
import { zoneBreakdownInWindow } from "../lib/zoneBreakdown";
import type { TindeqRecordingMeta } from "../types";
import { QUALITY_COLORS } from "../lib/zoneSelection";
import ChartTooltip from "./ChartTooltip";
import InfoDot from "./InfoDot";
import TrainingBalanceDetail from "./TrainingBalanceDetail";

interface Props {
  /// Recordings for the active exercise (already tag-filtered by ForceView).
  recordings: TindeqRecordingMeta[];
  /// The exercise those recordings are filtered to — named on the card,
  /// because "Training balance" alone reads as *your* balance when it is one
  /// exercise's (#214).
  exercise: string;
  model: ForceCurveModel | null;
  /// Arm the recommended zone on the gauge + guided timer (SL-100).
  onPick: (q: TrainingQuality) => void;
  /// #298 round 6 (finding A1): ForceView locks the gauge inputs for the
  /// whole duration of a run — arming a different zone mid-run must not be
  /// reachable any more than TargetZonesCard's own chips are.
  locked: boolean;
}

const WINDOW_DAYS = 28;

const fmt1 = (n: number) => (Math.round(n * 10) / 10).toFixed(1);

/// Training-balance card (SL-100, #182): how many duration-normalised sets
/// in the last 4 weeks you trained each quality on this exercise, and which
/// one to focus on next — the least-trained zone, with the force curve
/// breaking near-ties. Tapping the recommendation arms its guided zone
/// protocol; tapping the card opens the page that shows every number's
/// arithmetic (#214).
export default function ZoneFocusCard({ recordings, exercise, model, onPick, locked }: Props) {
  // `new Date()` is impure in render — freeze it once for this mount.
  const [now] = useState(() => new Date());
  const [detailOpen, setDetailOpen] = useState(false);
  const [hovered, hoverProps] = useChartHover<TrainingQuality>();
  const sets = zoneTrainingSets(recordings, now, WINDOW_DAYS);
  const rec = recommendZone(sets, model);
  // Hold seconds + hold count behind each bar, for the tooltip — the same
  // dividend the detail page shows the division of.
  const { zones } = zoneBreakdownInWindow(recordings, now, WINDOW_DAYS);
  if (!rec) return null;

  const maxSets = Math.max(1, ...QUALITIES.map((q) => sets[q.id]));

  return (
    <div
      className="card tappable"
      style={{ marginTop: 10 }}
      onClick={() => setDetailOpen(true)}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 6,
          marginBottom: 2,
        }}
      >
        {/* Scope in the title itself: which exercise, and the window. */}
        <div className="label-eyebrow">Training balance · {exercise}</div>
        <InfoDot topic="trainingBalance" />
        <span style={{ marginLeft: "auto", fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
          ›
        </span>
      </div>
      <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginBottom: 8 }}>
        Last 4 weeks · this exercise only · sets, not sessions
      </div>

      {/* Bars. `.chart-scrub` makes a horizontal drag scrub the tooltip
          instead of scrolling the page, and (per #171) mutes the delegated
          tap tick here — `useChartHover` already fires its own selection
          tick. The click guard keeps a scrub from opening the detail page. */}
      <div
        className="chart-scrub"
        role="img"
        aria-label={`Training balance for ${exercise}, last four weeks`}
        style={{ display: "flex", flexDirection: "column", gap: 5 }}
        onClick={(e) => e.stopPropagation()}
      >
        {QUALITIES.map((q) => {
          const n = sets[q.id];
          const rounded = Math.round(n * 10) / 10;
          const color = QUALITY_COLORS[q.id];
          const zb = zones[q.id];
          return (
            // The whole row is the hit area — an 8px bar is too thin to hit
            // with a finger.
            <div
              key={q.id}
              style={{
                position: "relative",
                display: "flex",
                alignItems: "center",
                gap: 8,
                cursor: "pointer",
              }}
              {...hoverProps(q.id)}
            >
              {hovered === q.id && (
                // The card clips its overflow (`.card.tappable`), so the top
                // row's tooltip is flipped below the row rather than being
                // cut off above it.
                <ChartTooltip
                  style={
                    q.id === QUALITIES[0]!.id
                      ? { bottom: "auto", top: "100%", marginBottom: 0, marginTop: 6 }
                      : undefined
                  }
                >
                  {fmt1(zb.sets)} set{fmt1(zb.sets) === "1.0" ? "" : "s"} ·{" "}
                  {fmt1(zb.totalHoldS)}s of holds over {zb.holds.length} hold
                  {zb.holds.length === 1 ? "" : "s"}
                </ChartTooltip>
              )}
              <span
                style={{
                  fontSize: "var(--t-xs)",
                  color: "var(--ink)",
                  width: 74,
                  flexShrink: 0,
                }}
              >
                {q.label}
              </span>
              <div
                role="img"
                aria-label={`${q.label}: ${rounded} set${rounded === 1 ? "" : "s"}`}
                style={{
                  flex: 1,
                  height: 8,
                  borderRadius: 4,
                  background: "var(--surface-1)",
                  overflow: "hidden",
                }}
              >
                <div
                  style={{
                    width: `${(n / maxSets) * 100}%`,
                    height: "100%",
                    background: `linear-gradient(90deg, color-mix(in srgb, ${color} 60%, var(--canvas)), ${color})`,
                    borderRadius: 4,
                    opacity: hovered === null || hovered === q.id ? 1 : 0.45,
                  }}
                />
              </div>
              <span
                style={{
                  fontSize: "var(--t-2xs)",
                  color: "var(--ink-muted)",
                  width: 46,
                  textAlign: "right",
                  flexShrink: 0,
                }}
              >
                {rounded} set{rounded === 1 ? "" : "s"}
              </span>
            </div>
          );
        })}
      </div>

      {/* Focus recommendation — tap to arm its guided zone. */}
      <button
        onClick={(e) => {
          e.stopPropagation(); // arming the zone is not "open the detail page"
          onPick(rec.zone);
        }}
        disabled={locked}
        style={{
          marginTop: 12,
          width: "100%",
          textAlign: "left",
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "10px 12px",
          borderRadius: 10,
          border: `1px solid ${QUALITY_COLORS[rec.zone]}`,
          background: `color-mix(in srgb, ${QUALITY_COLORS[rec.zone]} 12%, transparent)`,
          cursor: locked ? "default" : "pointer",
          opacity: locked ? 0.6 : 1,
          fontFamily: "inherit",
        }}
      >
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>
            FOCUS NEXT
          </div>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontWeight: 800,
              fontSize: "var(--t-md)",
              color: QUALITY_COLORS[rec.zone],
            }}
          >
            {QUALITIES.find((q) => q.id === rec.zone)?.label}
          </div>
          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", marginTop: 2 }}>
            {rec.reason}
          </div>
        </div>
        <span
          style={{
            fontSize: "var(--t-xs)",
            fontWeight: 700,
            color: QUALITY_COLORS[rec.zone],
            flexShrink: 0,
          }}
        >
          Arm ›
        </span>
      </button>

      {detailOpen && (
        <div onClick={(e) => e.stopPropagation()} style={{ cursor: "default" }}>
          <TrainingBalanceDetail
            recordings={recordings}
            exercise={exercise}
            now={now}
            windowDays={WINDOW_DAYS}
            sets={sets}
            rec={rec}
            onClose={() => setDetailOpen(false)}
          />
        </div>
      )}
    </div>
  );
}
