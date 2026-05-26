import { useState, useEffect, useMemo } from "react";

const PHASES = [
  {
    id: "capacity",
    name: "Capacity",
    color: "#4ade80",
    bg: "rgba(74,222,128,0.12)",
    border: "rgba(74,222,128,0.35)",
    acwr: "0.9–1.1",
    weeks: "4–6 wks",
    desc: "Aerobic base, density repeaters, high volume low intensity",
    tools: ["Density repeaters", "ARC traversing", "Low-intensity hangs"],
    intensity: "50–65%",
  },
  {
    id: "strength",
    name: "Strength",
    color: "#facc15",
    bg: "rgba(250,204,21,0.12)",
    border: "rgba(250,204,21,0.35)",
    acwr: "0.8–1.0",
    weeks: "3–5 wks",
    desc: "Max recruitment, heavy hangs, limit bouldering",
    tools: ["Max hangs 7–10s", "Limit bouldering", "Weighted fingerboard"],
    intensity: "85–100%",
  },
  {
    id: "power",
    name: "Power",
    color: "#f97316",
    bg: "rgba(249,115,22,0.12)",
    border: "rgba(249,115,22,0.35)",
    acwr: "0.8–1.0",
    weeks: "2–4 wks",
    desc: "Explosive contact strength, campus board, dynamic moves",
    tools: ["Campus board", "Dynamic bouldering", "Limit board problems"],
    intensity: "Max effort",
  },
  {
    id: "execution",
    name: "Execution",
    color: "#818cf8",
    bg: "rgba(129,140,248,0.12)",
    border: "rgba(129,140,248,0.35)",
    acwr: "0.7–0.9",
    weeks: "2–3 wks",
    desc: "Performance consolidation, projecting, fatigue clearance",
    tools: ["Projecting", "Footwork drills", "Easy-moderate volume"],
    intensity: "Moderate",
  },
];

const SESSION_TYPES = [
  {
    id: "fingerboard",
    label: "Fingerboard",
    defaultRpe: 6,
    defaultDuration: 45,
  },
  { id: "board", label: "Board Climbing", defaultRpe: 8, defaultDuration: 60 },
  {
    id: "outdoor",
    label: "Outdoor / Projecting",
    defaultRpe: 5,
    defaultDuration: 180,
  },
  {
    id: "antagonist",
    label: "Antagonist / Mobility",
    defaultRpe: 4,
    defaultDuration: 30,
  },
  { id: "arc", label: "ARC / Traversing", defaultRpe: 4, defaultDuration: 40 },
  { id: "campus", label: "Campus Board", defaultRpe: 9, defaultDuration: 30 },
  { id: "custom", label: "Custom", defaultRpe: 6, defaultDuration: 60 },
];

const NAV = [
  { id: "dashboard", icon: "⬡", label: "Home" },
  { id: "log", icon: "+", label: "Log" },
  { id: "phases", icon: "◈", label: "Phases" },
  { id: "history", icon: "≡", label: "History" },
];

function dateStr(d) {
  return d.toISOString().split("T")[0];
}
function today() {
  return dateStr(new Date());
}
function daysAgo(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return dateStr(d);
}

function getACWRStatus(acwr) {
  if (acwr === null) return { label: "No data", color: "#64748b" };
  if (acwr < 0.7) return { label: "Under-training", color: "#818cf8" };
  if (acwr <= 0.8) return { label: "Low", color: "#60a5fa" };
  if (acwr <= 1.3) return { label: "Optimal", color: "#4ade80" };
  if (acwr <= 1.5) return { label: "Caution", color: "#facc15" };
  return { label: "Danger", color: "#f87171" };
}

const STORAGE_KEY = "climbing_tracker_v1";
function loadData() {
  try {
    const r = localStorage.getItem(STORAGE_KEY);
    if (r) return JSON.parse(r);
  } catch {}
  return { sessions: [], currentPhase: "capacity", phaseStartDate: today() };
}
function saveData(d) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(d));
  } catch {}
}

const STYLES = `
  @import url('https://fonts.googleapis.com/css2?family=DM+Mono:wght@300;400;500&family=Syne:wght@700;800&display=swap');
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; overflow: hidden; }
  #root { height: 100%; }
  ::-webkit-scrollbar { width: 3px; } ::-webkit-scrollbar-track { background: #0a0c10; } ::-webkit-scrollbar-thumb { background: #334155; border-radius: 2px; }

  .app-shell {
    display: flex; flex-direction: column; height: 100dvh;
    background: #0a0c10; color: #e2e8f0;
    font-family: 'DM Mono', 'Fira Mono', monospace;
    overflow: hidden;
  }

  /* Top bar */
  .topbar {
    flex-shrink: 0;
    display: flex; align-items: center; justify-content: space-between;
    padding: 0 16px; height: 52px;
    border-bottom: 1px solid #1a2030;
    background: #0a0c10;
  }
  .topbar-title { font-family: 'Syne', sans-serif; font-size: 17px; font-weight: 800; letter-spacing: -0.02em; color: #e2e8f0; }
  .topbar-sub { font-size: 9px; color: #2a3a50; letter-spacing: 0.1em; text-transform: uppercase; margin-top: 1px; }

  /* Scrollable content */
  .content-area {
    flex: 1; overflow-y: auto; overflow-x: hidden;
    padding: 16px 16px 8px;
    -webkit-overflow-scrolling: touch;
  }

  /* Bottom nav */
  .bottom-nav {
    flex-shrink: 0;
    display: flex; align-items: stretch;
    border-top: 1px solid #1a2030;
    background: #080a0e;
    padding-bottom: env(safe-area-inset-bottom);
  }
  .nav-item {
    flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center;
    gap: 3px; padding: 10px 4px 8px;
    background: none; border: none; cursor: pointer;
    color: #3a4a60; transition: color 0.15s;
    font-family: 'DM Mono', monospace;
    -webkit-tap-highlight-color: transparent;
  }
  .nav-item.active { color: #e2e8f0; }
  .nav-item:active { opacity: 0.7; }
  .nav-icon { font-size: 18px; line-height: 1; }
  .nav-label { font-size: 9px; letter-spacing: 0.08em; text-transform: uppercase; }

  /* Cards */
  .card { background: #0f1420; border: 1px solid #1a2030; border-radius: 10px; padding: 16px; }
  .card + .card { margin-top: 10px; }

  /* Phase banner */
  .phase-banner { border-radius: 10px; padding: 16px; margin-bottom: 10px; }

  /* Grid */
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }

  /* Buttons */
  .btn-primary {
    background: #e2e8f0; color: #0a0c10; border: none;
    padding: 14px 20px; border-radius: 8px; width: 100%;
    font-family: 'DM Mono', monospace; font-size: 13px;
    font-weight: 500; letter-spacing: 0.04em; cursor: pointer;
    transition: opacity 0.15s; -webkit-tap-highlight-color: transparent;
  }
  .btn-primary:active { opacity: 0.8; }
  .btn-ghost {
    background: none; border: 1px solid #2a3a50; color: #64748b;
    padding: 13px 20px; border-radius: 8px; width: 100%;
    font-family: 'DM Mono', monospace; font-size: 13px; cursor: pointer;
    transition: border-color 0.15s; -webkit-tap-highlight-color: transparent;
  }
  .btn-ghost:active { border-color: #64748b; }

  /* Form fields */
  .field-label { display: block; font-size: 10px; color: #4a5a70; text-transform: uppercase; letter-spacing: 0.1em; margin-bottom: 7px; margin-top: 14px; }
  .field {
    width: 100%; background: #0f1420; border: 1px solid #1e2d40; color: #e2e8f0;
    padding: 13px 14px; border-radius: 8px;
    font-family: 'DM Mono', monospace; font-size: 15px; outline: none;
    transition: border-color 0.15s; -webkit-appearance: none; appearance: none;
  }
  .field:focus { border-color: #4a6080; }
  select.field { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='8' viewBox='0 0 12 8'%3E%3Cpath d='M1 1l5 5 5-5' stroke='%234a5a70' stroke-width='1.5' fill='none' stroke-linecap='round'/%3E%3C/svg%3E"); background-repeat: no-repeat; background-position: right 14px center; padding-right: 36px; }
  select.field option { background: #0f1420; }
  textarea.field { resize: none; }

  /* RPE stepper */
  .stepper { display: flex; align-items: center; background: #0f1420; border: 1px solid #1e2d40; border-radius: 8px; overflow: hidden; }
  .stepper-btn { flex-shrink: 0; width: 48px; height: 50px; background: none; border: none; color: #64748b; font-size: 22px; cursor: pointer; display: flex; align-items: center; justify-content: center; -webkit-tap-highlight-color: transparent; }
  .stepper-btn:active { background: #1e2d40; }
  .stepper-val { flex: 1; text-align: center; font-size: 20px; color: #e2e8f0; font-family: 'Syne', sans-serif; font-weight: 800; }

  /* Load preview */
  .load-preview { background: #1a2535; border-radius: 8px; padding: 14px 16px; margin-top: 14px; display: flex; justify-content: space-between; align-items: center; }

  /* ACWR bar */
  .acwr-track { height: 6px; background: #1a2030; border-radius: 3px; overflow: visible; position: relative; margin: 12px 0 6px; }

  /* Session row */
  .session-row { display: flex; align-items: center; gap: 12px; padding: 13px 14px; background: #0f1420; border: 1px solid #1a2030; border-radius: 8px; margin-bottom: 8px; }
  .session-phase-bar { width: 3px; height: 38px; border-radius: 2px; flex-shrink: 0; }
  .del-btn { background: none; border: none; color: #2a3a50; font-size: 20px; padding: 4px 8px; cursor: pointer; margin-left: auto; flex-shrink: 0; -webkit-tap-highlight-color: transparent; }
  .del-btn:active { color: #f87171; }

  /* Tag */
  .tag { display: inline-block; padding: 2px 7px; border-radius: 3px; font-size: 9px; text-transform: uppercase; letter-spacing: 0.07em; }

  /* Phase card */
  .phase-card { border-radius: 10px; padding: 16px; cursor: pointer; transition: transform 0.15s; margin-bottom: 10px; -webkit-tap-highlight-color: transparent; }
  .phase-card:active { transform: scale(0.98); }

  /* Section heading */
  .section-head { font-family: 'Syne', sans-serif; font-size: 22px; font-weight: 800; color: #e2e8f0; margin-bottom: 6px; }
  .section-sub { font-size: 11px; color: #4a5a70; margin-bottom: 18px; }

  /* Modal */
  .modal-bg { position: fixed; inset: 0; background: rgba(0,0,0,0.75); z-index: 200; display: flex; flex-direction: column; justify-content: flex-end; }
  .modal-sheet { background: #0d1117; border-top: 1px solid #1e2d40; border-radius: 16px 16px 0 0; padding: 20px 16px calc(16px + env(safe-area-inset-bottom)); max-height: 92dvh; overflow-y: auto; }
  .modal-handle { width: 36px; height: 4px; background: #2a3a50; border-radius: 2px; margin: 0 auto 18px; }

  /* Zone legend */
  .zone-row { display: flex; align-items: center; gap: 10px; margin-bottom: 9px; }
  .zone-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
`;

export default function App() {
  const [data, setData] = useState(() => loadData());
  const [view, setView] = useState("dashboard");
  const [showModal, setShowModal] = useState(false);
  const [form, setForm] = useState({
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

  const acwrData = useMemo(() => {
    const acute = sessions
      .filter((s) => s.date >= daysAgo(6) && s.date <= today())
      .reduce((sum, s) => sum + s.load, 0);
    const chronic =
      sessions
        .filter((s) => s.date >= daysAgo(27) && s.date <= today())
        .reduce((sum, s) => sum + s.load, 0) / 4;
    return { acute, chronic, acwr: chronic > 0 ? acute / chronic : null };
  }, [sessions]);

  const weeklyLoads = useMemo(
    () =>
      [3, 2, 1, 0].map((wb) => {
        const start = daysAgo(wb * 7 + 6),
          end = daysAgo(wb * 7);
        const total = sessions
          .filter((s) => s.date >= start && s.date <= end)
          .reduce((sum, s) => sum + s.load, 0);
        return { label: wb === 0 ? "Now" : `${wb}w`, total };
      }),
    [sessions],
  );

  const phase = PHASES.find((p) => p.id === currentPhase) || PHASES[0];
  const status = getACWRStatus(acwrData.acwr);
  const phaseDays =
    Math.floor((new Date(today()) - new Date(phaseStartDate)) / 86400000) + 1;

  function addSession() {
    const typeInfo = SESSION_TYPES.find((t) => t.id === form.type);
    const load = form.duration * form.rpe;
    const s = {
      id: Date.now(),
      date: form.date,
      type: form.type,
      typeLabel: typeInfo?.label || form.type,
      duration: +form.duration,
      rpe: +form.rpe,
      load,
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

  function openLog() {
    setForm((f) => ({ ...f, phase: currentPhase }));
    if (view === "log") return;
    setShowModal(true);
  }

  return (
    <div className="app-shell">
      <style>{STYLES}</style>

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
            setData={setData}
            onLog={openLog}
          />
        )}
        {view === "log" && (
          <LogView
            form={form}
            setForm={setForm}
            onSubmit={addSession}
            currentPhase={currentPhase}
          />
        )}
        {view === "phases" && (
          <PhasesView currentPhase={currentPhase} setData={setData} />
        )}
        {view === "history" && (
          <HistoryView sessions={sessions} setData={setData} />
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

function Dashboard({
  phase,
  phaseDays,
  acwrData,
  weeklyLoads,
  status,
  sessions,
  setData,
  onLog,
}) {
  const recent = sessions.slice(0, 6);
  const maxW = Math.max(...weeklyLoads.map((w) => w.total), 1);

  return (
    <div>
      {/* Phase strip */}
      <div
        className="phase-banner"
        style={{
          background: phase.bg,
          border: `1px solid ${phase.border}`,
          marginBottom: 10,
        }}
      >
        <div
          style={{
            fontSize: 9,
            color: phase.color,
            textTransform: "uppercase",
            letterSpacing: "0.12em",
            marginBottom: 4,
          }}
        >
          Current Phase — Day {phaseDays}
        </div>
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "flex-start",
          }}
        >
          <div>
            <div
              style={{
                fontFamily: "'Syne', sans-serif",
                fontSize: 26,
                fontWeight: 800,
                color: phase.color,
                letterSpacing: "-0.02em",
                lineHeight: 1,
              }}
            >
              {phase.name.toUpperCase()}
            </div>
            <div style={{ fontSize: 11, color: "#7a8a9a", marginTop: 5 }}>
              {phase.desc}
            </div>
          </div>
          <div style={{ textAlign: "right", flexShrink: 0, marginLeft: 12 }}>
            <div
              style={{
                fontSize: 9,
                color: "#4a5a70",
                textTransform: "uppercase",
              }}
            >
              Target ACWR
            </div>
            <div
              style={{
                fontSize: 20,
                color: phase.color,
                fontFamily: "'Syne', sans-serif",
                fontWeight: 800,
              }}
            >
              {phase.acwr}
            </div>
          </div>
        </div>
      </div>

      {/* ACWR + Load grid */}
      <div className="grid-2" style={{ marginBottom: 10 }}>
        <div className="card">
          <div
            style={{
              fontSize: 9,
              color: "#4a5a70",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 8,
            }}
          >
            ACWR
          </div>
          <div
            style={{
              fontFamily: "'Syne', sans-serif",
              fontSize: 38,
              fontWeight: 800,
              color: status.color,
              letterSpacing: "-0.04em",
              lineHeight: 1,
            }}
          >
            {acwrData.acwr !== null ? acwrData.acwr.toFixed(2) : "—"}
          </div>
          <div style={{ fontSize: 11, color: status.color, marginTop: 4 }}>
            {status.label}
          </div>
          <div className="acwr-track">
            <div
              style={{
                position: "absolute",
                left: 0,
                top: 0,
                width: "100%",
                height: "100%",
                background:
                  "linear-gradient(to right, #818cf8 0%,#60a5fa 15%,#4ade80 30%,#4ade80 68%,#facc15 80%,#f87171 100%)",
                opacity: 0.55,
                borderRadius: 3,
              }}
            />
            {acwrData.acwr !== null && (
              <div
                style={{
                  position: "absolute",
                  top: "50%",
                  left: `${Math.min(Math.max((acwrData.acwr / 2) * 100, 0), 100)}%`,
                  transform: "translate(-50%,-50%)",
                  width: 12,
                  height: 12,
                  borderRadius: "50%",
                  background: status.color,
                  border: "2px solid #0a0c10",
                  zIndex: 1,
                }}
              />
            )}
          </div>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: 9,
              color: "#2a3a50",
            }}
          >
            <span>0</span>
            <span>1.0</span>
            <span>1.5</span>
            <span>2</span>
          </div>
        </div>

        <div className="card">
          <div
            style={{
              fontSize: 9,
              color: "#4a5a70",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 10,
            }}
          >
            Load (AU)
          </div>
          <div style={{ marginBottom: 12 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                fontSize: 11,
                marginBottom: 5,
              }}
            >
              <span style={{ color: "#4a5a70" }}>Acute 7d</span>
              <span style={{ color: "#e2e8f0" }}>
                {acwrData.acute.toFixed(0)}
              </span>
            </div>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                fontSize: 11,
              }}
            >
              <span style={{ color: "#4a5a70" }}>Chronic avg</span>
              <span style={{ color: "#e2e8f0" }}>
                {acwrData.chronic.toFixed(0)}
              </span>
            </div>
          </div>
          <div
            style={{
              display: "flex",
              gap: 4,
              alignItems: "flex-end",
              height: 40,
            }}
          >
            {weeklyLoads.map((w, i) => (
              <div
                key={i}
                style={{
                  flex: 1,
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 3,
                }}
              >
                <div
                  style={{
                    width: "100%",
                    height: Math.max((w.total / maxW) * 32, 2),
                    background: i === 3 ? "#4ade80" : "#1e2d40",
                    borderRadius: 2,
                    transition: "height 0.4s",
                  }}
                />
                <div style={{ fontSize: 8, color: "#2a3a50" }}>{w.label}</div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Log button */}
      <button
        className="btn-primary"
        style={{ marginBottom: 16 }}
        onClick={onLog}
      >
        + Log Session
      </button>

      {/* Recent */}
      <div
        style={{
          fontSize: 10,
          color: "#4a5a70",
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          marginBottom: 10,
        }}
      >
        Recent Sessions
      </div>
      {recent.length === 0 && (
        <div
          style={{
            textAlign: "center",
            color: "#2a3a50",
            fontSize: 13,
            padding: "32px 0",
          }}
        >
          No sessions yet. Tap + Log Session to start.
        </div>
      )}
      {recent.map((s) => (
        <SessionRow key={s.id} s={s} setData={setData} />
      ))}
    </div>
  );
}

function LogView({ form, setForm, onSubmit, currentPhase }) {
  return (
    <div>
      <div className="section-head">LOG SESSION</div>
      <div className="section-sub">Load = Duration × RPE</div>
      <LogForm form={form} setForm={setForm} onSubmit={onSubmit} />
    </div>
  );
}

function LogForm({ form, setForm, onSubmit }) {
  const load = form.duration * form.rpe;

  function handleType(e) {
    const t = SESSION_TYPES.find((x) => x.id === e.target.value);
    setForm((f) => ({
      ...f,
      type: e.target.value,
      duration: t?.defaultDuration || f.duration,
      rpe: t?.defaultRpe || f.rpe,
    }));
  }

  return (
    <div>
      <span className="field-label">Date</span>
      <input
        className="field"
        type="date"
        value={form.date}
        onChange={(e) => setForm((f) => ({ ...f, date: e.target.value }))}
      />

      <span className="field-label">Session Type</span>
      <select className="field" value={form.type} onChange={handleType}>
        {SESSION_TYPES.map((t) => (
          <option key={t.id} value={t.id}>
            {t.label}
          </option>
        ))}
      </select>

      <span className="field-label">Phase</span>
      <select
        className="field"
        value={form.phase}
        onChange={(e) => setForm((f) => ({ ...f, phase: e.target.value }))}
      >
        {PHASES.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
          </option>
        ))}
      </select>

      <span className="field-label">Duration (minutes)</span>
      <div className="stepper">
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, duration: Math.max(5, f.duration - 5) }))
          }
        >
          −
        </button>
        <span className="stepper-val">{form.duration}</span>
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, duration: Math.min(300, f.duration + 5) }))
          }
        >
          +
        </button>
      </div>

      <span className="field-label">RPE (1–10)</span>
      <div className="stepper">
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, rpe: Math.max(1, f.rpe - 1) }))
          }
        >
          −
        </button>
        <span className="stepper-val">{form.rpe}</span>
        <button
          className="stepper-btn"
          onClick={() =>
            setForm((f) => ({ ...f, rpe: Math.min(10, f.rpe + 1) }))
          }
        >
          +
        </button>
      </div>

      <div className="load-preview">
        <span style={{ fontSize: 11, color: "#4a5a70" }}>Session Load</span>
        <span
          style={{
            fontSize: 24,
            color: "#e2e8f0",
            fontFamily: "'Syne', sans-serif",
            fontWeight: 800,
          }}
        >
          {load} <span style={{ fontSize: 13, color: "#4a5a70" }}>AU</span>
        </span>
      </div>

      <span className="field-label">Notes (optional)</span>
      <textarea
        className="field"
        rows={3}
        value={form.note}
        onChange={(e) => setForm((f) => ({ ...f, note: e.target.value }))}
        placeholder="Finger feel, grade attempts, injury notes…"
      />

      <div style={{ marginTop: 14 }}>
        <button className="btn-primary" onClick={onSubmit}>
          Save Session
        </button>
      </div>
    </div>
  );
}

function PhasesView({ currentPhase, setData }) {
  function setPhase(id) {
    setData((d) => ({ ...d, currentPhase: id, phaseStartDate: today() }));
  }

  return (
    <div>
      <div className="section-head">PHASES</div>
      <div className="section-sub">Tap to set your current training phase.</div>

      {PHASES.map((p) => (
        <div
          key={p.id}
          className="phase-card"
          style={{
            background: p.bg,
            border: `1px solid ${currentPhase === p.id ? p.color : p.border}`,
          }}
          onClick={() => setPhase(p.id)}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "flex-start",
            }}
          >
            <div style={{ flex: 1 }}>
              <div
                style={{
                  display: "flex",
                  gap: 8,
                  alignItems: "center",
                  marginBottom: 6,
                }}
              >
                <span
                  style={{
                    fontFamily: "'Syne', sans-serif",
                    fontSize: 18,
                    fontWeight: 800,
                    color: p.color,
                  }}
                >
                  {p.name.toUpperCase()}
                </span>
                {currentPhase === p.id && (
                  <span
                    className="tag"
                    style={{ background: p.color, color: "#0a0c10" }}
                  >
                    Active
                  </span>
                )}
              </div>
              <div style={{ fontSize: 11, color: "#7a8a9a", marginBottom: 10 }}>
                {p.desc}
              </div>
              <div style={{ display: "flex", gap: 5, flexWrap: "wrap" }}>
                {p.tools.map((t) => (
                  <span
                    key={t}
                    className="tag"
                    style={{
                      background: "#0a0c10",
                      color: "#4a5a70",
                      border: "1px solid #1e2d40",
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
            </div>
            <div style={{ textAlign: "right", flexShrink: 0, marginLeft: 12 }}>
              <div
                style={{
                  fontSize: 9,
                  color: "#4a5a70",
                  textTransform: "uppercase",
                  marginBottom: 3,
                }}
              >
                ACWR
              </div>
              <div
                style={{
                  fontSize: 17,
                  color: p.color,
                  fontFamily: "'Syne', sans-serif",
                  fontWeight: 800,
                }}
              >
                {p.acwr}
              </div>
              <div style={{ fontSize: 10, color: "#3a4a60", marginTop: 3 }}>
                {p.weeks}
              </div>
              <div style={{ fontSize: 10, color: "#3a4a60" }}>
                {p.intensity}
              </div>
            </div>
          </div>
        </div>
      ))}

      <div className="card" style={{ marginTop: 6 }}>
        <div
          style={{
            fontSize: 10,
            color: "#4a5a70",
            textTransform: "uppercase",
            letterSpacing: "0.1em",
            marginBottom: 12,
          }}
        >
          ACWR Risk Zones
        </div>
        {[
          { range: "< 0.7", label: "Under-training", color: "#818cf8" },
          {
            range: "0.7–0.8",
            label: "Low — build carefully",
            color: "#60a5fa",
          },
          {
            range: "0.8–1.3",
            label: "Optimal — safe progression",
            color: "#4ade80",
          },
          {
            range: "1.3–1.5",
            label: "Caution — monitor closely",
            color: "#facc15",
          },
          { range: "> 1.5", label: "Danger — injury risk", color: "#f87171" },
        ].map((z) => (
          <div key={z.range} className="zone-row">
            <div className="zone-dot" style={{ background: z.color }} />
            <span style={{ fontSize: 11, color: "#7a8a9a", width: 64 }}>
              {z.range}
            </span>
            <span style={{ fontSize: 11, color: "#4a5a70" }}>{z.label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function HistoryView({ sessions, setData }) {
  const total = sessions.reduce((s, x) => s + x.load, 0);
  return (
    <div>
      <div className="section-head">HISTORY</div>
      <div className="section-sub">
        {sessions.length} sessions · {total.toLocaleString()} AU total
      </div>
      {sessions.length === 0 && (
        <div
          style={{
            textAlign: "center",
            color: "#2a3a50",
            fontSize: 13,
            padding: "60px 0",
          }}
        >
          No sessions yet.
        </div>
      )}
      {sessions.map((s) => (
        <SessionRow key={s.id} s={s} setData={setData} />
      ))}
    </div>
  );
}

function SessionRow({ s, setData }) {
  const ph = PHASES.find((p) => p.id === s.phase);
  return (
    <div className="session-row">
      <div
        className="session-phase-bar"
        style={{ background: ph?.color || "#334155" }}
      />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div
          style={{
            display: "flex",
            gap: 7,
            alignItems: "center",
            marginBottom: 4,
            flexWrap: "wrap",
          }}
        >
          <span style={{ fontSize: 13, color: "#e2e8f0" }}>{s.typeLabel}</span>
          <span
            className="tag"
            style={{
              background: ph?.bg || "#1e2d40",
              color: ph?.color || "#7a8a9a",
              border: `1px solid ${ph?.border || "#1e2d40"}`,
            }}
          >
            {ph?.name || s.phase}
          </span>
        </div>
        <div style={{ fontSize: 11, color: "#4a5a70" }}>
          {s.date} · {s.duration}min · RPE {s.rpe} ·{" "}
          <span style={{ color: "#7a8a9a" }}>{s.load} AU</span>
        </div>
        {s.note && (
          <div style={{ fontSize: 11, color: "#3a4a60", marginTop: 3 }}>
            {s.note}
          </div>
        )}
      </div>
      <button
        className="del-btn"
        onClick={() =>
          setData((d) => ({
            ...d,
            sessions: d.sessions.filter((x) => x.id !== s.id),
          }))
        }
      >
        ×
      </button>
    </div>
  );
}
