import { useEffect, useState } from "react";
import { useTindeq } from "../hooks/useTindeq";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import {
  deleteRecording,
  fetchRecordings,
  insertRecording,
} from "../lib/repo";
import type { TindeqRecordingMeta, TindeqSide } from "../types";
import ForceCurveCard from "./ForceCurveCard";
import type { GaugeTarget } from "./ForceCurveCard";
import ForceGauge from "./ForceGauge";
import GroupedRecordings from "./GroupedRecordings";
import TagSideEditor from "./TagSideEditor";
import TindeqTrendChart from "./TindeqTrendChart";

interface TindeqViewProps {
  onLogSession: (input: {
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
  }) => Promise<void>;
}

export default function TindeqView({ onLogSession }: TindeqViewProps) {
  const tindeq = useTindeq();
  // The just-auto-saved recording, shown as a confirmation so the user can
  // eyeball its tag (and undo if it was wrong). Replaces the old discard/save
  // prompt — a rep now saves the moment you stop, using the tag set beforehand.
  const [justSaved, setJustSaved] = useState<TindeqRecordingMeta | null>(null);
  const [pendingTag, setPendingTag] = useState("");
  const [pendingSide, setPendingSide] = useState<TindeqSide>("");
  const [gaugeSession, setGaugeSession] = useState<{
    id: string;
    startedAt: number;
  } | null>(null);
  const [endingSession, setEndingSession] = useState<{
    id: string;
    durationMin: number;
    rpe: number;
  } | null>(null);
  const [loggingSession, setLoggingSession] = useState(false);
  const [saving, setSaving] = useState(false);
  const [recordings, setRecordings] = useState<TindeqRecordingMeta[]>([]);
  const [listError, setListError] = useState<string | null>(null);
  const [selectedTag, setSelectedTag] = useState<string | null>(null);
  const [selectedSide, setSelectedSide] = useState<TindeqSide | null>(null);
  const [showTrends, setShowTrends] = useState(false);
  const [gaugeTarget, setGaugeTarget] = useState<GaugeTarget | null>(null);
  const realtimeVersion = useRealtimeVersion();

  // Every tag ever used, most frequent first; top 6 become one-tap chips,
  // the full list feeds the input's autocomplete datalist.
  const allTags = (() => {
    const counts = new Map<string, number>();
    for (const r of recordings) {
      if (r.tag) counts.set(r.tag, (counts.get(r.tag) ?? 0) + 1);
    }
    return [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([t]) => t);
  })();
  const recentTags = allTags.slice(0, 6);

  const sessionCount = gaugeSession
    ? recordings.filter((r) => r.groupId === gaugeSession.id).length
    : 0;

  function endSession() {
    if (!gaugeSession) return;
    const durationMin = Math.max(
      1,
      Math.round((Date.now() - gaugeSession.startedAt) / 60000),
    );
    if (sessionCount > 0) {
      setEndingSession({ id: gaugeSession.id, durationMin, rpe: 5 });
    }
    setGaugeSession(null);
  }

  async function logEndedSession() {
    if (!endingSession) return;
    setLoggingSession(true);
    const recs = recordings.filter((r) => r.groupId === endingSession.id);
    const tags = [...new Set(recs.map((r) => r.tag).filter(Boolean))];
    const note = [
      `${recs.length} recording${recs.length === 1 ? "" : "s"}`,
      ...(tags.length ? [tags.join(", ")] : []),
    ].join(" · ");
    await onLogSession({
      durationMin: endingSession.durationMin,
      rpe: endingSession.rpe,
      note,
      groupId: endingSession.id,
    });
    setLoggingSession(false);
    setEndingSession(null);
  }

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
  }, [realtimeVersion]);

  // Stop always saves — the tag was required before Start, so there's nothing
  // to decide here. Show the saved rep as a confirmation (with an undo).
  async function handleStop() {
    const summary = await tindeq.stop();
    if (!summary) return;
    setSaving(true);
    try {
      const saved = await insertRecording({
        durationMs: summary.durationMs,
        peakKg: summary.peakKg,
        avgKg: summary.avgKg,
        note: "",
        tag: pendingTag.trim(),
        side: pendingSide,
        groupId: gaugeSession?.id ?? null,
        samples: summary.samples,
      });
      setRecordings((list) => [saved, ...list]);
      setJustSaved(saved);
      // keep tag and side — set once, tweak side between reps
    } catch (e) {
      setListError(e instanceof Error ? e.message : "Failed to save recording");
    } finally {
      setSaving(false);
    }
  }

  // Undo a just-saved rep (mis-tagged, or a bad pull) — deletes it and clears
  // the confirmation so the user can retag and pull again.
  async function undoJustSaved() {
    if (!justSaved) return;
    const id = justSaved.id;
    setJustSaved(null);
    await removeRecording(id);
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
          <span style={{ fontSize: 10, color: "var(--warning)" }}>(fake mode)</span>
        )}
      </div>
      <div className="section-sub">
        Live force from your Progressor via Bluetooth.
      </div>

      {/* Gauge session bar */}
      {status !== "unsupported" && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            padding: "10px 14px",
            background: "var(--canvas)",
            border: `1px solid ${gaugeSession ? "rgba(91,95,199,0.55)" : "transparent"}`,
            borderRadius: 10,
            boxShadow: "0 1px 4px rgba(0,0,0,0.12)",
            marginBottom: 10,
          }}
        >
          {gaugeSession ? (
            <>
              <div
                style={{
                  width: 8,
                  height: 8,
                  borderRadius: "50%",
                  background: "var(--info)",
                }}
              />
              <span style={{ fontSize: 12, color: "var(--ink)", flex: 1 }}>
                Gauge session{" "}
                <span style={{ color: "var(--ink-muted)" }}>
                  · {sessionCount} recording{sessionCount === 1 ? "" : "s"}
                </span>
              </span>
              <button
                onClick={endSession}
                style={{
                  background: "none",
                  border: "1px solid var(--ink-faint)",
                  color: "var(--ink-muted)",
                  padding: "6px 10px",
                  borderRadius: 6,
                  fontSize: 10,
                  cursor: "pointer",
                  fontFamily: "Inter, sans-serif",
                }}
              >
                End Session
              </button>
            </>
          ) : (
            <>
              <span style={{ fontSize: 11, color: "var(--ink-muted)", flex: 1 }}>
                Group recordings into a session
              </span>
              <button
                onClick={() =>
                  setGaugeSession({
                    id: crypto.randomUUID(),
                    startedAt: Date.now(),
                  })
                }
                style={{
                  background: "none",
                  border: "1px solid var(--ink-faint)",
                  color: "var(--ink-muted)",
                  padding: "6px 10px",
                  borderRadius: 6,
                  fontSize: 10,
                  cursor: "pointer",
                  fontFamily: "Inter, sans-serif",
                }}
              >
                Start Session
              </button>
            </>
          )}
        </div>
      )}

      {status === "unsupported" && (
        <div className="card">
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 16,
              fontWeight: 800,
              marginBottom: 8,
            }}
          >
            Bluetooth not available
          </div>
          <div style={{ fontSize: 12, color: "var(--ink-muted)", lineHeight: 1.5 }}>
            {tindeq.secure
              ? "This browser doesn't support Web Bluetooth. Use Chrome or Edge on desktop or Android — iOS Safari can't connect to Bluetooth devices."
              : "Web Bluetooth requires a secure (HTTPS) connection."}
          </div>
        </div>
      )}

      {/* Log the just-ended gauge session into History / ACWR */}
      {endingSession && (
        <div className="card" style={{ marginBottom: 10 }}>
          <div className="label-eyebrow" style={{ marginBottom: 10 }}>
            Log session to history
          </div>
          {/* Duration is the actual session wall-clock time — only RPE is asked */}
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
              padding: "10px 2px",
            }}
          >
            <span className="field-label" style={{ margin: 0 }}>
              Duration
            </span>
            <span style={{ fontSize: 15, fontWeight: 700 }}>
              {endingSession.durationMin} min{" "}
              <span style={{ fontSize: 10, color: "var(--ink-faint)", fontWeight: 400 }}>
                actual time
              </span>
            </span>
          </div>
          <span className="field-label">RPE (1–10)</span>
          <div className="stepper">
            <button
              className="stepper-btn"
              onClick={() =>
                setEndingSession((s) =>
                  s ? { ...s, rpe: Math.max(1, s.rpe - 1) } : s,
                )
              }
            >
              −
            </button>
            <span className="stepper-val">{endingSession.rpe}</span>
            <button
              className="stepper-btn"
              onClick={() =>
                setEndingSession((s) =>
                  s ? { ...s, rpe: Math.min(10, s.rpe + 1) } : s,
                )
              }
            >
              +
            </button>
          </div>
          <div className="grid-2" style={{ marginTop: 12 }}>
            <button
              className="btn-ghost"
              disabled={loggingSession}
              onClick={() => setEndingSession(null)}
            >
              Skip
            </button>
            <button
              className="btn-primary"
              disabled={loggingSession}
              onClick={() => void logEndedSession()}
            >
              {loggingSession ? "Logging…" : "Log Session"}
            </button>
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
        <div style={{ fontSize: 11, color: "var(--danger)", marginTop: 10 }}>
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
                background: status === "measuring" ? "var(--success)" : "var(--info)",
              }}
            />
            <span style={{ fontSize: 12, color: "var(--ink)", flex: 1 }}>
              Progressor{" "}
              <span style={{ color: "var(--ink-muted)" }}>
                · {status === "measuring" ? "measuring" : "connected"}
              </span>
            </span>
            {tindeq.lowBattery && (
              <span
                className="tag"
                style={{
                  background: "rgba(255,184,0,0.12)",
                  color: "var(--warning)",
                  border: "1px solid rgba(255,184,0,0.35)",
                }}
              >
                Low battery
              </span>
            )}
            <button
              onClick={tindeq.disconnect}
              style={{
                background: "none",
                border: "1px solid var(--ink-faint)",
                color: "var(--ink-muted)",
                padding: "6px 10px",
                borderRadius: 6,
                fontSize: 10,
                cursor: "pointer",
                fontFamily: "Inter, sans-serif",
              }}
            >
              Disconnect
            </button>
          </div>

          {gaugeTarget && (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 8,
                marginBottom: 8,
                fontSize: 10,
                color: "var(--ink-faint)",
              }}
            >
              <span style={{ flex: 1 }}>
                Target set: <span style={{ color: "var(--success)" }}>{gaugeTarget.label}</span>
              </span>
              <button
                onClick={() => setGaugeTarget(null)}
                style={{
                  background: "none",
                  border: "none",
                  color: "var(--ink-faint)",
                  fontSize: 10,
                  cursor: "pointer",
                  fontFamily: "Inter, sans-serif",
                  textDecoration: "underline",
                }}
              >
                clear
              </button>
            </div>
          )}
          <ForceGauge
            current={tindeq.current}
            peak={tindeq.peak}
            elapsedMs={tindeq.elapsedMs}
            samplesRef={tindeq.samplesRef}
            live={status === "measuring"}
            target={gaugeTarget}
          />

          {/* Set the tag/side before each rep — a tag is required to Start,
              so every recording is labelled without a post-stop decision. */}
          {status === "connected" && (
            <div className="card" style={{ marginTop: 10 }}>
              <div className="label-eyebrow" style={{ marginBottom: 8 }}>
                Next recording
              </div>
              <TagSideEditor
                tag={pendingTag}
                side={pendingSide}
                recentTags={recentTags}
                allTags={allTags}
                onTag={setPendingTag}
                onSide={setPendingSide}
              />
              {!pendingTag.trim() && (
                <div
                  style={{ fontSize: 11, color: "var(--ink-faint)", marginTop: 8 }}
                >
                  Add a tag to start recording.
                </div>
              )}
            </div>
          )}

          <div className="grid-2" style={{ marginTop: 10 }}>
            <button
              className="btn-ghost"
              disabled={status === "measuring"}
              onClick={() => void tindeq.tare()}
            >
              Tare
            </button>
            {status === "measuring" ? (
              <button
                className="btn-primary"
                disabled={saving}
                onClick={() => void handleStop()}
              >
                {saving ? "Saving…" : "Stop & Save"}
              </button>
            ) : (
              <button
                className="btn-primary"
                disabled={!pendingTag.trim()}
                onClick={() => {
                  setJustSaved(null);
                  void tindeq.start();
                }}
              >
                Start
              </button>
            )}
          </div>

          {/* Confirmation of the auto-saved rep (tag shown so it can be
              eyeballed; Undo deletes it for a retag + re-pull). */}
          {justSaved && status !== "measuring" && (
            <div
              className="card"
              style={{
                marginTop: 10,
                display: "flex",
                alignItems: "center",
                gap: 10,
              }}
            >
              <span
                style={{ fontSize: 12, color: "var(--success)", fontWeight: 700, flex: 1 }}
              >
                Saved · {justSaved.tag || "untagged"}
                {justSaved.side ? ` · ${justSaved.side}` : ""}
              </span>
              <span
                style={{
                  fontSize: 12,
                  color: "var(--ink)",
                  fontFamily: "Inter, sans-serif",
                  fontWeight: 800,
                }}
              >
                {justSaved.peakKg.toFixed(1)} kg
              </span>
              <button
                onClick={() => void undoJustSaved()}
                style={{
                  background: "none",
                  border: "1px solid var(--ink-faint)",
                  color: "var(--ink-muted)",
                  padding: "6px 10px",
                  borderRadius: 6,
                  fontSize: 10,
                  cursor: "pointer",
                  fontFamily: "Inter, sans-serif",
                }}
              >
                Undo
              </button>
            </div>
          )}
        </div>
      )}

      {/* Trends & force curve live in a modal */}
      {recordings.length >= 2 && (
        <button
          className="btn-ghost"
          style={{ marginTop: 10 }}
          onClick={() => setShowTrends(true)}
        >
          Trends &amp; Force Curve
        </button>
      )}

      {showTrends && (
        <div
          className="modal-bg"
          onClick={(e) => e.target === e.currentTarget && setShowTrends(false)}
        >
          <div className="modal-sheet">
            <div className="modal-handle" />
            <TindeqTrendChart
              recordings={recordings}
              selectedTag={selectedTag}
              onSelectTag={setSelectedTag}
              selectedSide={selectedSide}
              onSelectSide={setSelectedSide}
            />
            {selectedTag && (
              <ForceCurveCard
                key={`${selectedTag}|${selectedSide ?? "all"}`}
                tag={
                  selectedSide
                    ? `${selectedTag} · ${selectedSide}`
                    : selectedTag
                }
                recordings={recordings.filter(
                  (r) =>
                    r.tag === selectedTag &&
                    (selectedSide === null || r.side === selectedSide),
                )}
                onUseTarget={(t) => {
                  setGaugeTarget(t);
                  setShowTrends(false);
                  window.scrollTo({ top: 0, behavior: "smooth" });
                }}
              />
            )}
            {!selectedTag && (
              <div style={{ fontSize: 11, color: "var(--ink-faint)", marginTop: 10 }}>
                Select a tag above to see its force–duration curve and generate
                training targets.
              </div>
            )}
            <div style={{ marginTop: 12 }}>
              <button className="btn-ghost" onClick={() => setShowTrends(false)}>
                Close
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Past recordings */}
      <div
        style={{
          fontSize: 10,
          color: "var(--ink-faint)",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          margin: "20px 0 10px",
        }}
      >
        Recordings
      </div>
      {listError && (
        <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 8 }}>
          {listError}
        </div>
      )}
      {recordings.length === 0 && !listError && (
        <div
          style={{
            textAlign: "center",
            color: "var(--ink-faint)",
            fontSize: 13,
            padding: "24px 0",
          }}
        >
          No recordings yet.
        </div>
      )}
      <GroupedRecordings
        recordings={recordings}
        onDelete={(id) => void removeRecording(id)}
      />
    </div>
  );
}
