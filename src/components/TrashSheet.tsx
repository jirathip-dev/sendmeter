import { useEffect, useState } from "react";
import {
  fetchDeletedRecordings,
  fetchDeletedSessions,
  purgeRecording,
  purgeSession,
  restoreRecording,
  restoreSession,
} from "../lib/repo";
import Sheet from "./Sheet";
import type { DeletedSession, DeletedTindeqRecording } from "../types";
import { captureHandledOperationalFailure } from "../lib/monitoring";

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
      captureHandledOperationalFailure("session.restore", e, {
        automatic: false,
      });
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
      if (kind === "session") {
        captureHandledOperationalFailure("session.purge", e, {
          automatic: false,
        });
      }
      setError(e instanceof Error ? e.message : "Failed to delete forever");
    } finally {
      setBusyId(null);
    }
  }

  const loading = sessions === null || recordings === null;
  const isEmpty = !loading && sessions.length === 0 && recordings.length === 0;

  // Inline "delete forever?" confirmation, rendered directly under the row
  // whose × was tapped — no more hunting at the bottom of the sheet.
  function purgeConfirm(id: string) {
    if (confirmPurge?.id !== id) return null;
    return (
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "10px 0 12px",
          borderBottom: "1px solid var(--hairline)",
        }}
      >
        <span style={{ flex: 1, fontSize: "var(--t-sm)", color: "var(--danger)" }}>
          Delete forever? No undo.
        </span>
        <button
          className="btn-ghost"
          style={{ width: "auto", padding: "8px 12px", fontSize: "var(--t-xs)" }}
          disabled={busyId === id}
          onClick={() => setConfirmPurge(null)}
        >
          Cancel
        </button>
        <button
          className="btn-danger btn-inline"
          disabled={busyId === id}
          onClick={() => void handlePurge()}
        >
          {busyId === id ? "Deleting…" : "Delete forever"}
        </button>
      </div>
    );
  }

  return (
    <Sheet
      title="Trash"
      subtitle="Deleted sessions and Tindeq recordings stay here until you restore or permanently delete them."
      onClose={onClose}
    >

        {loading && (
          <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)" }}>
            Loading…
          </div>
        )}

        {isEmpty && (
          <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)" }}>
            Trash is empty.
          </div>
        )}

        {sessions !== null && sessions.length > 0 && (
          <div style={{ marginBottom: 18 }}>
            <div className="label-eyebrow" style={{ marginBottom: 8 }}>
              Sessions
            </div>
            {sessions.map((s) => (
              <div key={s.id}>
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 8,
                    padding: "10px 0",
                    borderBottom: confirmPurge?.id === s.id ? "none" : "1px solid var(--hairline)",
                  }}
                >
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: "var(--t-base)", color: "var(--ink)" }}>
                      {s.typeLabel}{" "}
                      <span style={{ color: "var(--ink-muted)" }}>
                        · {s.date}
                      </span>
                    </div>
                    <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
                      deleted {timeAgo(s.deletedAt)}
                    </div>
                  </div>
                  <button
                    className="btn-ghost"
                    style={{ width: "auto", padding: "8px 12px", fontSize: "var(--t-xs)" }}
                    disabled={busyId === s.id}
                    onClick={() => void handleRestoreSession(s.id)}
                  >
                    Restore
                  </button>
                  <button
                    className="btn-danger btn-inline trash-purge-button"
                    onClick={() => setConfirmPurge({ kind: "session", id: s.id })}
                    disabled={busyId === s.id}
                    style={{
                      fontSize: "var(--t-lg)",
                      padding: 4,
                    }}
                    title="Delete forever"
                  >
                    ×
                  </button>
                </div>
                {purgeConfirm(s.id)}
              </div>
            ))}
          </div>
        )}

        {recordings !== null && recordings.length > 0 && (
          <div>
            <div className="label-eyebrow" style={{ marginBottom: 8 }}>
              Tindeq Recordings
            </div>
            {recordings.map((r) => (
              <div key={r.id}>
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 8,
                    padding: "10px 0",
                    borderBottom: confirmPurge?.id === r.id ? "none" : "1px solid var(--hairline)",
                  }}
                >
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: "var(--t-base)", color: "var(--ink)" }}>
                      {r.source === "manual" ? `${r.externalLoadKg?.toFixed(1)} kg external` : `${r.peakKg?.toFixed(1)} kg`}
                      {r.tag && (
                        <span style={{ color: "var(--ink-muted)" }}>
                          {" "}
                          · {r.tag}
                        </span>
                      )}
                    </div>
                    <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>
                      deleted {timeAgo(r.deletedAt)}
                    </div>
                  </div>
                  <button
                    className="btn-ghost"
                    style={{ width: "auto", padding: "8px 12px", fontSize: "var(--t-xs)" }}
                    disabled={busyId === r.id}
                    onClick={() => void handleRestoreRecording(r.id)}
                  >
                    Restore
                  </button>
                  <button
                    className="btn-danger btn-inline trash-purge-button"
                    onClick={() =>
                      setConfirmPurge({ kind: "recording", id: r.id })
                    }
                    disabled={busyId === r.id}
                    style={{
                      fontSize: "var(--t-lg)",
                      padding: 4,
                    }}
                    title="Delete forever"
                  >
                    ×
                  </button>
                </div>
                {purgeConfirm(r.id)}
              </div>
            ))}
          </div>
        )}

        {error && (
          <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 10 }}>
            {error}
          </div>
        )}

    </Sheet>
  );
}
