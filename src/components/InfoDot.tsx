import { useState } from "react";
import Sheet from "./Sheet";

export type InfoTopic = "acwr" | "readiness" | "forceCurve" | "gaugeTarget";

const CONTENT: Record<
  InfoTopic,
  {
    title: string;
    body: { heading: string; text: string }[];
  }
> = {
  acwr: {
    title: "How ACWR is calculated",
    body: [
      {
        heading: "Session load",
        text: "Every session gets a load in arbitrary units (AU) = duration (min) × RPE (1–10) — the session-RPE method, a simple and validated way to quantify how much training your body absorbed.",
      },
      {
        heading: "Acute : Chronic Workload Ratio",
        text: "ACWR compares what you did recently (acute ≈ last 7 days) with what you're adapted to (chronic ≈ last 28 days). Sendmeter uses exponentially-weighted moving averages, which weight recent days more heavily than simple rolling averages.",
      },
      {
        heading: "Risk zones",
        text: "0.8–1.3 is the commonly-cited 'sweet spot'; above ~1.5 injury risk rises sharply (load spiking faster than adaptation). Below 0.8 you're detraining relative to your base. The phase banner shows a phase-specific target band — a power phase legitimately runs lower than a capacity phase.",
      },
      {
        heading: "Take it as a guide",
        text: "ACWR is a screening heuristic, not a prescription. Treat sustained red zones as a prompt to look at sleep, finger niggles and volume — not as a hard rule.",
      },
    ],
  },
  readiness: {
    title: "How Readiness is calculated",
    body: [
      {
        heading: "Inputs",
        text: "Overnight HRV, resting heart rate, and sleep duration from Apple Health (any wearable that writes to it), each compared against YOUR own rolling baseline — plus a penalty when recent training load is high.",
      },
      {
        heading: "The model",
        text: "Each input becomes a z-score against your personal multi-week baseline. Higher HRV and lower resting HR than usual push the score up; short sleep and heavy recent load pull it down. The result is clamped to 0–100.",
      },
      {
        heading: "Reading it",
        text: "It's a trend tool: single days are noisy (alcohol, heat, late meals all move HRV). A multi-day slide — especially HRV down AND resting HR up — is the meaningful signal to back off intensity. It needs about a week of overnight data to build a baseline.",
      },
    ],
  },
  gaugeTarget: {
    title: "How zone targets are recommended",
    body: [
      {
        heading: "Anchored to YOUR curve",
        text: "Each zone is a percentage band of your own force–duration fit for the selected exercise (and side): POWER and STRENGTH anchor to your max force; POW END and ENDURANCE anchor to your critical force (CF) — the sustainable ceiling from the fit.",
      },
      {
        heading: "Why %max vs %CF",
        text: "Short maximal efforts (<10s) are limited by maximal recruitment, so power/strength work is prescribed off max. Longer efforts are limited by the forearm's aerobic ceiling, so endurance work is prescribed off CF — just below CF extends capacity, just above it trains your anaerobic reserve.",
      },
      {
        heading: "Using a target",
        text: "Picking a zone draws its band on the live gauge and arms its guided timer — keep the trace inside the band for the prescribed work time. Zones sharpen as your curve gets more data (especially one all-out 30–60s hold).",
      },
    ],
  },
  forceCurve: {
    title: "How the Force Curve works",
    body: [
      {
        heading: "Force–duration curve",
        text: "From your recordings, the best average force you can hold for every window length (1s…120s) is extracted. Huge force for seconds, much less for minutes — the decay between them is highly individual and trainable.",
      },
      {
        heading: "Critical force (CF) & W′",
        text: "The curve is fitted with the hyperbolic critical-power model adapted to fingers: F(t) = CF + W′/t. CF is the force you can theoretically sustain 'indefinitely' (the forearm's aerobic ceiling); W′ is the fixed anaerobic reserve above CF you can spend before failing. The fit needs at least one long (30–60s+) all-out hold to be trustworthy.",
      },
      {
        heading: "Training zones",
        text: "The POWER / STRENGTH / POW END / ENDURANCE targets are percentage bands anchored to your max force and CF. They translate the fit into 'hang at X kg for Y seconds' prescriptions.",
      },
    ],
  },
};

/// Small circled "?" that opens a plain-language explainer sheet for how the
/// number is computed.
export default function InfoDot({ topic }: { topic: InfoTopic }) {
  const [open, setOpen] = useState(false);
  const c = CONTENT[topic];

  return (
    // display:contents + stopPropagation: the dot often lives inside a
    // tappable card (e.g. ReadinessCard opens its detail sheet on click) —
    // nothing from the explainer, including its Close/backdrop clicks, may
    // bubble into the host card's onClick.
    <span style={{ display: "contents" }} onClick={(e) => e.stopPropagation()}>
      <button
        aria-label={`About: ${c.title}`}
        onClick={() => setOpen(true)}
        style={{
          width: 18,
          height: 18,
          borderRadius: "50%",
          border: "1px solid var(--border)",
          background: "transparent",
          color: "var(--ink-faint)",
          fontSize: "var(--t-xs)",
          lineHeight: 1,
          cursor: "pointer",
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          padding: 0,
          fontFamily: "Inter, sans-serif",
          flexShrink: 0,
        }}
      >
        ?
      </button>
      {open && (
        <Sheet onClose={() => setOpen(false)}>
          {/* The dot often sits inside an uppercase eyebrow label — undo any
              inherited text styling for the sheet body. */}
          <div style={{ textTransform: "none", letterSpacing: "normal", textAlign: "left" }}>
            <div
              style={{
                fontFamily: "Inter, sans-serif",
                fontSize: "var(--t-lg)",
                fontWeight: 800,
                marginBottom: 12,
              }}
            >
              {c.title}
            </div>
            {c.body.map((b) => (
              <div key={b.heading} style={{ marginBottom: 14 }}>
                <div
                  style={{
                    fontSize: "var(--t-xs)",
                    fontWeight: 700,
                    color: "var(--ink)",
                    marginBottom: 4,
                    fontFamily: "Inter, sans-serif",
                  }}
                >
                  {b.heading}
                </div>
                <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", lineHeight: 1.6 }}>
                  {b.text}
                </div>
              </div>
            ))}
            <div style={{ marginTop: 14 }}>
              <button className="btn-ghost" onClick={() => setOpen(false)}>
                Close
              </button>
            </div>
          </div>
        </Sheet>
      )}
    </span>
  );
}
