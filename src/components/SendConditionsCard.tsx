import { useCallback, useEffect, useState } from "react";
import {
  fetchSendConditions,
  percentileColor,
  percentileLabel,
  sendScoreColor,
  WEATHER_FAKE_MODE,
  type SendConditions,
} from "../lib/weather";
import SendConditionsSheet from "./SendConditionsSheet";

const KEY = "sendmeter:send-conditions-v2";
const FRESH_MS = 30 * 60 * 1000;

function loadCached(): SendConditions | null {
  // Fake data must never leak into real usage, and a real cached value must
  // not mask the fake scenario — see weather.ts's `?fake-weather`.
  if (WEATHER_FAKE_MODE) return null;
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as SendConditions) : null;
  } catch {
    return null;
  }
}

/// Colour by the LOCAL percentile when we have it (SL-91) — a hot-climate day
/// that's good *for here* shouldn't read as red just because the absolute
/// score is low; falls back to the absolute score otherwise.
function condColor(c: SendConditions): string {
  return c.percentile !== null ? percentileColor(c.percentile) : sendScoreColor(c.score);
}

/// Same percentile-first framing as `condColor`: the local same-hour ranking
/// (issue #99) is the headline when we have it, falling back to the absolute
/// label otherwise.
function condLabel(c: SendConditions): SendConditions["label"] {
  return c.percentile !== null ? percentileLabel(c.percentile) : c.label;
}

/// The card's compact percentile detail (issue #99). Percentile reads as
/// "how much of the distribution is below me", so ≥50 is naturally a "top"
/// framing and <50 a "bottom" one — printing "top 100%" (percentile 0) would
/// read backwards.
function percentileDetail(percentile: number): string {
  return percentile >= 50
    ? `top ${Math.max(1, 100 - percentile)}%`
    : `bottom ${Math.max(1, percentile)}%`;
}

/// Compact "send conditions" widget (SL-69): temperature + humidity → a climbing
/// friction score. Fetches on tap the first time (so the location prompt is
/// user-initiated); once cached it silently refreshes when stale.
export default function SendConditionsCard() {
  const [cond, setCond] = useState<SendConditions | null>(loadCached);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const [showSheet, setShowSheet] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    setFailed(false);
    const c = await fetchSendConditions();
    setLoading(false);
    if (c) {
      setCond(c);
      if (!WEATHER_FAKE_MODE) {
        try {
          localStorage.setItem(KEY, JSON.stringify(c));
        } catch {
          /* ignore quota */
        }
      }
    } else {
      setFailed(true);
    }
  }, []);

  // If we already have data (location was granted before), refresh it silently
  // when stale — this won't re-prompt. No auto-prompt on a cold first run.
  // Deferred a tick so it's not a synchronous setState inside the effect.
  useEffect(() => {
    if (cond && Date.now() - cond.fetchedAt > FRESH_MS) {
      const t = setTimeout(() => void refresh(), 0);
      return () => clearTimeout(t);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const dot = (color: string) => (
    <span
      style={{
        width: 8,
        height: 8,
        borderRadius: "50%",
        background: color,
        flexShrink: 0,
      }}
    />
  );

  return (
    <>
    <div
      className="card surface-context"
      // #171: tappable card without the `.tappable` class (it has its own
      // compact column layout) — opt into the delegated tick by attribute.
      data-haptic="light"
      onClick={() => setShowSheet(true)}
      style={{
        // 1/3-width column next to the 2/3 phase card — vertical layout.
        flex: 1,
        minWidth: 0,
        margin: 0,
        padding: "10px 12px",
        cursor: "pointer",
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        gap: 3,
      }}
    >
      <div
        style={{
          fontSize: "var(--t-eyebrow)",
          color: "var(--ink-muted)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
        }}
      >
        Send Conditions
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6, minWidth: 0 }}>
        {dot(cond ? condColor(cond) : "var(--ink-faint)")}
        <span
          style={{
            fontSize: "var(--t-base)",
            fontWeight: 700,
            color: cond ? condColor(cond) : "var(--ink)",
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {loading ? "Checking…" : cond ? condLabel(cond) : failed ? "N/A" : "Check"}
        </span>
      </div>
      {cond && !loading && (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
          {Math.round(cond.tempC)}°C · {Math.round(cond.humidity)}%
          {cond.percentile !== null && (
            <span style={{ color: condColor(cond) }}> · {percentileDetail(cond.percentile)}</span>
          )}
        </div>
      )}
    </div>
    {showSheet && (
      <SendConditionsSheet
        cond={cond}
        loading={loading}
        failed={failed}
        onRefresh={() => void refresh()}
        onClose={() => setShowSheet(false)}
      />
    )}
    </>
  );
}
