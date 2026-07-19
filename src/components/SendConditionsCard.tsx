import { useCallback, useEffect, useState } from "react";
import { fetchSendConditions, type SendConditions } from "../lib/weather";
import SendConditionsSheet from "./SendConditionsSheet";

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
  const [showSheet, setShowSheet] = useState(false);

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
    <>
    <div
      className="card"
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
        {dot(cond ? scoreColor(cond.score) : "var(--ink-faint)")}
        <span
          style={{
            fontSize: "var(--t-base)",
            fontWeight: 700,
            color: cond ? scoreColor(cond.score) : "var(--ink)",
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {loading ? "Checking…" : cond ? cond.label : failed ? "N/A" : "Check"}
        </span>
      </div>
      {cond && !loading && (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
          {Math.round(cond.tempC)}°C · {Math.round(cond.humidity)}%
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
