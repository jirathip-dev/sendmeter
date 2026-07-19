import Sheet from "./Sheet";
import {
  humidityFrictionScore,
  tempFrictionScore,
  type SendConditions,
} from "../lib/weather";

const scoreColor = (s: number) =>
  s >= 55 ? "var(--success)" : s >= 35 ? "var(--warning)" : "var(--danger)";

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
        <span style={{ fontSize: 12, color: "var(--ink)", fontWeight: 600 }}>{label}</span>
        <span style={{ fontSize: 11, color: "var(--ink-muted)" }}>
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
      <div style={{ fontFamily: "Inter, sans-serif", fontSize: 20, fontWeight: 800, marginBottom: 2 }}>
        Send conditions
      </div>
      <div style={{ fontSize: 11, color: "var(--ink-muted)", marginBottom: 16 }}>
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
            <span style={{ fontSize: 14, color: "var(--ink-muted)", fontWeight: 700 }}>
              {cond.score}/100
            </span>
          </div>
          <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12 }}>
            {Math.round(cond.tempC)}°C · {Math.round(cond.humidity)}% humidity
          </div>

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
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: 9, color: "var(--ink-faint)", marginBottom: 18 }}>
            <span>Poor</span>
            <span>Fair</span>
            <span>Good</span>
            <span>Prime</span>
          </div>

          {/* Breakdown */}
          <div className="label-eyebrow" style={{ marginBottom: 10 }}>How it's scored</div>
          <SubScore label="Temperature" detail={`${Math.round(cond.tempC)}°C · 60%`} score={Math.round(tempFrictionScore(cond.tempC))} />
          <SubScore label="Humidity" detail={`${Math.round(cond.humidity)}% · 40%`} score={Math.round(humidityFrictionScore(cond.humidity))} />

          <div style={{ fontSize: 11, color: "var(--ink-muted)", lineHeight: 1.6, marginTop: 4 }}>
            The score blends temperature (60%) and humidity (40%). Grip friction
            peaks around <strong>6&nbsp;°C</strong> and low humidity, and drops as
            it warms up or gets muggy. Weather is from Open-Meteo for your current
            location.
          </div>

          <div style={{ fontSize: 10, color: "var(--ink-faint)", marginTop: 10 }}>
            Updated {new Date(cond.fetchedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
          </div>
        </>
      ) : (
        <div style={{ fontSize: 12, color: "var(--ink-muted)", lineHeight: 1.6, marginBottom: 4 }}>
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
