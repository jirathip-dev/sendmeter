import { useState } from "react";
import { trendChartRecordings } from "../lib/forceTrend";
import type { ForceCurveModel, PeriodCurve } from "../lib/force-curve";
import type { TindeqRecordingMeta, TindeqSide } from "../types";
import ForceCurveCard from "./ForceCurveCard";
import ForceTrendChart from "./ForceTrendChart";
import Sheet from "./Sheet";
import SideAsymmetryCard from "./SideAsymmetryCard";

interface Props {
  recordings: TindeqRecordingMeta[];
  selectedTag: string | null;
  selectedSide: TindeqSide | null;
  model: ForceCurveModel | null;
  periods: PeriodCurve[];
  computing: boolean;
  error: string | null;
}

type Detail = "static" | "movement";

function metric(value: number | null | undefined, suffix = ""): string {
  return value == null ? "—" : `${value.toFixed(1)}${suffix}`;
}

export default function ForceProgressCard({
  recordings,
  selectedTag,
  selectedSide,
  model,
  periods,
  computing,
  error,
}: Props) {
  const [detail, setDetail] = useState<Detail | null>(null);
  const staticRows = trendChartRecordings(recordings, selectedTag, selectedSide, "static");
  const staticRecent = staticRows
    .filter((recording) => recording.peakKg !== null)
    .sort((a, b) => a.recordedAt.localeCompare(b.recordedAt))
    .slice(-8);
  const staticBest = staticRecent.length
    ? Math.max(...staticRecent.map((recording) => recording.peakKg!))
    : null;
  const staticLatest = staticRecent.at(-1)?.peakKg ?? null;
  const staticMax = staticBest ?? 1;

  const movementRows = recordings
    .filter((recording) =>
      recording.protocolMode === "reverse_action" &&
      (selectedTag === null || recording.tag === selectedTag) &&
      (selectedSide === null || recording.side === selectedSide) &&
      recording.setMetrics != null,
    )
    .sort((a, b) => a.recordedAt.localeCompare(b.recordedAt));
  const movementRecent = movementRows.slice(-8);
  const latestMovement = movementRecent.at(-1)?.setMetrics ?? null;
  const completion = latestMovement?.cadenceAdherencePct ?? null;
  const movementMax = 100;

  return (
    <section className="force-progress-stack" aria-labelledby="force-progress-title">
      <div className="label-eyebrow" id="force-progress-title">Progress &amp; insights</div>
      <div className="force-progress-grid">
        <button
          type="button"
          className="card surface-force force-progress-card"
          onClick={() => setDetail("static")}
          aria-label="Open Static capacity progress and insights"
        >
          <span className="force-progress-heading">
            <span className="force-progress-title">Static capacity{selectedTag ? ` · ${selectedTag}` : ""}</span>
            <span aria-hidden="true" className="force-progress-chevron">›</span>
          </span>
          {staticRecent.length ? (
            <>
              <span className="force-progress-metrics">
                <span><b>{metric(staticLatest)}</b><small>Latest kg</small></span>
                <span><b>{metric(staticBest)}</b><small>Best kg</small></span>
                <span><b>{staticRows.length}</b><small>Recordings</small></span>
              </span>
              <span className="force-mini-bars" aria-label={`Recent Static peaks: ${staticRecent.map((recording) => `${recording.peakKg!.toFixed(1)} kilograms`).join(", ")}`}>
                {staticRecent.map((recording) => (
                  <span key={recording.id} style={{ height: `${Math.max(12, (recording.peakKg! / staticMax) * 100)}%` }} />
                ))}
              </span>
            </>
          ) : (
            <span className="force-progress-empty">
              {computing ? "Updating your Static capacity…" : error ?? "Complete a measured Static hold to start this capacity view."}
            </span>
          )}
        </button>

        <button
          type="button"
          className="card surface-force force-progress-card force-progress-movement"
          onClick={() => setDetail("movement")}
          aria-label="Open resisted-movement progress and insights"
        >
          <span className="force-progress-heading">
            <span className="force-progress-title">Resisted movement{selectedTag ? ` · ${selectedTag}` : ""}</span>
            <span aria-hidden="true" className="force-progress-chevron">›</span>
          </span>
          {latestMovement ? (
            <>
              <span className="force-progress-metrics">
                <span><b>{metric(completion, "%")}</b><small>Completed</small></span>
                <span><b>{metric(latestMovement.meanKg)}</b><small>Mean kg</small></span>
                <span><b>{metric(latestMovement.coefficientVariationPct, "%")}</b><small>Variation</small></span>
              </span>
              <span className="force-mini-bars" aria-label={`Recent movement completion: ${movementRecent.map((recording) => `${recording.setMetrics?.cadenceAdherencePct.toFixed(1) ?? "0.0"} percent`).join(", ")}`}>
                {movementRecent.map((recording) => (
                  <span key={recording.id} style={{ height: `${Math.max(12, ((recording.setMetrics?.cadenceAdherencePct ?? 0) / movementMax) * 100)}%` }} />
                ))}
              </span>
            </>
          ) : (
            <span className="force-progress-empty">Complete a measured movement set to see completion, mean force, stability, accuracy and drift.</span>
          )}
        </button>
      </div>

      {detail === "static" && (
        <Sheet title="Static capacity" subtitle={`${selectedTag ?? "All exercises"}${selectedSide ? ` · ${selectedSide}` : ""}`} onClose={() => setDetail(null)} fullHeight>
          {staticRows.length >= 2 ? (
            <>
              <ForceTrendChart recordings={recordings} selectedTag={selectedTag} selectedSide={selectedSide} modality="static" />
              {selectedTag && <ForceCurveCard tag={selectedSide ? `${selectedTag} · ${selectedSide}` : selectedTag} model={model} periods={model ? periods : []} computing={computing} error={error} modality="static" />}
              {selectedTag && <SideAsymmetryCard recordings={recordings.filter((recording) => recording.tag === selectedTag)} modality="static" />}
            </>
          ) : (
            <div className="force-progress-empty">Complete a couple of measured Static holds to unlock the trend and force-duration model.</div>
          )}
        </Sheet>
      )}

      {detail === "movement" && (
        <Sheet title="Resisted movement" subtitle={`${selectedTag ?? "All exercises"}${selectedSide ? ` · ${selectedSide}` : ""}`} onClose={() => setDetail(null)} fullHeight>
          {latestMovement ? (
            <div className="movement-insight-detail">
              <div className="movement-insight-grid">
                <div><b>{metric(completion, "%")}</b><span>Clock completed</span></div>
                <div><b>{metric(latestMovement.meanKg, " kg")}</b><span>Mean force</span></div>
                <div><b>{metric(latestMovement.coefficientVariationPct, "%")}</b><span>Variation (CV)</span></div>
                <div><b>{metric(latestMovement.inTargetPct, "%")}</b><span>{latestMovement.inTargetPct == null ? "Accuracy · no target" : "Target accuracy"}</span></div>
                <div><b>{metric(latestMovement.driftPct, "%")}</b><span>Force drift</span></div>
                <div><b>{movementRows.length}</b><span>Measured sets</span></div>
              </div>
              <p className="force-progress-explainer">Movement is tracked as execution quality. It never changes your Static PR, Hill/CF model or asymmetry.</p>
            </div>
          ) : (
            <div className="force-progress-empty">No measured resisted-movement sets for this exercise and side yet.</div>
          )}
        </Sheet>
      )}
    </section>
  );
}
