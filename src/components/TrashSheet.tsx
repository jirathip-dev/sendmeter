import { useEffect, useState } from "react";
import {
  fetchDeletedRecordings,
  fetchDeletedSessions,
  purgeRecording,
  purgeSession,
  restoreRecording,
  restoreSession,
} from "../lib/repo";
import type { DeletedSession, DeletedTindeqRecording } from "../types";

interface Props {
  onClose: () => void;
  /// Called after a session is restored so the active list (fed by
  /// useTrainingData, which doesn't remount on tab switch) picks it up.
  onSessionRestored: () => void;
}

function timeAgo(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(ms / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export default function TrashSheet({ onClose, onSessionRestored }: Props) {
  const [sessions, setSessions] = useState<DeletedSession[] | null>(null);
  const [recordings, setRecordings] = useState<
    DeletedTindeqRecording[] | null
  >(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmPurge, setConfirmPurge] = useState<{
    kind: "session" | "recording";
    id: string;
  } | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([fetchDeletedSessions(), fetchDeletedRecordings()])
      .then(([s, r]) => {
        if (cancelled) return;
        setSessions(s);
        setRecordings(r);
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : "Failed to load trash");
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleRestoreSession(id: string) {
    setBusyId(id);
    try {
      await restoreSession(id);
      setSessions((list) => (list ? list.filter((s) => s.id !== id) : list));
      onSessionRestored();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to restore");
    } finally {
      setBusyId(null);
    }
  }

  async function handleRestoreRecording(id: string) {
    setBusyId(id);
    try {
      await restoreRecording(id);
      setRecordings((list) =>
        list ? list.filter((r) => r.id !== id) : list,
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to restore");
    } finally {
      setBusyId(null);
    }
  }

  async function handlePurge() {
    if (!confirmPurge) return;
    const { kind, id } = confirmPurge;
    setBusyId(id);
    try {
      if (kind === "session") {
        await purgeSession(id);
        setSessions((list) => (list ? list.filter((s) => s.id !== id) : list));
      } else {
        await purgeRecording(id);
        setRecordings((list) =>
          list ? list.filter((r) => r.id !== id) : list,
        );
      }
      setConfirmPurge(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to delete forever");
    } finally {
      setBusyId(null);
    }
  }

  const loading = sessions === null || recordings === null;
  const isEmpty = !loading && sessions.length === 0 && recordings.length === 0;

  return (
    <div
      className="modal-bg"
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="modal-sheet">
        <div className="modal-handle" />
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontSize: 20,
            fontWeight: 800,
            marginBottom: 6,
          }}
        >
          Trash
        </div>
        <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 16 }}>
          Deleted sessions and Tindeq recordings stay here until you restore
          or permanently delete them.
        </div>

        {loading && (
          <div style={{ fontSize: 12, color: "var(--ink-muted)" }}>
            Loading…
          </div>
        )}

        {isEmpty && (
          <div style={{ fontSize: 12, color: "var(--ink-muted)" }}>
            Trash is empty.
          </div>
        )}

        {sessions !== null && sessions.length > 0 && (
          <div style={{ marginBottom: 18 }}>
            <div
              style={{
                fontSize: 9,
                color: "var(--ink-muted)",
                textTransform: "uppercase",
                letterSpacing: "0.1em",
                marginBottom: 8,
              }}
            >
              Sessions
            </div>
            {sessions.map((s) => (
              <div
                key={s.id}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  padding: "10px 0",
                  borderBottom: "1px solid var(--hairline)",
                }}
              >
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13, color: "var(--ink)" }}>
                    {s.typeLabel}{" "}
                    <span style={{ color: "var(--ink-muted)" }}>
                      · {s.date}
                    </span>
                  </div>
                  <div style={{ fontSize: 10, color: "var(--ink-faint)" }}>
                    deleted {timeAgo(s.deletedAt)}
                  </div>
                </div>
                <button
                  className="btn-ghost"
                  style={{ width: "auto", padding: "8px 12px", fontSize: 11 }}
                  disabled={busyId === s.id}
                  onClick={() => void handleRestoreSession(s.id)}
                >
                  Restore
                </button>
                <button
                  onClick={() => setConfirmPurge({ kind: "session", id: s.id })}
                  disabled={busyId === s.id}
                  style={{
                    background: "none",
                    border: "none",
                    color: "#FF453A",
                    fontSize: 18,
                    cursor: "pointer",
                    padding: 4,
                  }}
                  title="Delete forever"
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        )}

        {recordings !== null && recordings.length > 0 && (
          <div>
            <div
              style={{
                fontSize: 9,
                color: "var(--ink-muted)",
                textTransform: "uppercase",
                letterSpacing: "0.1em",
                marginBottom: 8,
              }}
            >
              Tindeq Recordings
            </div>
            {recordings.map((r) => (
              <div
                key={r.id}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  padding: "10px 0",
                  borderBottom: "1px solid var(--hairline)",
                }}
              >
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13, color: "var(--ink)" }}>
                    {r.peakKg.toFixed(1)} kg
                    {r.tag && (
                      <span style={{ color: "var(--ink-muted)" }}>
                        {" "}
                        · {r.tag}
                      </span>
                    )}
                  </div>
                  <div style={{ fontSize: 10, color: "var(--ink-faint)" }}>
                    deleted {timeAgo(r.deletedAt)}
                  </div>
                </div>
                <button
                  className="btn-ghost"
                  style={{ width: "auto", padding: "8px 12px", fontSize: 11 }}
                  disabled={busyId === r.id}
                  onClick={() => void handleRestoreRecording(r.id)}
                >
                  Restore
                </button>
                <button
                  onClick={() =>
                    setConfirmPurge({ kind: "recording", id: r.id })
                  }
                  disabled={busyId === r.id}
                  style={{
                    background: "none",
                    border: "none",
                    color: "#FF453A",
                    fontSize: 18,
                    cursor: "pointer",
                    padding: 4,
                  }}
                  title="Delete forever"
                >
                  ×
                </button>
              </div>
            ))}
          </div>
        )}

        {confirmPurge && (
          <div
            style={{
              marginTop: 16,
              paddingTop: 14,
              borderTop: "1px solid var(--hairline)",
            }}
          >
            <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12 }}>
              Delete this {confirmPurge.kind} forever? There is no undo.
            </div>
            <div style={{ display: "flex", gap: 8 }}>
              <button
                className="btn-ghost"
                disabled={busyId === confirmPurge.id}
                onClick={() => setConfirmPurge(null)}
              >
                Cancel
              </button>
              <button
                disabled={busyId === confirmPurge.id}
                onClick={() => void handlePurge()}
                style={{
                  background: "#FF453A",
                  color: "#ffffff",
                  border: "none",
                  padding: "13px 20px",
                  borderRadius: 8,
                  width: "100%",
                  fontFamily: "Inter, sans-serif",
                  fontSize: 13,
                  fontWeight: 500,
                  cursor: "pointer",
                }}
              >
                {busyId === confirmPurge.id ? "Deleting…" : "Delete forever"}
              </button>
            </div>
          </div>
        )}

        {error && (
          <div style={{ fontSize: 11, color: "#FF453A", marginTop: 10 }}>
            {error}
          </div>
        )}

        <div style={{ marginTop: 14 }}>
          <button className="btn-ghost" onClick={onClose}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
