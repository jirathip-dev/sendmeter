import Sheet from "./Sheet";
import {
  humidityFrictionScore,
  scoreHistogram,
  sendScoreColor as scoreColor,
  tempFrictionScore,
  type ClimateSummary,
  type SendConditions,
} from "../lib/weather";

const BINS = 20;

/// The local 30-day send-score distribution (SL-91b) with today marked — so
/// the percentile is something you can SEE (is today an outlier or typical?).
/// Bars are coloured by their own score band; today's column is outlined.
function DistributionChart({ hist, score }: { hist: ClimateSummary; score: number }) {
  const counts = scoreHistogram(hist.scores, BINS);
  const max = Math.max(1, ...counts);
  const todayBin = Math.min(BINS - 1, Math.max(0, Math.floor((score / 100) * BINS)));
  return (
    // Every bin is a full-height faint TRACK spanning the whole Poor→Prime
    // axis, with the hour-count filling from the bottom — so a bunched
    // distribution still reads across the full width and today's outlined
    // column shows its true position on the axis (not just "rightmost bar").
    <div style={{ display: "flex", alignItems: "flex-end", gap: 2, height: 56 }}>
      {counts.map((c, i) => {
        const binScore = (i + 0.5) * (100 / BINS);
        const isToday = i === todayBin;
        return (
          <div
            key={i}
            title={`${Math.round(i * (100 / BINS))}–${Math.round((i + 1) * (100 / BINS))}: ${c}h`}
            style={{
              flex: 1,
              height: "100%",
              display: "flex",
              alignItems: "flex-end",
              background: "var(--surface-1)",
              borderRadius: 2,
              outline: isToday ? "2px solid var(--ink)" : undefined,
              outlineOffset: 1,
            }}
          >
            <div
              style={{
                width: "100%",
                height: `${(c / max) * 100}%`,
                minHeight: c > 0 ? 2 : 0,
                background: scoreColor(binScore),
                opacity: isToday ? 1 : 0.55,
                borderRadius: 2,
              }}
            />
          </div>
        );
      })}
    </div>
  );
}

interface Props {
  cond: SendConditions | null;
  loading: boolean;
  failed: boolean;
  onRefresh: () => void;
  onClose: () => void;
}

/// A labelled sub-score bar (0–100) — used for the temperature and humidity
/// contributions to the overall send score.
function SubScore({ label, detail, score }: { label: string; detail: string; score: number }) {
  return (
    <div style={{ marginBottom: 12 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", marginBottom: 4 }}>
        <span style={{ fontSize: "var(--t-sm)", color: "var(--ink)", fontWeight: 600 }}>{label}</span>
        <span style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
          {detail} · <span style={{ color: scoreColor(score), fontWeight: 700 }}>{score}</span>
        </span>
      </div>
      <div style={{ height: 6, borderRadius: 3, background: "var(--surface-2)", overflow: "hidden" }}>
        <div style={{ width: `${score}%`, height: "100%", background: scoreColor(score), borderRadius: 3 }} />
      </div>
    </div>
  );
}

/// Detail view for the "send conditions" widget (SL-69): the current weather,
/// the derived friction score with its temperature/humidity breakdown, and an
/// explanation of how the status is determined.
export default function SendConditionsSheet({ cond, loading, failed, onRefresh, onClose }: Props) {
  return (
    <Sheet onClose={onClose}>
      <div style={{ fontFamily: "Inter, sans-serif", fontSize: "var(--t-xl)", fontWeight: 800, marginBottom: 2 }}>
        Send conditions
      </div>
      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 16 }}>
        Friction is best when it's cool and dry — better grip, less sweat.
      </div>

      {cond ? (
        <>
          {/* Headline score */}
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 4 }}>
            <span
              style={{
                fontFamily: "Inter, sans-serif",
                fontSize: 40,
                fontWeight: 800,
                color: scoreColor(cond.score),
                letterSpacing: "-0.03em",
                lineHeight: 1,
              }}
            >
              {cond.label}
            </span>
            <span style={{ fontSize: "var(--t-base)", color: "var(--ink-muted)", fontWeight: 700 }}>
              {cond.score}/100
            </span>
          </div>
          <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 12 }}>
            {Math.round(cond.tempC)}°C · {Math.round(cond.humidity)}% humidity
          </div>

          {/* Relative-to-location standing (SL-91) — the signal that matters
              where the absolute score is always low. */}
          {cond.percentile !== null && (
            <div
              style={{
                fontSize: "var(--t-sm)",
                color: "var(--ink)",
                background: "var(--surface-1)",
                border: "1px solid var(--border)",
                borderRadius: 10,
                padding: "10px 12px",
                marginBottom: 16,
                lineHeight: 1.5,
              }}
            >
              Better than{" "}
              <strong>{cond.percentile}%</strong> of the last 30 days at your
              location{" "}
              <span style={{ color: "var(--ink-muted)" }}>
                — {cond.percentile >= 75
                  ? "a standout window here"
                  : cond.percentile >= 40
                    ? "an average day here"
                    : "below par for here"}
                .
              </span>
            </div>
          )}

          {/* Local distribution (SL-91b): the 30-day spread with today marked,
              plus the raw weather range so "historical vs current" is visible. */}
          {cond.hist && (
            <div style={{ marginBottom: 16 }}>
              <div
                className="label-eyebrow"
                style={{ display: "flex", justifyContent: "space-between", marginBottom: 6 }}
              >
                <span>Last 30 days here</span>
                <span style={{ color: "var(--ink-faint)" }}>
                  today ●
                </span>
              </div>
              <DistributionChart hist={cond.hist} score={cond.score} />
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  fontSize: "var(--t-eyebrow)",
                  color: "var(--ink-faint)",
                  marginTop: 4,
                }}
              >
                <span>Poor</span>
                <span>Prime</span>
              </div>
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 8, lineHeight: 1.5 }}>
                Range here: <strong>{Math.round(cond.hist.tempMin)}–{Math.round(cond.hist.tempMax)}°C</strong>,{" "}
                <strong>{Math.round(cond.hist.humMin)}–{Math.round(cond.hist.humMax)}%</strong> humidity.
                Now: <span style={{ color: scoreColor(cond.score), fontWeight: 700 }}>{Math.round(cond.tempC)}°C · {Math.round(cond.humidity)}%</span>.
              </div>
            </div>
          )}

          {/* Score scale — orange (poor) → yellow → blue (prime) */}
          <div style={{ position: "relative", height: 10, borderRadius: 5, marginBottom: 6, background: "linear-gradient(to right, var(--danger), var(--warning), var(--success))", opacity: 0.85 }}>
            <div
              style={{
                position: "absolute",
                top: "50%",
                left: `${Math.min(Math.max(cond.score, 0), 100)}%`,
                transform: "translate(-50%,-50%)",
                width: 14,
                height: 14,
                borderRadius: "50%",
                background: scoreColor(cond.score),
                border: "2px solid var(--canvas)",
              }}
            />
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)", marginBottom: 18 }}>
            <span>Poor</span>
            <span>Fair</span>
            <span>Good</span>
            <span>Prime</span>
          </div>

          {/* Breakdown */}
          <div className="label-eyebrow" style={{ marginBottom: 10 }}>How it's scored</div>
          <SubScore label="Temperature" detail={`${Math.round(cond.tempC)}°C · 60%`} score={Math.round(tempFrictionScore(cond.tempC))} />
          <SubScore label="Humidity" detail={`${Math.round(cond.humidity)}% · 40%`} score={Math.round(humidityFrictionScore(cond.humidity))} />

          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.6, marginTop: 4 }}>
            The score blends temperature (60%) and humidity (40%). Grip friction
            peaks around <strong>6&nbsp;°C</strong> and low humidity, and drops as
            it warms up or gets muggy.
            {cond.percentile !== null
              ? " The percentile above compares today against the last 30 days at your location, so a warm climate still has good and bad days."
              : ""}{" "}
            Weather is from Open-Meteo for your current location.
          </div>

          <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 10 }}>
            Updated {new Date(cond.fetchedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
          </div>
        </>
      ) : (
        <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", lineHeight: 1.6, marginBottom: 4 }}>
          {failed
            ? "Couldn't read the weather — check that location access is allowed, then try again."
            : "Check the current temperature and humidity at your location to see how good conditions are for sending."}
        </div>
      )}

      <div style={{ display: "flex", gap: 8, marginTop: 16 }}>
        <button className="btn-primary" disabled={loading} onClick={onRefresh} style={{ flex: 1 }}>
          {loading ? "Checking…" : cond ? "Refresh" : "Check conditions"}
        </button>
        <button className="btn-ghost" onClick={onClose} style={{ flex: 1 }}>
          Close
        </button>
      </div>
    </Sheet>
  );
}
