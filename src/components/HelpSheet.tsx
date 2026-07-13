import type { ReactNode } from "react";
import Sheet from "./Sheet";

interface Props {
  onClose: () => void;
}

function Section({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div style={{ marginTop: 20 }}>
      <div className="label-eyebrow" style={{ marginBottom: 8 }}>
        {title}
      </div>
      <div style={{ fontSize: 12, color: "var(--ink-muted)", lineHeight: 1.6 }}>
        {children}
      </div>
    </div>
  );
}

export default function HelpSheet({ onClose }: Props) {
  return (
    <Sheet onClose={onClose}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: 20,
          fontWeight: 800,
          marginBottom: 4,
        }}
      >
        Help & FAQ
      </div>
        <div style={{ fontSize: 12, color: "var(--ink-faint)" }}>
          How the numbers on your dashboard are actually computed.
        </div>

        <Section title="Readiness score">
          <p style={{ margin: 0 }}>
            A daily 0–100 score blending HRV, resting heart rate, and sleep
            (each compared to your own trailing baseline) with your recent
            climbing load. It needs at least 7 days of watch data to start
            scoring HRV and resting HR individually — before that it'll show
            "—" or lean on whichever signal it has.
          </p>
          <p>
            <strong style={{ color: "var(--ink)" }}>Why SDNN, not RMSSD?</strong>{" "}
            Most sports-science HRV research favors RMSSD (it isolates
            parasympathetic/vagal tone more cleanly). Apple Watch only
            exposes SDNN through HealthKit though — that's an Apple platform
            limit, not a choice made here. SDNN is still a valid recovery
            signal, just not the one you'll see cited in most papers.
          </p>
          <p style={{ marginBottom: 0 }}>
            Deep sleep, REM sleep, and respiratory rate are also shown for
            context (Recovery Inputs card) but aren't folded into the score
            yet — they're new, and we'd rather show them plainly first than
            guess at a weighting.
          </p>
        </Section>

        <Section title="ACWR (Acute:Chronic Workload Ratio)">
          <p style={{ margin: 0 }}>
            Acute load (last 7 days) divided by chronic load (a smoothed
            28-day baseline), meant to flag "doing too much too soon." The
            0.8–1.3 zone is the commonly-cited "safer" range; above 1.5 is
            flagged as higher-risk.
          </p>
          <p style={{ marginBottom: 0 }}>
            The ratio itself uses an exponentially-weighted moving average
            (EWMA) rather than a plain rolling average — current research
            favors it as more statistically sound and more responsive to
            recent changes.{" "}
            <strong style={{ color: "var(--ink)" }}>
              Treat it as one input, not a verdict:
            </strong>{" "}
            the sports-science literature is explicit that ACWR alone isn't a
            strong standalone injury predictor. A high number is a prompt to
            pay attention, not a diagnosis.
          </p>
        </Section>

        <Section title="Not medical advice">
          <p style={{ margin: 0 }}>
            Everything here is a self-tracking heuristic built from consumer
            wearable data, not a clinical or diagnostic tool. If something
            feels persistently off — pain, unusual fatigue, illness — talk to
            an actual doctor or coach rather than reading it off a chart.
          </p>
        </Section>

      <div style={{ marginTop: 20 }}>
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      </div>
    </Sheet>
  );
}
