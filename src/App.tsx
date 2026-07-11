import { useEffect, useMemo, useState } from "react";
import { NAV, PHASES, SESSION_TYPES } from "./constants";
import { today } from "./lib/dates";
import { computeAcwr, computeWeeklyLoads, getACWRStatus } from "./lib/metrics";
import { loadData, saveData } from "./lib/storage";
import type { LogFormState, PhaseId, Session, ViewId } from "./types";
import Dashboard from "./components/Dashboard";
import HistoryView from "./components/HistoryView";
import LogForm from "./components/LogForm";
import LogView from "./components/LogView";
import PhasesView from "./components/PhasesView";

export default function App() {
  const [data, setData] = useState(() => loadData());
  const [view, setView] = useState<ViewId>("dashboard");
  const [showModal, setShowModal] = useState(false);
  const [form, setForm] = useState<LogFormState>({
    date: today(),
    type: "fingerboard",
    duration: 45,
    rpe: 6,
    note: "",
    phase: "capacity",
  });

  const { sessions, currentPhase, phaseStartDate } = data;

  useEffect(() => {
    saveData(data);
  }, [data]);

  const acwrData = useMemo(() => computeAcwr(sessions), [sessions]);
  const weeklyLoads = useMemo(() => computeWeeklyLoads(sessions), [sessions]);

  const phase = PHASES.find((p) => p.id === currentPhase) || PHASES[0]!;
  const status = getACWRStatus(acwrData.acwr);
  const phaseDays =
    Math.floor(
      (new Date(today()).getTime() - new Date(phaseStartDate).getTime()) /
        86400000,
    ) + 1;

  function addSession() {
    const typeInfo = SESSION_TYPES.find((t) => t.id === form.type);
    const s: Session = {
      id: String(Date.now()),
      date: form.date,
      type: form.type,
      typeLabel: typeInfo?.label || form.type,
      duration: +form.duration,
      rpe: +form.rpe,
      load: form.duration * form.rpe,
      note: form.note,
      phase: form.phase,
    };
    setData((d) => ({
      ...d,
      sessions: [...d.sessions, s].sort((a, b) => b.date.localeCompare(a.date)),
    }));
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

  function deleteSession(id: string) {
    setData((d) => ({
      ...d,
      sessions: d.sessions.filter((x) => x.id !== id),
    }));
  }

  function setPhase(id: PhaseId) {
    setData((d) => ({ ...d, currentPhase: id, phaseStartDate: today() }));
  }

  function openLog() {
    setForm((f) => ({ ...f, phase: currentPhase }));
    if (view === "log") return;
    setShowModal(true);
  }

  return (
    <div className="app-shell">
      {/* Top bar */}
      <div className="topbar">
        <div>
          <div className="topbar-title">SEND LOG</div>
          <div className="topbar-sub">Climbing Periodization</div>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
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
        </div>
      </div>

      {/* Content */}
      <div className="content-area">
        {view === "dashboard" && (
          <Dashboard
            phase={phase}
            phaseDays={phaseDays}
            acwrData={acwrData}
            weeklyLoads={weeklyLoads}
            status={status}
            sessions={sessions}
            onDelete={deleteSession}
            onLog={openLog}
          />
        )}
        {view === "log" && (
          <LogView form={form} setForm={setForm} onSubmit={addSession} />
        )}
        {view === "phases" && (
          <PhasesView currentPhase={currentPhase} onSetPhase={setPhase} />
        )}
        {view === "history" && (
          <HistoryView sessions={sessions} onDelete={deleteSession} />
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
            <LogForm form={form} setForm={setForm} onSubmit={addSession} />
            <div style={{ marginTop: 10 }}>
              <button className="btn-ghost" onClick={() => setShowModal(false)}>
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
