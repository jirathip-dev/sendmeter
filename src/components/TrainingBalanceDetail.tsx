import type { ReactNode } from "react";
import { dateStr } from "../lib/dates";
import { QUALITIES, type TrainingQuality } from "../lib/force-curve";
import { holdsInWindow } from "../lib/zoneBreakdown";
import {
  balanceScopeCounts,
  CURVE_BIAS_RATIO,
  TIE_BAND_SETS,
  type ZoneRecommendation,
} from "../lib/zoneHistory";
import { QUALITY_COLORS } from "../lib/zoneSelection";
import type { TindeqRecordingMeta } from "../types";
import Sheet from "./Sheet";
import ZoneBreakdownPanel from "./ZoneBreakdownPanel";

interface Props {
  /// Every recording for the active exercise (unwindowed) — the page applies
  /// the same trailing window the card does.
  recordings: TindeqRecordingMeta[];
  exercise: string;
  now: Date;
  windowDays: number;
  /// The card's own numbers, passed down rather than recomputed, so the page
  /// can never quote a different figure than the bars behind it.
  sets: Record<TrainingQuality, number>;
  rec: ZoneRecommendation;
  onClose: () => void;
}

const fmt1 = (n: number) => (Math.round(n * 10) / 10).toFixed(1);
const zoneLabel = (z: TrainingQuality) => QUALITIES.find((q) => q.id === z)!.label;

function Section({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="label-eyebrow" style={{ marginBottom: 8 }}>
        {title}
      </div>
      {children}
    </div>
  );
}

function ScopeRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div style={{ marginBottom: 10 }}>
      <div style={{ fontSize: "var(--t-2xs)", fontWeight: 700, color: "var(--ink)" }}>
        {label}
      </div>
      <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", lineHeight: 1.6 }}>
        {children}
      </div>
    </div>
  );
}

/// #214 — the training-balance card's own page. The card can only ever be a
/// summary; this is where its scope is stated outright and every number is
/// traced back to the holds that produced it, because the same training used
/// to read differently here and in History with nothing on screen explaining
/// why.
export default function TrainingBalanceDetail({
  recordings,
  exercise,
  now,
  windowDays,
  sets,
  rec,
  onClose,
}: Props) {
  const since = dateStr(new Date(now.getTime() - windowDays * 86_400_000));
  // Scoped with the same filter the bars use (`holdsInWindow`), not a second
  // copy of the cutoff rule.
  const windowRecs = holdsInWindow(recordings, now, windowDays);
  // The two sentences below describe what fed the numbers on THIS page —
  // Maintenance holds don't (zoneSets drops them), so counting them here
  // would make both sentences literally false. `windowRecs` (unfiltered)
  // still goes to ZoneBreakdownPanel below, which states the maintenance count on
  // its own "excluded" line instead of silently folding it into these totals.
  const { effortCount, recordedCount: recorded } = balanceScopeCounts(windowRecs);
  const d = rec.detail;
  const tiedOthers = d.tied.filter((z) => z !== rec.zone);

  return (
    <Sheet
      title="Training balance"
      subtitle={`${exercise} · last ${Math.round(windowDays / 7)} weeks`}
      onClose={onClose}
      fullHeight
    >
      <Section title="What this counts">
        <ScopeRow label="One exercise">
          Only holds tagged <strong>{exercise}</strong> count. Every other
          exercise is excluded, so this is the balance of one exercise, not of
          your training as a whole.
        </ScopeRow>
        <ScopeRow label="One window">
          The last {windowDays} days (since {since}). Anything older is excluded,
          however much of it there is.
        </ScopeRow>
        <ScopeRow label="Both sides">
          Left, right and both-hands holds all count toward the same balance.
        </ScopeRow>
        <ScopeRow label="Sets, not sessions">
          Each zone's total hold time divided by that zone's own protocol set
          length, so a 5-minute warm-up registers as a fraction of a set instead
          of a whole session. {effortCount} recording
          {effortCount === 1 ? "" : "s"} fed the numbers below.
        </ScopeRow>
        {/* #259: the page's numbers are part fact, part inference — say how
            much of each rather than letting the reader assume all fact. */}
        <ScopeRow label="Recorded vs inferred zones">
          {recorded === 0 ? (
            <>
              None of these holds store the zone they were performed under, so
              every one is bucketed by how long it lasted. Only holds recorded
              under an armed zone or preset carry the real thing.
            </>
          ) : (
            <>
              {recorded} of {effortCount} hold
              {effortCount === 1 ? "" : "s"} store the zone they were
              performed under and are counted as that;{" "}
              {effortCount - recorded === 0
                ? "none are inferred"
                : `the other ${effortCount - recorded} have it inferred from hold length`}
              .
            </>
          )}
        </ScopeRow>
        <ScopeRow label="Why History reads differently">
          History lists every session for every exercise over all time, and
          badges each one with the zone that session alone was mostly in. It's a
          different measurement over a different scope — the two are expected to
          disagree, and neither is wrong.
        </ScopeRow>
      </Section>

      <Section title="Where each number comes from">
        <ZoneBreakdownPanel recs={windowRecs} />
      </Section>

      <Section title={`Why ${zoneLabel(rec.zone)} is recommended`}>
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontWeight: 800,
            fontSize: "var(--t-md)",
            color: QUALITY_COLORS[rec.zone],
            marginBottom: 6,
          }}
        >
          {zoneLabel(rec.zone)}
        </div>
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)", lineHeight: 1.7 }}>
          <div>
            Least-trained zone wins. The lowest of the four is{" "}
            {fmt1(d.minSets)} set{fmt1(d.minSets) === "1.0" ? "" : "s"}; {zoneLabel(rec.zone)} is at{" "}
            {fmt1(sets[rec.zone])}.
          </div>
          {tiedOthers.length > 0 ? (
            <div style={{ marginTop: 6 }}>
              Within {TIE_BAND_SETS} sets of that minimum, so treated as tied:{" "}
              {d.tied.map((z) => `${zoneLabel(z)} ${fmt1(sets[z])}`).join(" · ")}.
            </div>
          ) : (
            <div style={{ marginTop: 6 }}>
              No other zone is within {TIE_BAND_SETS} sets of it, so there was no
              tie to break.
            </div>
          )}
          {d.curveRatio === null ? (
            <div style={{ marginTop: 6 }}>
              No critical-force fit yet, so the force curve had no say — the
              least-trained zone stands on its own.
            </div>
          ) : (
            <div style={{ marginTop: 6 }}>
              Your critical force is {Math.round(d.curveRatio * 100)}% of your
              predicted 5s peak —{" "}
              {d.curveBias === "endurance"
                ? `under ${Math.round(CURVE_BIAS_RATIO * 100)}%, which reads as endurance-limited`
                : `at or over ${Math.round(CURVE_BIAS_RATIO * 100)}%, which reads as strength-limited`}
              .{" "}
              {tiedOthers.length === 0
                ? "With no tie to break, it changed nothing here."
                : d.biasChangedPick
                  ? `That broke the tie toward the ${d.curveBias} side, over ${zoneLabel(d.unbiasedZone)}.`
                  : `That points at the same zone the set counts already did (${zoneLabel(d.unbiasedZone)}), so it changed nothing.`}
            </div>
          )}
          <div style={{ marginTop: 6, color: "var(--ink-faint)" }}>
            Tapping the recommendation on the card arms this zone's guided
            protocol for {exercise}.
          </div>
        </div>
      </Section>
    </Sheet>
  );
}
