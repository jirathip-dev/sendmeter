import Sheet from "./Sheet";
import ChartTooltip from "./ChartTooltip";
import { useChartHover } from "../hooks/useChartHover";
import {
  humidityFrictionScore,
  percentileColor,
  percentileLabel,
  sameHourScores,
  scoreLabel,
  sendScoreColor as scoreColor,
  tempFrictionScore,
  type SendConditions,
} from "../lib/weather";

/// Same-hour-of-day comparison chart (issue #99): one bar per day at the
/// SAME local hour as the current reading, chronological, with today's bar
/// appended on the right — the countable claim the banner makes ("better
/// than N of the last M days at this time of day") made visible as bars
/// under a dotted "today" line. Replaces the old absolute-score histogram,
/// which collapsed to a single bin in a hot climate where every hour scores
/// the same "Poor". `days` (from `sameHourScores`) is computed by the caller
/// so it can also drive the under-axis "N days ago" label off the same
/// series length. Hover uses the repo's standard chart-tooltip pattern
/// (`useChartHover` + `ChartTooltip`) rather than native `title` attributes —
/// `title` tooltips don't work on touch, and this is primarily a Capacitor
/// iOS app. `days.length` is used as the sentinel index for today's bar.
function DayComparisonChart({
  score,
  percentile,
  days,
}: {
  score: number;
  percentile: number;
  days: number[];
}) {
  const max = Math.max(1, ...days, score);
  const todayColor = percentileColor(percentile);
  const [hoveredIdx, hoverProps] = useChartHover<number>();
  return (
    <div
      className="chart-scrub"
      style={{ display: "flex", alignItems: "flex-end", gap: 2, height: 56, position: "relative" }}
    >
      {/* Dotted line at today's level — days under it are the ones today beats. */}
      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          bottom: `${(score / max) * 100}%`,
          borderTop: "1px dashed var(--ink-faint)",
        }}
      />
      {days.map((s, i) => {
        const daysAgo = days.length - i;
        const isHovered = hoveredIdx === i;
        return (
          <div
            key={i}
            style={{
              flex: 1,
              position: "relative",
              height: "100%",
              display: "flex",
              alignItems: "flex-end",
              cursor: "pointer",
            }}
            {...hoverProps(i)}
          >
            {isHovered && (
              <ChartTooltip align={i < 5 ? "start" : i > days.length - 5 ? "end" : "center"}>
                {daysAgo} days ago: {s}
              </ChartTooltip>
            )}
            <div
              style={{
                width: "100%",
                height: `${(s / max) * 100}%`,
                minHeight: s > 0 ? 2 : 0,
                background: "var(--ink-faint)",
                opacity: hoveredIdx === null ? 0.55 : isHovered ? 0.85 : 0.35,
                borderRadius: 2,
                boxShadow: isHovered ? "0 0 0 1.5px var(--ink)" : "none",
                transition: "opacity 0.1s",
              }}
            />
          </div>
        );
      })}
      {/* Today's bar, appended on the right — coloured + full opacity so it pops. */}
      <div
        style={{
          flex: 1.3,
          position: "relative",
          height: "100%",
          display: "flex",
          alignItems: "flex-end",
          cursor: "pointer",
        }}
        {...hoverProps(days.length)}
      >
        {hoveredIdx === days.length && <ChartTooltip align="end">Today: {score}</ChartTooltip>}
        <div
          style={{
            width: "100%",
            height: `${(score / max) * 100}%`,
            minHeight: score > 0 ? 2 : 0,
            background: todayColor,
            outline: `2px solid ${todayColor}`,
            outlineOffset: 1,
            borderRadius: 2,
            opacity: hoveredIdx === null || hoveredIdx === days.length ? 1 : 0.55,
            boxShadow: hoveredIdx === days.length ? "0 0 0 1.5px var(--ink)" : "none",
            transition: "opacity 0.1s",
          }}
        />
      </div>
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

/// The headline's percentile suffix (issue #99). Percentile 100 reads as
/// "top 0%", which is backwards — say "best of the last N days" instead.
/// Below 40 ("Poor" territory) the label + banner tail already say it's a
/// bad window, so the suffix is omitted rather than printing "top 100%".
function headlineSuffix(percentile: number, daysTotal: number | null): string | null {
  if (percentile === 100) return daysTotal !== null ? `best of the last ${daysTotal} days` : null;
  if (percentile >= 40) return `top ${Math.max(1, 100 - percentile)}%`;
  return null;
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

/// Detail view for the "send conditions" widget (SL-69): a percentile-first
/// headline (how today compares to the same hour of day over the last 30
/// days — the signal that's actually informative in a hot climate, where the
/// absolute score is permanently "Poor"), with the absolute friction model
/// kept as a secondary, clearly-labelled explanation below.
export default function SendConditionsSheet({ cond, loading, failed, onRefresh, onClose }: Props) {
  const suffix =
    cond && cond.percentile !== null ? headlineSuffix(cond.percentile, cond.daysTotal) : null;
  // Same-hour day series for the comparison chart, computed once so both the
  // chart and its "N days ago" axis label agree on the count (issue #99).
  const chartDays =
    cond && cond.hist && cond.percentile !== null && cond.hourOfDay !== undefined
      ? sameHourScores(cond.hist.scores, cond.hourOfDay)
      : null;
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
          {/* Headline: percentile-first when we have a same-hour ranking —
              that's the number that's actually informative in a hot climate,
              where the absolute score is permanently "Poor". Falls back to
              the absolute headline when there's no ranking (short/no history). */}
          {cond.percentile !== null ? (
            <>
              <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 4, flexWrap: "wrap" }}>
                <span
                  style={{
                    fontFamily: "Inter, sans-serif",
                    fontSize: 40,
                    fontWeight: 800,
                    color: percentileColor(cond.percentile),
                    letterSpacing: "-0.03em",
                    lineHeight: 1,
                  }}
                >
                  {percentileLabel(cond.percentile)}
                </span>
                <span style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", fontWeight: 600 }}>
                  conditions for here{suffix ? ` · ${suffix}` : ""}
                </span>
              </div>
              <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 12 }}>
                {Math.round(cond.tempC)}°C · {Math.round(cond.humidity)}% humidity
              </div>
            </>
          ) : (
            <>
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
            </>
          )}

          {/* The countable claim (issue #99): the banner states exactly what
              the chart below shows — how many of the last N same-hour days
              today beats. */}
          {cond.percentile !== null && cond.daysBelow !== null && cond.daysTotal !== null && (
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
              <strong>
                {cond.daysBelow} of the last {cond.daysTotal} days
              </strong>{" "}
              at this time of day.{" "}
              <span style={{ color: "var(--ink-muted)" }}>
                {cond.percentile >= 75
                  ? "A standout window for here."
                  : cond.percentile >= 40
                    ? "A typical day here."
                    : "Below par for here."}
              </span>
            </div>
          )}

          {/* Same-hour-of-day comparison (issue #99): today plotted against
              the other ~30 days at the SAME hour, so the chart shows exactly
              what the banner counts. Belt-and-braces `hourOfDay !== undefined`
              guard against a stale pre-#99 localStorage cache. */}
          {cond.hist && cond.percentile !== null && chartDays && (
            <div style={{ marginBottom: 16 }}>
              <div
                className="label-eyebrow"
                style={{ display: "flex", justifyContent: "space-between", marginBottom: 6 }}
              >
                <span>Same time of day · last 30 days</span>
                <span style={{ color: percentileColor(cond.percentile) }}>today</span>
              </div>
              <DayComparisonChart score={cond.score} percentile={cond.percentile} days={chartDays} />
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  fontSize: "var(--t-eyebrow)",
                  color: "var(--ink-faint)",
                  marginTop: 4,
                }}
              >
                <span>{chartDays.length} days ago</span>
                <span>today</span>
              </div>
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 8, lineHeight: 1.5 }}>
                Range here: <strong>{Math.round(cond.hist.tempMin)}–{Math.round(cond.hist.tempMax)}°C</strong>,{" "}
                <strong>{Math.round(cond.hist.humMin)}–{Math.round(cond.hist.humMax)}%</strong> humidity.
              </div>
            </div>
          )}

          {/* Absolute friction — secondary, clearly labelled: the model that
              explains the raw temp/humidity numbers, kept below the
              percentile-first headline rather than leading with it. The
              summary line is skipped when the headline above IS the absolute
              score (no percentile) — it would just repeat it verbatim. */}
          <div className="label-eyebrow" style={{ marginBottom: 6 }}>Absolute friction</div>
          {cond.percentile !== null && (
            <div style={{ fontSize: "var(--t-sm)", color: "var(--ink)", marginBottom: 10 }}>
              <span style={{ color: scoreColor(cond.score), fontWeight: 700 }}>
                {scoreLabel(cond.score)} · {cond.score}/100
              </span>{" "}
              — {Math.round(cond.tempC)}°C · {Math.round(cond.humidity)}%
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
            {cond.percentile !== null &&
              "The headline compares right now with the same time of day over the last 30 days at your location — a high rank means this is a good window for here, whatever the absolute score says. "}
            The absolute score rewards cold and dry (friction peaks near
            6&nbsp;°C); above ~23&nbsp;°C the temperature part bottoms out, so
            in a warm climate the day-to-day ranking is driven almost entirely
            by humidity.
            {cond.hist &&
              (tempFrictionScore(cond.tempC) === 0
                ? ` Temperature is maxed out here year-round — today ranks on humidity: ${Math.round(cond.humidity)}% against the local ${Math.round(cond.hist.humMin)}–${Math.round(cond.hist.humMax)}% range.`
                : ` Today ranks on the mix of ${Math.round(cond.tempC)}°C against the local ${Math.round(cond.hist.tempMin)}–${Math.round(cond.hist.tempMax)}°C range and ${Math.round(cond.humidity)}% against ${Math.round(cond.hist.humMin)}–${Math.round(cond.hist.humMax)}% humidity.`)}{" "}
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
