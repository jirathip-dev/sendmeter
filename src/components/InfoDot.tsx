import { useState } from "react";
import Sheet from "./Sheet";

export type InfoTopic =
  | "acwr"
  | "acwrProjection"
  | "readiness"
  | "forceCurve"
  | "gaugeTarget"
  | "phaseStepBack"
  | "trainingBalance"
  | "tindeqConsistency";

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
  acwrProjection: {
    title: "How the 7-day projection works",
    body: [
      {
        heading: "It assumes you train nothing",
        text: "Every day on this curve is a full rest day — no climbing, no board, no hangs. It is not a forecast of what will happen; it's what happens if you do nothing. Log a session and the curve is redrawn from the new number.",
      },
      {
        heading: "Why it slides down",
        text: "The acute (≈7-day) average decays faster than the chronic (≈28-day) one, so a rest day multiplies ACWR by about 0.81 — roughly 19% a day, and by the same factor whatever ratio you start from. From 1.20, two rest days already put you under 0.80.",
      },
      {
        heading: "Measured against your phase band",
        text: "The shaded band is the current phase's target band — the same one the phase strip shows — not the universal 0.8–1.3 risk zone. A power phase legitimately sits lower than a capacity phase, so the phase band is the honest comparison.",
      },
      {
        heading: "The session it quotes",
        text: "Session load is duration × RPE, so a load target is also a session. The suggestion prices the band floor at RPE 6 on the day the curve would drop out, assuming you rest until then. It's one day's arithmetic, not a training plan — the same load at a different RPE works just as well.",
      },
      {
        heading: "Seven days is the honest limit",
        text: "Every day you deviate from 'no training' the rest of the curve becomes fiction, and deviation is the normal case. A 4-week version would look more useful while being less true.",
      },
      {
        heading: "Readiness is today's, never projected",
        text: "HRV, resting heart rate and sleep can't be forecast — the readiness shown here is the current score, sitting alongside the projection rather than inside it.",
      },
      {
        heading: "A guardrail, not a target",
        text: "This card doesn't say whether to train. It shows what happens if you don't, and what it would take to change that; whether that's the right call is yours — readiness, how your fingers feel, and what's in the week all outrank a ratio.",
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
      {
        heading: "Why it doesn't change all day",
        text: "The score reflects your overnight recovery, so it locks at noon — later syncs keep the metric values below current (resting HR often finalizes mid-day) without rewriting the score. “Score as of” shows when it was computed.",
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
        text: "Picking a zone draws its band on the live gauge and arms its guided timer — keep the trace inside the band for the prescribed work time. Zones sharpen as your curve gets more data (especially one all-out 30–60s hold). The Intensity slider on this card (60–110%) applies to the RECOMMENDED ZONES only: it scales the target load and adapts hold time to keep the training dose equivalent — dial it down for a lighter session, or above 100% for a heavier one (shorter holds, extra strain on your pulleys — only when fully warmed up). Custom presets are never modified by this dial; a preset's quality badge still reflects whatever load it actually resolves to (fixed kg, or a %-of-PR/CF/curve target).",
      },
    ],
  },
  phaseStepBack: {
    title: "Why step back to Capacity",
    body: [
      {
        heading: "Two signals, closed loop",
        text: "The phase banner and Readiness are normally shown side by side — this nudge is the one place they talk to each other. Power and strength phases ask your nervous system for near-maximal output; that only works safely on top of good recovery.",
      },
      {
        heading: "The trigger",
        text: "Readiness sitting in the red 'recover' zone (below 40) for 3+ days in a row while you're in a power or strength phase. One rough night is noise — HRV wobbles with alcohol, heat, late meals. A multi-day slide is the meaningful signal.",
      },
      {
        heading: "It's a suggestion, not a rule",
        text: "Capacity work (volume, lower intensity) lets you keep training while your recovery catches up, instead of grinding a high-intensity phase on an empty tank. Dismiss it if you'd rather push through — it won't nag again for this same low streak.",
      },
    ],
  },
  trainingBalance: {
    title: "What Training balance counts",
    body: [
      {
        heading: "One exercise, four weeks",
        text: "Only holds tagged with the exercise named on the card, recorded in the last 28 days. Every other exercise is excluded, and so is anything older — so this is one exercise's balance, not your training as a whole. Left, right and both-hands holds all count toward it.",
      },
      {
        heading: "Sets, not sessions",
        text: "Each zone's total hold time in the window, divided by that zone's own protocol set length (power 6 × 5s = 30s; strength 5 × 10s = 50s; pow end 6 × 7s = 42s; endurance 8 × 30s = 240s). A short warm-up shows up as a fraction of a set rather than needing a whole session to register.",
      },
      {
        heading: "The zone is inferred, not stored",
        text: "Recordings don't record which zone you meant to train, so it's re-inferred from hold length: 1–6s power · 6–8.5s pow end · 8.5–20s strength · over 20s endurance. Those anchors sit close together, so short holds are inherently fuzzy and land as fractional credit either side of a boundary.",
      },
      {
        heading: "Why History looks different",
        text: "History lists every session for every exercise over all time, and badges each one with the zone that session alone was mostly in. Different scope, different window, different unit — the two are expected to disagree. Tap the card to see every number here traced back to the holds behind it.",
      },
    ],
  },
  tindeqConsistency: {
    title: "How Tindeq consistency is tracked",
    body: [
      {
        heading: "A day counts once",
        text: "Each bar is how many DISTINCT DAYS you recorded at least one Tindeq hold in that rolling 7-day window (0–7) — not rep count or total time, so one huge session can't dwarf the rest of the week. Filtering to one exercise still counts a day once even if you did several holds of it.",
      },
      {
        heading: "Rolling weekly windows",
        text: "Same windowing as Weekly load above: 'Now' is the last 7 days including today, '1w' the 7 days before that, and so on back 8 weeks.",
      },
      {
        heading: "Hidden tags are excluded",
        text: "Exercises you've hidden from the Force tab's tag picker don't count here either — same list, same reasoning.",
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
