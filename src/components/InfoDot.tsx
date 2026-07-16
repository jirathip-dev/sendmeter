import { useState } from "react";
import Sheet from "./Sheet";

export type InfoTopic = "acwr" | "readiness" | "forceCurve" | "gaugeTarget";

const CONTENT: Record<
  InfoTopic,
  {
    title: string;
    body: { heading: string; text: string }[];
    refs: { label: string; url: string }[];
  }
> = {
  acwr: {
    title: "How ACWR is calculated",
    body: [
      {
        heading: "Session load",
        text: "Every session gets a load in arbitrary units (AU) = duration (min) × RPE (1–10). This is the session-RPE method — a validated, equipment-free way to quantify internal training load.",
      },
      {
        heading: "Acute : Chronic Workload Ratio",
        text: "ACWR compares what you did recently (acute ≈ last 7 days) with what you're adapted to (chronic ≈ last 28 days). Sendmeter uses exponentially-weighted moving averages (EWMA, λ = 2/(N+1) with N = 7 and 28) over the last 90 days, seeded with the window mean — EWMA weights recent days more and avoids the 'mathematical coupling' of simple rolling averages.",
      },
      {
        heading: "Risk zones",
        text: "0.8–1.3 is the commonly-cited 'sweet spot'; above ~1.5 the risk of injury rises sharply (load spiking faster than adaptation). Below 0.8 you're detraining relative to your base. The phase banner also shows a phase-specific target band — a power phase legitimately runs a lower ratio than a capacity phase.",
      },
      {
        heading: "Caveats",
        text: "ACWR is a screening heuristic, not a prescription — the research is debated (especially causality), and RPE-based load misses intensity spikes inside a session. Treat sustained red zones as a prompt to look at sleep, finger niggles and volume, not as a hard rule.",
      },
    ],
    refs: [
      {
        label: "Foster et al. 2001 — Session-RPE training load",
        url: "https://pubmed.ncbi.nlm.nih.gov/11708692/",
      },
      {
        label: "Gabbett 2016 — The training–injury prevention paradox (BJSM)",
        url: "https://pubmed.ncbi.nlm.nih.gov/26758673/",
      },
      {
        label: "Williams et al. 2017 — EWMA better than rolling averages for ACWR",
        url: "https://pubmed.ncbi.nlm.nih.gov/27650255/",
      },
      {
        label: "Impellizzeri et al. 2020 — ACWR critique & limitations",
        url: "https://pubmed.ncbi.nlm.nih.gov/32014052/",
      },
    ],
  },
  readiness: {
    title: "How Readiness is calculated",
    body: [
      {
        heading: "Inputs",
        text: "Overnight HRV (SDNN), resting heart rate, and sleep duration from Apple Health (any wearable that writes to it), each compared against YOUR rolling baseline — plus a penalty when recent training load is high.",
      },
      {
        heading: "The model",
        text: "readiness = 50 + wHRV·z(ln HRV) − wRHR·z(RHR) + wSleep·min(z(sleep), cap) − loadPenalty·p(ACWR), clamped 0–100. z-scores are computed against your own multi-week baseline (HRV is log-transformed first, standard practice because HRV is right-skewed). Higher HRV and lower RHR than your baseline push the score up; short sleep and heavy recent load pull it down.",
      },
      {
        heading: "Reading it",
        text: "It's a trend tool: single days are noisy (alcohol, heat, late meals all move HRV). A multi-day slide in the score — especially HRV down AND RHR up — is the meaningful signal to back off intensity. It needs about a week of overnight data to build a baseline.",
      },
    ],
    refs: [
      {
        label: "Plews et al. 2013 — HRV in elite training monitoring",
        url: "https://pubmed.ncbi.nlm.nih.gov/23852425/",
      },
      {
        label: "Buchheit 2014 — Monitoring training status with HR measures",
        url: "https://pubmed.ncbi.nlm.nih.gov/24734048/",
      },
      {
        label: "Stanley et al. 2013 — Parasympathetic reactivation & recovery",
        url: "https://pubmed.ncbi.nlm.nih.gov/23529287/",
      },
    ],
  },
  gaugeTarget: {
    title: "How zone targets are recommended",
    body: [
      {
        heading: "Anchored to YOUR curve",
        text: "Each zone is a percentage band of your own force–duration fit for the selected exercise (and side): POWER and STRENGTH anchor to your max force; POW END and ENDURANCE anchor to your critical force (CF) — the sustainable ceiling from the hyperbolic fit.",
      },
      {
        heading: "Why %max vs %CF",
        text: "Short maximal efforts (<10s) are limited by maximal recruitment, so power/strength work is prescribed off max. Longer efforts are limited by the forearm's aerobic ceiling, so endurance work is prescribed off CF — training just below CF extends capacity, just above it trains W′ (anaerobic reserve).",
      },
      {
        heading: "Using a target",
        text: "Picking a zone draws its band on the live gauge — keep the trace inside the band for the prescribed work time. The zones sharpen as your curve gets more data (especially one all-out 30–60s hold).",
      },
    ],
    refs: [
      {
        label: "Giles et al. 2020 — Finger-flexor critical force in climbers",
        url: "https://pubmed.ncbi.nlm.nih.gov/31743092/",
      },
      {
        label: "Jones et al. 2010 — Critical power: implications for training",
        url: "https://pubmed.ncbi.nlm.nih.gov/20195180/",
      },
      {
        label: "López-Rivera & González-Badillo 2012 — Hangboard training loads",
        url: "https://doi.org/10.1080/19346182.2012.716061",
      },
    ],
  },
  forceCurve: {
    title: "How the Force Curve works",
    body: [
      {
        heading: "Force–duration curve",
        text: "From your recordings, the best average force you can hold for every window length (1s…120s) is extracted. Long story short: huge force for seconds, much less for minutes — the decay between them is highly individual and trainable.",
      },
      {
        heading: "Critical force (CF) & W′",
        text: "The curve is fitted with the hyperbolic critical-power model adapted to finger flexors: F(t) = CF + W′/t. CF is the force you can theoretically sustain 'indefinitely' (aerobic ceiling of the forearm); W′ is the fixed anaerobic work capacity above CF you can spend before failing. The fit needs at least one long (30–60s+) all-out hold to be trustworthy.",
      },
      {
        heading: "Training zones",
        text: "The POWER / STRENGTH / POW END / ENDURANCE targets are percentage bands anchored to your max force and CF (e.g. endurance ≈ 80–100% of CF, strength near max). They translate the fit into 'hang at X kg for Y seconds' prescriptions.",
      },
    ],
    refs: [
      {
        label: "Monod & Scherrer 1965 — the critical power concept",
        url: "https://doi.org/10.1080/00140136508930810",
      },
      {
        label: "Giles et al. 2020 — All-out test for finger-flexor critical force in climbers",
        url: "https://pubmed.ncbi.nlm.nih.gov/31743092/",
      },
      {
        label: "Jones et al. 2010 — Critical power: implications for training",
        url: "https://pubmed.ncbi.nlm.nih.gov/20195180/",
      },
    ],
  },
};

/// Small circled "?" that opens an explainer sheet: how the number is
/// computed + the research it leans on.
export default function InfoDot({ topic }: { topic: InfoTopic }) {
  const [open, setOpen] = useState(false);
  const c = CONTENT[topic];

  return (
    <>
      <button
        aria-label={`About: ${c.title}`}
        onClick={(e) => {
          e.stopPropagation();
          setOpen(true);
        }}
        style={{
          width: 18,
          height: 18,
          borderRadius: "50%",
          border: "1px solid var(--border)",
          background: "transparent",
          color: "var(--ink-faint)",
          fontSize: 11,
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
              fontSize: 18,
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
                  fontSize: 11,
                  fontWeight: 700,
                  color: "var(--ink)",
                  marginBottom: 4,
                  fontFamily: "Inter, sans-serif",
                }}
              >
                {b.heading}
              </div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)", lineHeight: 1.6 }}>
                {b.text}
              </div>
            </div>
          ))}
          <div className="label-eyebrow" style={{ margin: "18px 0 8px" }}>
            References
          </div>
          {c.refs.map((r) => (
            <a
              key={r.url}
              href={r.url}
              target="_blank"
              rel="noreferrer"
              style={{
                display: "block",
                fontSize: 11,
                color: "var(--info)",
                marginBottom: 6,
                lineHeight: 1.5,
                textDecoration: "none",
                borderBottom: "1px dotted var(--border)",
                paddingBottom: 6,
              }}
            >
              {r.label} ↗
            </a>
          ))}
          <div style={{ marginTop: 14 }}>
            <button className="btn-ghost" onClick={() => setOpen(false)}>
              Close
            </button>
          </div>
          </div>
        </Sheet>
      )}
    </>
  );
}
