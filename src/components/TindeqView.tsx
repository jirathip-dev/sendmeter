import { useEffect, useState } from "react";
import { useTindeq } from "../hooks/useTindeq";
import type { StoppedRecording } from "../hooks/useTindeq";
import {
  deleteRecording,
  fetchRecordings,
  insertRecording,
} from "../lib/repo";
import type { TindeqRecordingMeta } from "../types";
import ForceGauge from "./ForceGauge";
import RecordingRow from "./RecordingRow";
import TindeqTrendChart from "./TindeqTrendChart";

export default function TindeqView() {
  const tindeq = useTindeq();
  const [pending, setPending] = useState<StoppedRecording | null>(null);
  const [pendingNote, setPendingNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [recordings, setRecordings] = useState<TindeqRecordingMeta[]>([]);
  const [listError, setListError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchRecordings()
      .then((list) => {
        if (!cancelled) setRecordings(list);
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setListError(
            e instanceof Error ? e.message : "Failed to load recordings",
          );
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleStop() {
    const summary = await tindeq.stop();
    if (summary) {
      setPending(summary);
      setPendingNote("");
    }
  }

  async function savePending() {
    if (!pending) return;
    setSaving(true);
    try {
      const saved = await insertRecording({
        durationMs: pending.durationMs,
        peakKg: pending.peakKg,
        avgKg: pending.avgKg,
        note: pendingNote.trim(),
        samples: pending.samples,
      });
      setRecordings((list) => [saved, ...list]);
      setPending(null);
    } catch (e) {
      setListError(e instanceof Error ? e.message : "Failed to save recording");
    } finally {
      setSaving(false);
    }
  }

  async function removeRecording(id: string) {
    const prev = recordings;
    setRecordings((list) => list.filter((r) => r.id !== id));
    try {
      await deleteRecording(id);
    } catch (e) {
      setRecordings(prev);
      setListError(
        e instanceof Error ? e.message : "Failed to delete recording",
      );
    }
  }

  const { status } = tindeq;

  return (
    <div>
      <div className="section-head">
        TINDEQ{" "}
        {tindeq.fakeMode && (
          <span style={{ fontSize: 10, color: "#facc15" }}>(fake mode)</span>
        )}
      </div>
      <div className="section-sub">
        Live force from your Progressor via Bluetooth.
      </div>

      {status === "unsupported" && (
        <div className="card">
          <div
            style={{
              fontFamily: "'Syne', sans-serif",
              fontSize: 16,
              fontWeight: 800,
              marginBottom: 8,
            }}
          >
            Bluetooth not available
          </div>
          <div style={{ fontSize: 12, color: "#7a8a9a", lineHeight: 1.5 }}>
            {tindeq.secure
              ? "This browser doesn't support Web Bluetooth. Use Chrome or Edge on desktop or Android — iOS Safari can't connect to Bluetooth devices."
              : "Web Bluetooth requires a secure (HTTPS) connection."}
          </div>
        </div>
      )}

      {status === "idle" && (
        <button className="btn-primary" onClick={() => void tindeq.connect()}>
          Connect Progressor
        </button>
      )}
      {status === "connecting" && (
        <button className="btn-primary" disabled>
          Connecting…
        </button>
      )}

      {tindeq.errorMsg && (
        <div style={{ fontSize: 11, color: "#f87171", marginTop: 10 }}>
          {tindeq.errorMsg}
        </div>
      )}

      {(status === "connected" || status === "measuring") && (
        <div>
          {/* Device status row */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              marginBottom: 10,
            }}
          >
            <div
              style={{
                width: 8,
                height: 8,
                borderRadius: "50%",
                background: status === "measuring" ? "#4ade80" : "#60a5fa",
              }}
            />
            <span style={{ fontSize: 12, color: "#e2e8f0", flex: 1 }}>
              Progressor{" "}
              <span style={{ color: "#4a5a70" }}>
                · {status === "measuring" ? "measuring" : "connected"}
              </span>
            </span>
            {tindeq.lowBattery && (
              <span
                className="tag"
                style={{
                  background: "rgba(250,204,21,0.12)",
                  color: "#facc15",
                  border: "1px solid rgba(250,204,21,0.35)",
                }}
              >
                Low battery
              </span>
            )}
            <button
              onClick={tindeq.disconnect}
              style={{
                background: "none",
                border: "1px solid #2a3a50",
                color: "#64748b",
                padding: "6px 10px",
                borderRadius: 6,
                fontSize: 10,
                cursor: "pointer",
                fontFamily: "'DM Mono', monospace",
              }}
            >
              Disconnect
            </button>
          </div>

          <ForceGauge
            current={tindeq.current}
            peak={tindeq.peak}
            elapsedMs={tindeq.elapsedMs}
            samplesRef={tindeq.samplesRef}
            live={status === "measuring"}
          />

          <div className="grid-2" style={{ marginTop: 10 }}>
            <button
              className="btn-ghost"
              disabled={status === "measuring"}
              onClick={() => void tindeq.tare()}
            >
              Tare
            </button>
            {status === "measuring" ? (
              <button className="btn-primary" onClick={() => void handleStop()}>
                Stop
              </button>
            ) : (
              <button
                className="btn-primary"
                onClick={() => {
                  setPending(null);
                  void tindeq.start();
                }}
              >
                Start
              </button>
            )}
          </div>

          {/* Save prompt after stop */}
          {pending && status !== "measuring" && (
            <div className="card" style={{ marginTop: 10 }}>
              <div
                style={{
                  fontSize: 9,
                  color: "#4a5a70",
                  textTransform: "uppercase",
                  letterSpacing: "0.1em",
                  marginBottom: 10,
                }}
              >
                Recording finished
              </div>
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  fontSize: 12,
                  color: "#7a8a9a",
                  marginBottom: 4,
                }}
              >
                <span>Duration</span>
                <span style={{ color: "#e2e8f0" }}>
                  {(pending.durationMs / 1000).toFixed(1)}s
                </span>
              </div>
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  fontSize: 12,
                  color: "#7a8a9a",
                  marginBottom: 4,
                }}
              >
                <span>Peak</span>
                <span
                  style={{
                    color: "#4ade80",
                    fontFamily: "'Syne', sans-serif",
                    fontWeight: 800,
                  }}
                >
                  {pending.peakKg.toFixed(1)} kg
                </span>
              </div>
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  fontSize: 12,
                  color: "#7a8a9a",
                }}
              >
                <span>Average</span>
                <span style={{ color: "#e2e8f0" }}>
                  {pending.avgKg.toFixed(1)} kg
                </span>
              </div>
              <span className="field-label">Note (optional)</span>
              <input
                className="field"
                value={pendingNote}
                onChange={(e) => setPendingNote(e.target.value)}
                placeholder="e.g. right hand, half crimp 20mm"
              />
              <div className="grid-2" style={{ marginTop: 12 }}>
                <button
                  className="btn-ghost"
                  disabled={saving}
                  onClick={() => setPending(null)}
                >
                  Discard
                </button>
                <button
                  className="btn-primary"
                  disabled={saving}
                  onClick={() => void savePending()}
                >
                  {saving ? "Saving…" : "Save"}
                </button>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Trend */}
      <TindeqTrendChart recordings={recordings} />

      {/* Past recordings */}
      <div
        style={{
          fontSize: 10,
          color: "#4a5a70",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          margin: "20px 0 10px",
        }}
      >
        Recordings
      </div>
      {listError && (
        <div style={{ fontSize: 11, color: "#f87171", marginBottom: 8 }}>
          {listError}
        </div>
      )}
      {recordings.length === 0 && !listError && (
        <div
          style={{
            textAlign: "center",
            color: "#2a3a50",
            fontSize: 13,
            padding: "24px 0",
          }}
        >
          No recordings yet.
        </div>
      )}
      {recordings.map((rec) => (
        <RecordingRow
          key={rec.id}
          rec={rec}
          onDelete={(id) => void removeRecording(id)}
        />
      ))}
    </div>
  );
}
