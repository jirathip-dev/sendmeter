import { useCallback, useEffect, useState } from "react";
import { fetchSendConditions, type SendConditions } from "../lib/weather";

const KEY = "sendmeter:send-conditions";
const FRESH_MS = 30 * 60 * 1000;

function loadCached(): SendConditions | null {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as SendConditions) : null;
  } catch {
    return null;
  }
}

const scoreColor = (s: number) =>
  s >= 55 ? "var(--success)" : s >= 35 ? "var(--warning)" : "var(--danger)";

/// Compact "send conditions" widget (SL-69): temperature + humidity → a climbing
/// friction score. Fetches on tap the first time (so the location prompt is
/// user-initiated); once cached it silently refreshes when stale.
export default function SendConditionsCard() {
  const [cond, setCond] = useState<SendConditions | null>(loadCached);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    setFailed(false);
    const c = await fetchSendConditions();
    setLoading(false);
    if (c) {
      setCond(c);
      try {
        localStorage.setItem(KEY, JSON.stringify(c));
      } catch {
        /* ignore quota */
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
    <div
      className="card"
      onClick={() => void refresh()}
      style={{
        flex: 1,
        minWidth: 0,
        margin: 0,
        padding: "10px 14px",
        cursor: "pointer",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        gap: 10,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
        {dot(cond ? scoreColor(cond.score) : "var(--ink-faint)")}
        <div style={{ minWidth: 0 }}>
          <div
            style={{
              fontSize: 9,
              color: "var(--ink-muted)",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
            }}
          >
            Send conditions
          </div>
          <div style={{ fontSize: 13, fontWeight: 700, color: "var(--ink)", marginTop: 1 }}>
            {loading
              ? "Checking…"
              : cond
                ? cond.label
                : failed
                  ? "Unavailable"
                  : "Tap to check"}
          </div>
        </div>
      </div>
      {cond && !loading && (
        <div style={{ textAlign: "right", flexShrink: 0 }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: scoreColor(cond.score) }}>
            {Math.round(cond.tempC)}°C
          </div>
          <div style={{ fontSize: 10, color: "var(--ink-muted)" }}>
            {Math.round(cond.humidity)}% RH
          </div>
        </div>
      )}
    </div>
  );
}
