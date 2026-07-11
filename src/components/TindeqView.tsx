import { useEffect, useId, useState } from "react";
import { useTindeq } from "../hooks/useTindeq";
import type { StoppedRecording } from "../hooks/useTindeq";
import {
  deleteRecording,
  fetchRecordings,
  insertRecording,
} from "../lib/repo";
import type { TindeqRecordingMeta, TindeqSide } from "../types";
import ForceCurveCard from "./ForceCurveCard";
import type { GaugeTarget } from "./ForceCurveCard";
import ForceGauge from "./ForceGauge";
import RecordingRow from "./RecordingRow";
import TindeqTrendChart from "./TindeqTrendChart";

const SIDE_OPTIONS: { value: TindeqSide; label: string }[] = [
  { value: "", label: "—" },
  { value: "left", label: "Left" },
  { value: "right", label: "Right" },
  { value: "both", label: "Both" },
];

/// Shared exercise setup: used before starting a measure AND in the save
/// card, editing the same state — set once, tweak between reps.
function TagSideEditor({
  tag,
  side,
  recentTags,
  allTags,
  onTag,
  onSide,
}: {
  tag: string;
  side: TindeqSide;
  recentTags: string[];
  allTags: string[];
  onTag: (t: string) => void;
  onSide: (s: TindeqSide) => void;
}) {
  const listId = useId();
  return (
    <div>
      <div className="grid-2" style={{ gap: 10 }}>
        <div>
          <span className="field-label" style={{ marginTop: 0 }}>
            Exercise tag
          </span>
          <input
            className="field"
            value={tag}
            onChange={(e) => onTag(e.target.value)}
            placeholder="e.g. FDP"
            list={listId}
          />
          <datalist id={listId}>
            {allTags.map((t) => (
              <option key={t} value={t} />
            ))}
          </datalist>
        </div>
        <div>
          <span className="field-label" style={{ marginTop: 0 }}>
            Side
          </span>
          <select
            className="field"
            value={side}
            onChange={(e) => onSide(e.target.value as TindeqSide)}
          >
            {SIDE_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </div>
      </div>
      {recentTags.length > 0 && (
        <div
          style={{ display: "flex", gap: 5, flexWrap: "wrap", marginTop: 7 }}
        >
          {recentTags.map((t) => (
            <button
              key={t}
              className="tag"
              onClick={() => onTag(tag === t ? "" : t)}
              style={{
                background: tag === t ? "#60a5fa" : "#0a0c10",
                color: tag === t ? "#0a0c10" : "#4a5a70",
                border: `1px solid ${tag === t ? "#60a5fa" : "#1e2d40"}`,
                cursor: "pointer",
                fontFamily: "'DM Mono', monospace",
              }}
            >
              {t}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export default function TindeqView() {
  const tindeq = useTindeq();
  const [pending, setPending] = useState<StoppedRecording | null>(null);
  const [pendingNote, setPendingNote] = useState("");
  const [pendingTag, setPendingTag] = useState("");
  const [pendingSide, setPendingSide] = useState<TindeqSide>("");
  const [gaugeSession, setGaugeSession] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [recordings, setRecordings] = useState<TindeqRecordingMeta[]>([]);
  const [listError, setListError] = useState<string | null>(null);
  const [selectedTag, setSelectedTag] = useState<string | null>(null);
  const [selectedSide, setSelectedSide] = useState<TindeqSide | null>(null);
  const [gaugeTarget, setGaugeTarget] = useState<GaugeTarget | null>(null);

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
    ? recordings.filter((r) => r.groupId === gaugeSession).length
    : 0;

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
        tag: pendingTag.trim(),
        side: pendingSide,
        groupId: gaugeSession,
        samples: pending.samples,
      });
      setRecordings((list) => [saved, ...list]);
      setPending(null);
      // keep tag and side — set them once, tweak side between reps
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

      {/* Gauge session bar */}
      {status !== "unsupported" && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            padding: "10px 14px",
            background: gaugeSession ? "rgba(96,165,250,0.08)" : "#0f1420",
            border: `1px solid ${gaugeSession ? "rgba(96,165,250,0.35)" : "#1a2030"}`,
            borderRadius: 8,
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
                  background: "#60a5fa",
                }}
              />
              <span style={{ fontSize: 12, color: "#e2e8f0", flex: 1 }}>
                Gauge session{" "}
                <span style={{ color: "#4a5a70" }}>
                  · {sessionCount} recording{sessionCount === 1 ? "" : "s"}
                </span>
              </span>
              <button
                onClick={() => setGaugeSession(null)}
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
                End Session
              </button>
            </>
          ) : (
            <>
              <span style={{ fontSize: 11, color: "#4a5a70", flex: 1 }}>
                Group recordings into a session
              </span>
              <button
                onClick={() => setGaugeSession(crypto.randomUUID())}
                style={{
                  background: "none",
                  border: "1px solid #2a3a50",
                  color: "#7a8a9a",
                  padding: "6px 10px",
                  borderRadius: 6,
                  fontSize: 10,
                  cursor: "pointer",
                  fontFamily: "'DM Mono', monospace",
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

          {gaugeTarget && (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 8,
                marginBottom: 8,
                fontSize: 10,
                color: "#4a5a70",
              }}
            >
              <span style={{ flex: 1 }}>
                Target set: <span style={{ color: "#4ade80" }}>{gaugeTarget.label}</span>
              </span>
              <button
                onClick={() => setGaugeTarget(null)}
                style={{
                  background: "none",
                  border: "none",
                  color: "#3a4a60",
                  fontSize: 10,
                  cursor: "pointer",
                  fontFamily: "'DM Mono', monospace",
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

          {/* Exercise setup before each measure */}
          {status === "connected" && !pending && (
            <div className="card" style={{ marginTop: 10 }}>
              <div
                style={{
                  fontSize: 9,
                  color: "#4a5a70",
                  textTransform: "uppercase",
                  letterSpacing: "0.1em",
                  marginBottom: 8,
                }}
              >
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
              <div style={{ marginTop: 12 }}>
                <TagSideEditor
                  tag={pendingTag}
                  side={pendingSide}
                  recentTags={recentTags}
                  allTags={allTags}
                  onTag={setPendingTag}
                  onSide={setPendingSide}
                />
              </div>
              <span className="field-label">Note (optional)</span>
              <input
                className="field"
                value={pendingNote}
                onChange={(e) => setPendingNote(e.target.value)}
                placeholder="e.g. half crimp 20mm"
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
      <TindeqTrendChart
        recordings={recordings}
        selectedTag={selectedTag}
        onSelectTag={setSelectedTag}
        selectedSide={selectedSide}
        onSelectSide={setSelectedSide}
      />

      {/* Force–duration curve for the selected exercise (+side) */}
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
            window.scrollTo({ top: 0, behavior: "smooth" });
          }}
        />
      )}

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
      <GroupedRecordings
        recordings={recordings}
        onDelete={(id) => void removeRecording(id)}
      />
    </div>
  );
}

/// Recordings sharing a group_id render as one session block with a header;
/// ungrouped recordings render as standalone rows. Blocks are ordered by
/// their most recent recording.
function GroupedRecordings({
  recordings,
  onDelete,
}: {
  recordings: TindeqRecordingMeta[];
  onDelete: (id: string) => void;
}) {
  type Block =
    | { kind: "single"; rec: TindeqRecordingMeta; latest: string }
    | { kind: "group"; id: string; recs: TindeqRecordingMeta[]; latest: string };

  const groups = new Map<string, TindeqRecordingMeta[]>();
  const blocks: Block[] = [];
  for (const rec of recordings) {
    if (!rec.groupId) {
      blocks.push({ kind: "single", rec, latest: rec.recordedAt });
    } else if (groups.has(rec.groupId)) {
      groups.get(rec.groupId)!.push(rec);
    } else {
      const recs = [rec];
      groups.set(rec.groupId, recs);
      blocks.push({ kind: "group", id: rec.groupId, recs, latest: rec.recordedAt });
    }
  }
  blocks.sort((a, b) => b.latest.localeCompare(a.latest));

  const fmtTime = (iso: string) => {
    const d = new Date(iso);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  };
  const fmtDate = (iso: string) => {
    const d = new Date(iso);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  };

  return (
    <div>
      {blocks.map((b) =>
        b.kind === "single" ? (
          <RecordingRow key={b.rec.id} rec={b.rec} onDelete={onDelete} />
        ) : (
          <div
            key={b.id}
            style={{
              border: "1px solid #1e2d40",
              borderRadius: 10,
              padding: "10px 8px 2px",
              marginBottom: 8,
            }}
          >
            <div
              style={{
                display: "flex",
                alignItems: "baseline",
                gap: 8,
                flexWrap: "wrap",
                padding: "0 6px 8px",
              }}
            >
              <span style={{ fontSize: 11, color: "#e2e8f0" }}>
                {fmtDate(b.recs[b.recs.length - 1]!.recordedAt)}
              </span>
              <span style={{ fontSize: 10, color: "#4a5a70" }}>
                {fmtTime(b.recs[b.recs.length - 1]!.recordedAt)}–
                {fmtTime(b.recs[0]!.recordedAt)} · {b.recs.length} recording
                {b.recs.length === 1 ? "" : "s"}
              </span>
              <span style={{ fontSize: 10, color: "#3a4a60" }}>
                {[...new Set(b.recs.map((r) => r.tag).filter(Boolean))].join(
                  " · ",
                )}
              </span>
            </div>
            {b.recs.map((rec) => (
              <RecordingRow key={rec.id} rec={rec} onDelete={onDelete} />
            ))}
          </div>
        ),
      )}
    </div>
  );
}
