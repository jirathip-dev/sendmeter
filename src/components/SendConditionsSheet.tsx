import type { CSSProperties } from "react";
import Sheet from "./Sheet";
import ChartTooltip from "./ChartTooltip";
import { useChartHover } from "../hooks/useChartHover";
import { chartColor } from "../lib/chartTheme";
import { median } from "../lib/boxplot";
import {
  humidityFrictionScore,
  isTempRangeSaturated,
  percentileColor,
  percentileLabel,
  sameHourDaysAgo,
  sameHourScores,
  scoreLabel,
  sendScoreColor as scoreColor,
  tempFrictionScore,
  type SendConditions,
} from "../lib/weather";

const CHART_H = 56;

/// Right gutter reserved for the reference lines' inline end labels (SL-184).
/// Shared with the under-axis label row so the "N days ago" / "today" ticks
/// keep landing on the plot area rather than on the gutter (the same
/// shared-axis-constant lesson as SL-183's `WORKOUT_CHART_PAD`). An inline
/// end label beats a legend here: this is a narrow phone sheet, a legend
/// would cost its own row and introduce a colour-swatch vocabulary the chart
/// doesn't otherwise use, and the label sits where the eye already is — at
/// the line.
const CHART_LABEL_GUTTER = 44;
/// Line box of a reference-line label, in px — used to keep it inside the plot.
const CHART_LABEL_H = 11;

/// Shared look for both end labels — same size/weight as the chart's own
/// under-axis ticks, so they read as part of the axis furniture. Colour is
/// per-line.
const refLabelStyle: CSSProperties = {
  position: "absolute",
  right: 0,
  width: CHART_LABEL_GUTTER,
  paddingLeft: 5,
  fontSize: "var(--t-eyebrow)",
  lineHeight: `${CHART_LABEL_H}px`,
  fontWeight: 700,
  whiteSpace: "nowrap",
  pointerEvents: "none",
};

/// Where a reference line's label sits, in px from the chart's bottom edge.
/// `side` is +1 to sit above the line, -1 below; callers put each label on
/// the side away from the *other* line, so the two can never collide even
/// when today lands exactly on the median. Clamped into the plot so a line at
/// the very top (today is the best day — always true for the today line when
/// it sets `max`) doesn't push its label out of the chart.
function refLabelBottom(valuePct: number, side: 1 | -1): number {
  const line = (valuePct / 100) * CHART_H;
  const raw = side === 1 ? line + 2 : line - CHART_LABEL_H - 2;
  return Math.min(Math.max(raw, 0), CHART_H - CHART_LABEL_H);
}

/// Same-hour-of-day comparison chart (issue #99): one bar per day at the
/// SAME local hour as the current reading, chronological, with today's bar
/// appended on the right — the countable claim the banner makes ("better
/// than N of the last M days at this time of day") made visible as bars
/// under a dashed "today" line. Replaces the old absolute-score histogram,
/// which collapsed to a single bin in a hot climate where every hour scores
/// the same "Poor". `days` (from `sameHourScores`) is computed by the caller
/// so it can also drive the under-axis "N days ago" label off the same
/// series length. Hover uses the repo's standard chart-tooltip pattern
/// (`useChartHover` + `ChartTooltip`) rather than native `title` attributes —
/// `title` tooltips don't work on touch, and this is primarily a Capacitor
/// iOS app. `days.length` is used as the sentinel index for today's bar.
///
/// Both reference lines carry an inline end label (SL-184). The "today" line
/// used to be the only one and was unlabelled, which left readers guessing
/// what it meant; the median of the plotted days is the second reference,
/// deliberately styled *down* from it (muted + dotted vs. the percentile
/// colour + dashed) so the two never read as the same kind of thing.
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
  // Median of the days plotted — today is excluded, matching the banner's
  // "better than N of the last M days" which also ranks today *against* the
  // history rather than including it.
  const med = median(days);
  const scorePct = (score / max) * 100;
  const medPct = med === null ? 0 : (med / max) * 100;
  // Each label goes on the side facing away from the other line.
  const todayAbove = med === null || score >= med;
  return (
    <div
      role="group"
      aria-label="Same-time-of-day send conditions comparison"
      style={{ position: "relative", height: CHART_H, paddingRight: CHART_LABEL_GUTTER }}
    >
      <div
        className="chart-scrub"
        role="group"
        style={{ display: "flex", alignItems: "flex-end", gap: 2, height: "100%", position: "relative" }}
      >
        {/* Median of the plotted days — the "typical day here" baseline. Dotted
            and muted so it reads as background reference, not as today. */}
        {med !== null && (
          <div
            style={{
              position: "absolute",
              left: 0,
              right: 0,
              bottom: `${medPct}%`,
              borderTop: `1px dotted ${chartColor("reference")}`,
            }}
          />
        )}
        {/* Dashed line at today's level — days under it are the ones today
            beats. Carries today's percentile colour, tying it to today's bar. */}
        <div
          style={{
            position: "absolute",
            left: 0,
            right: 0,
            bottom: `${scorePct}%`,
            borderTop: `1px dashed ${todayColor}`,
          }}
        />
        {days.map((s, i) => {
          const daysAgo = sameHourDaysAgo(i, days.length);
          const isHovered = hoveredIdx === i;
          return (
            <button
              key={i}
              type="button"
              aria-label={`${daysAgo} days ago: send conditions score ${s}`}
              style={{
                flex: 1,
                position: "relative",
                height: "100%",
                display: "flex",
                alignItems: "flex-end",
                minHeight: 44,
                minWidth: 0,
                padding: 0,
                border: 0,
                background: "transparent",
                color: "inherit",
                font: "inherit",
                appearance: "none",
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
                  background: `linear-gradient(180deg, color-mix(in srgb, ${chartColor("reference")} 45%, var(--canvas)), ${chartColor("reference")})`,
                  opacity: hoveredIdx === null ? 0.55 : isHovered ? 0.85 : 0.35,
                  borderRadius: 2,
                  boxShadow: isHovered ? "0 0 0 1.5px var(--ink)" : "none",
                  transition: "opacity 0.1s",
                }}
              />
            </button>
          );
        })}
        {/* Today's bar, appended on the right — coloured + full opacity so it pops. */}
        <button
          type="button"
          aria-label={`Today: send conditions score ${score}`}
          style={{
            flex: 1.3,
            position: "relative",
            height: "100%",
            display: "flex",
            alignItems: "flex-end",
            minHeight: 44,
            minWidth: 0,
            padding: 0,
            border: 0,
            background: "transparent",
            color: "inherit",
            font: "inherit",
            appearance: "none",
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
            background: `linear-gradient(180deg, color-mix(in srgb, ${todayColor} 62%, var(--canvas)), ${todayColor})`,
              outline: `2px solid ${todayColor}`,
              outlineOffset: 1,
              borderRadius: 2,
              opacity: hoveredIdx === null || hoveredIdx === days.length ? 1 : 0.55,
              boxShadow: hoveredIdx === days.length ? "0 0 0 1.5px var(--ink)" : "none",
              transition: "opacity 0.1s",
            }}
          />
        </button>
        </div>
      {/* Inline end labels, in the reserved gutter — every reference line on
          this chart is identifiable without hovering. */}
      {med !== null && (
        <span style={{ ...refLabelStyle, bottom: refLabelBottom(medPct, todayAbove ? -1 : 1), color: "var(--ink-muted)" }}>
          median
        </span>
      )}
      <span style={{ ...refLabelStyle, bottom: refLabelBottom(scorePct, todayAbove ? 1 : -1), color: todayColor }}>
        today
      </span>
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
  // Whether the "maxed out year-round" driver-line claim is actually
  // supported by the 30-day history, rather than inferred from today's
  // reading alone (today could be the hottest day in an otherwise-cooler
  // range).
  const histTempSaturated = cond?.hist
    ? isTempRangeSaturated(cond.hist.tempMin, cond.hist.tempMax)
    : false;
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
              {/* The right-hand "today" swatch this row used to carry is gone
                  (SL-184) — the chart's own dashed "today" line label is in
                  the same percentile colour, right next to today's bar, and
                  the axis below still says "today". Three of them in a 60px
                  band was the noise, not the signal. */}
              <div className="label-eyebrow" style={{ marginBottom: 6 }}>
                Same time of day · last 30 days
              </div>
              <DayComparisonChart score={cond.score} percentile={cond.percentile} days={chartDays} />
              {/* Same right gutter as the chart, so these ticks stay aligned
                  with the plot area rather than with the label gutter. */}
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  paddingRight: CHART_LABEL_GUTTER,
                  fontSize: "var(--t-eyebrow)",
                  color: "var(--ink-faint)",
                  marginTop: 4,
                }}
              >
                <span>{sameHourDaysAgo(0, chartDays.length)} days ago</span>
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
              (histTempSaturated
                ? ` Temperature is maxed out here year-round — today ranks on humidity: ${Math.round(cond.humidity)}% against the local ${Math.round(cond.hist.humMin)}–${Math.round(cond.hist.humMax)}% range.`
                : tempFrictionScore(cond.tempC) === 0
                  ? ` Temperature is maxed out in this range — today ranks on humidity: ${Math.round(cond.humidity)}% against the local ${Math.round(cond.hist.humMin)}–${Math.round(cond.hist.humMax)}% range.`
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
