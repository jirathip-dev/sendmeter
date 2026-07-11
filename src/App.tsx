import { useMemo, useState } from "react";
import { NAV, PHASES } from "./constants";
import { today } from "./lib/dates";
import { computeAcwr, computeWeeklyLoads, getACWRStatus } from "./lib/metrics";
import {
  importLegacyData,
  markLegacyImported,
  readLegacyData,
} from "./lib/import-legacy";
import { useAuth } from "./hooks/useAuth";
import { useTrainingData } from "./hooks/useTrainingData";
import type { LogFormState, ViewId } from "./types";
import Dashboard from "./components/Dashboard";
import HistoryView from "./components/HistoryView";
import LoginScreen from "./components/LoginScreen";
import LogForm from "./components/LogForm";
import LogView from "./components/LogView";
import PhasesView from "./components/PhasesView";
import TindeqView from "./components/TindeqView";

export default function App() {
  const { session, loading, signOut } = useAuth();

  if (loading) {
    return (
      <div
        className="app-shell"
        style={{ alignItems: "center", justifyContent: "center" }}
      >
        <div style={{ fontSize: 11, color: "#4a5a70" }}>loading…</div>
      </div>
    );
  }

  if (!session) return <LoginScreen />;

  return <AuthedApp userId={session.user.id} onSignOut={signOut} />;
}

function AuthedApp({
  userId,
  onSignOut,
}: {
  userId: string;
  onSignOut: () => Promise<{ error: Error | null }>;
}) {
  const {
    sessions,
    currentPhase,
    phaseStartDate,
    loading,
    error,
    dismissError,
    addSession,
    removeSession,
    setPhase,
    reload,
  } = useTrainingData(userId);

  const [view, setView] = useState<ViewId>("dashboard");
  const [showModal, setShowModal] = useState(false);
  const [importDismissed, setImportDismissed] = useState(false);
  const [importing, setImporting] = useState(false);
  const [form, setForm] = useState<LogFormState>({
    date: today(),
    type: "fingerboard",
    duration: 45,
    rpe: 6,
    note: "",
    phase: "capacity",
  });

  const legacy = useMemo(() => readLegacyData(), []);
  const importPrompt =
    !loading && !!legacy && sessions.length === 0 && !importDismissed;

  const acwrData = useMemo(() => computeAcwr(sessions), [sessions]);
  const weeklyLoads = useMemo(() => computeWeeklyLoads(sessions), [sessions]);

  const phase = PHASES.find((p) => p.id === currentPhase) || PHASES[0]!;
  const status = getACWRStatus(acwrData.acwr);
  const phaseDays =
    Math.floor(
      (new Date(today()).getTime() - new Date(phaseStartDate).getTime()) /
        86400000,
    ) + 1;

  function submitSession() {
    void addSession(form);
    setShowModal(false);
    setForm({
      date: today(),
      type: "fingerboard",
      duration: 45,
      rpe: 6,
      note: "",
      phase: currentPhase,
    });
  }

  function openLog() {
    setForm((f) => ({ ...f, phase: currentPhase }));
    if (view === "log") return;
    setShowModal(true);
  }

  async function runImport() {
    if (!legacy) return;
    setImporting(true);
    try {
      await importLegacyData(legacy);
      markLegacyImported();
      setImportDismissed(true);
      await reload();
    } catch {
      // error banner comes from reload/fetch; keep prompt open so user can retry
    } finally {
      setImporting(false);
    }
  }

  function discardImport() {
    markLegacyImported();
    setImportDismissed(true);
  }

  return (
    <div className="app-shell">
      {/* Top bar */}
      <div className="topbar">
        <div>
          <div className="topbar-title">SEND LOG</div>
          <div className="topbar-sub">Climbing Periodization</div>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <div style={{ textAlign: "right" }}>
            <div
              style={{
                fontSize: 9,
                color: "#4a5a70",
                textTransform: "uppercase",
                letterSpacing: "0.08em",
              }}
            >
              Phase / Day
            </div>
            <div
              style={{
                fontSize: 13,
                color: phase.color,
                fontFamily: "'Syne', sans-serif",
                fontWeight: 800,
              }}
            >
              {phase.name} · {phaseDays}
            </div>
          </div>
          <div
            style={{
              width: 8,
              height: 8,
              borderRadius: "50%",
              background: phase.color,
            }}
          />
          <button
            onClick={() => void onSignOut()}
            style={{
              background: "none",
              border: "none",
              color: "#3a4a60",
              fontSize: 9,
              textTransform: "uppercase",
              letterSpacing: "0.08em",
              cursor: "pointer",
              padding: 4,
              fontFamily: "'DM Mono', monospace",
            }}
          >
            Sign out
          </button>
        </div>
      </div>

      {/* Error banner */}
      {error && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 8,
            padding: "8px 16px",
            background: "rgba(248,113,113,0.12)",
            borderBottom: "1px solid rgba(248,113,113,0.35)",
            fontSize: 11,
            color: "#f87171",
          }}
        >
          <span>{error}</span>
          <button
            onClick={dismissError}
            style={{
              background: "none",
              border: "none",
              color: "#f87171",
              fontSize: 16,
              cursor: "pointer",
            }}
          >
            ×
          </button>
        </div>
      )}

      {/* Content */}
      <div className="content-area">
        {loading ? (
          <div
            style={{
              textAlign: "center",
              color: "#2a3a50",
              fontSize: 13,
              padding: "60px 0",
            }}
          >
            loading…
          </div>
        ) : (
          <>
            {view === "dashboard" && (
              <Dashboard
                phase={phase}
                phaseDays={phaseDays}
                acwrData={acwrData}
                weeklyLoads={weeklyLoads}
                status={status}
                sessions={sessions}
                onDelete={(id) => void removeSession(id)}
                onLog={openLog}
              />
            )}
            {view === "log" && (
              <LogView form={form} setForm={setForm} onSubmit={submitSession} />
            )}
            {view === "phases" && (
              <PhasesView
                currentPhase={currentPhase}
                onSetPhase={(id) => void setPhase(id)}
              />
            )}
            {view === "history" && (
              <HistoryView
                sessions={sessions}
                onDelete={(id) => void removeSession(id)}
              />
            )}
            {view === "tindeq" && <TindeqView />}
          </>
        )}
      </div>

      {/* Bottom nav */}
      <div className="bottom-nav">
        {NAV.map((n) => (
          <button
            key={n.id}
            className={`nav-item ${view === n.id ? "active" : ""}`}
            onClick={() => {
              setView(n.id);
              if (n.id === "log") setShowModal(false);
            }}
          >
            <span className="nav-icon">{n.icon}</span>
            <span className="nav-label">{n.label}</span>
          </button>
        ))}
      </div>

      {/* Log bottom sheet modal */}
      {showModal && (
        <div
          className="modal-bg"
          onClick={(e) => e.target === e.currentTarget && setShowModal(false)}
        >
          <div className="modal-sheet">
            <div className="modal-handle" />
            <div
              style={{
                fontFamily: "'Syne', sans-serif",
                fontSize: 20,
                fontWeight: 800,
                marginBottom: 2,
              }}
            >
              Log Session
            </div>
            <div style={{ fontSize: 11, color: "#4a5a70", marginBottom: 4 }}>
              Load = Duration × RPE
            </div>
            <LogForm form={form} setForm={setForm} onSubmit={submitSession} />
            <div style={{ marginTop: 10 }}>
              <button className="btn-ghost" onClick={() => setShowModal(false)}>
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Legacy import bottom sheet */}
      {importPrompt && legacy && (
        <div className="modal-bg">
          <div className="modal-sheet">
            <div className="modal-handle" />
            <div
              style={{
                fontFamily: "'Syne', sans-serif",
                fontSize: 20,
                fontWeight: 800,
                marginBottom: 6,
              }}
            >
              Import local data?
            </div>
            <div style={{ fontSize: 12, color: "#7a8a9a", marginBottom: 16 }}>
              Found {legacy.sessions.length} session
              {legacy.sessions.length === 1 ? "" : "s"} saved on this device
              from before your account existed. Import them into your account?
            </div>
            <button
              className="btn-primary"
              disabled={importing}
              onClick={() => void runImport()}
            >
              {importing
                ? "Importing…"
                : `Import ${legacy.sessions.length} sessions`}
            </button>
            <div style={{ marginTop: 10 }}>
              <button
                className="btn-ghost"
                disabled={importing}
                onClick={discardImport}
              >
                Discard local data
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
