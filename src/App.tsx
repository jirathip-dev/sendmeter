import { useEffect, useMemo, useRef, useState } from "react";
import { PHASES } from "./constants";
import { today } from "./lib/dates";
import {
  computeAcwr,
  computeWeeklyLoads,
  getACWRStatus,
  phaseStartFromHistory,
} from "./lib/metrics";
import { useAuth } from "./hooks/useAuth";
import { useTrainingData } from "./hooks/useTrainingData";
import type { LogFormState, Session, ViewId } from "./types";
import Dashboard from "./components/Dashboard";
import EditSessionSheet from "./components/EditSessionSheet";
import HistoryView from "./components/HistoryView";
import LoginScreen from "./components/LoginScreen";
import RecoveryScreen from "./components/RecoveryScreen";
import LogForm from "./components/LogForm";
import PhasesView from "./components/PhasesView";
import ForceView from "./components/ForceView";
import WorkoutView from "./components/WorkoutView";
import BottomNav from "./components/BottomNav";
import PasskeyPrompt from "./components/PasskeyPrompt";
import AccountSheet from "./components/AccountSheet";
import Sheet from "./components/Sheet";
import TrashSheet from "./components/TrashSheet";
import RealtimeVersionProvider from "./components/RealtimeVersionProvider";
import ToastProvider from "./components/ToastProvider";
import { TindeqProvider } from "./hooks/TindeqProvider";
import { useToast } from "./hooks/useToast";

export default function App() {
  const { session, loading, recovery, clearRecovery, signOut } = useAuth();

  // A password-reset email link takes priority — prompt for the new password
  // before anything else, even though a (temporary) session now exists.
  if (recovery) return <RecoveryScreen onDone={clearRecovery} />;

  if (loading) {
    return (
      <div
        className="app-shell"
        style={{ alignItems: "center", justifyContent: "center" }}
      >
        <div className="loading-center">
          <div className="topbar-title" style={{ fontSize: 22 }}>SENDMETER</div>
          <div className="spinner" />
        </div>
      </div>
    );
  }

  if (!session) return <LoginScreen />;

  return (
    <RealtimeVersionProvider userId={session.user.id}>
      <ToastProvider>
        <TindeqProvider>
          <AuthedApp userId={session.user.id} onSignOut={signOut} />
        </TindeqProvider>
      </ToastProvider>
    </RealtimeVersionProvider>
  );
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
    phasePeriods,
    loading,
    error,
    dismissError,
    addSession,
    addTindeqSession,
    editSession,
    removeSession,
    setPhase,
    reload,
  } = useTrainingData(userId);

  const toast = useToast();
  const [view, setView] = useState<ViewId>("dashboard");
  const [showModal, setShowModal] = useState(false);
  const [editingSession, setEditingSession] = useState<Session | null>(null);
  const [showPhases, setShowPhases] = useState(false);
  const [showPhaseChange, setShowPhaseChange] = useState(false);
  const [showWatchSheet, setShowWatchSheet] = useState(false);
  const [showTrash, setShowTrash] = useState(false);
  const [form, setForm] = useState<LogFormState>({
    date: today(),
    type: "fingerboard",
    duration: 45,
    rpe: 6,
    note: "",
    phase: "capacity",
  });

  const acwrData = useMemo(() => computeAcwr(sessions), [sessions]);
  const weeklyLoads = useMemo(() => computeWeeklyLoads(sessions), [sessions]);

  // Auto-hide the topbar + bottom nav on scroll-down, reveal on scroll-up
  // (modern app chrome). Both overlay the content, so hiding frees the screen.
  const contentRef = useRef<HTMLDivElement>(null);
  const [chromeHidden, setChromeHidden] = useState(false);
  const lastScrollY = useRef(0);
  useEffect(() => {
    const el = contentRef.current;
    if (!el) return;
    function onScroll() {
      // Desktop keeps its in-flow nav — auto-hide is a mobile behavior.
      if (window.innerWidth >= 720) return;
      const y = el!.scrollTop;
      const dy = y - lastScrollY.current;
      if (y < 48) setChromeHidden(false);
      else if (dy > 6) setChromeHidden(true);
      else if (dy < -6) setChromeHidden(false);
      lastScrollY.current = y;
    }
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, []);

  const phase = PHASES.find((p) => p.id === currentPhase) || PHASES[0]!;
  const status = getACWRStatus(acwrData.acwr);
  // "Day N" counts from the first session actually logged in the current phase
  // (auto from history), not the raw phase_start_date. The open phase period's
  // start bounds it; phaseStartDate is the fallback for old accounts.
  const periodStart =
    phasePeriods.find((p) => p.endedOn === null)?.startedOn ?? phaseStartDate;
  const phaseStart = phaseStartFromHistory(sessions, periodStart);
  const phaseDays =
    Math.floor(
      (new Date(today()).getTime() - new Date(phaseStart).getTime()) / 86400000,
    ) + 1;

  function submitSession() {
    void addSession(form);
    toast("Session logged");
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
    setShowModal(true);
  }

  return (
    <div className={`app-shell${chromeHidden ? " chrome-hidden" : ""}`}>
      {/* Floating account button — the whole header is just this circle;
          branding and phase info live in the content (phase banner). */}
      <button
        className="account-fab"
        aria-label="Account"
        onClick={() => setShowWatchSheet(true)}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="12" cy="8.2" r="3.4" />
          <path d="M5 20c1.2-3.4 3.8-5 7-5s5.8 1.6 7 5" />
        </svg>
      </button>

      {/* Content */}
      <div className="content-area with-chrome" ref={contentRef}>
        {/* Error banner (scrolls with content; the chrome overlays above it) */}
        {error && (
          <div className="error-banner">
            <span className="msg">{error}</span>
            <button className="error-retry" onClick={() => void reload()}>
              Retry
            </button>
            <button className="error-x" onClick={dismissError} aria-label="Dismiss">
              ×
            </button>
          </div>
        )}
        {loading ? (
          <div className="loading-center" style={{ padding: "72px 0" }}>
            <div className="spinner" />
            <span>Loading your training…</span>
          </div>
        ) : (
          <>
            <PasskeyPrompt />
            {view === "dashboard" && (
              <Dashboard
                phase={phase}
                phaseDays={phaseDays}
                acwrData={acwrData}
                weeklyLoads={weeklyLoads}
                status={status}
                sessions={sessions}
                onOpenPhases={() => setShowPhases(true)}
                onChangePhase={() => setShowPhaseChange(true)}
              />
            )}
            {view === "history" && (
              <HistoryView
                sessions={sessions}
                currentPhase={currentPhase}
                onDelete={(id) => {
                  void removeSession(id);
                  toast("Session moved to Trash");
                }}
                onEdit={setEditingSession}
                onOpenTrash={() => setShowTrash(true)}
              />
            )}
            {view === "workout" && (
              <WorkoutView
                userId={userId}
                currentPhase={currentPhase}
                onLog={openLog}
              />
            )}
            {view === "tindeq" && (
              <ForceView onLogSession={addTindeqSession} />
            )}
          </>
        )}
      </div>

      {/* Bottom nav — collapses to the active tab's icon while scroll-hidden */}
      <BottomNav
        view={view}
        onChange={setView}
        collapsed={chromeHidden}
        onExpand={() => setChromeHidden(false)}
      />

      {/* Log bottom sheet modal */}
      {showModal && (
        <Sheet onClose={() => setShowModal(false)}>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 20,
              fontWeight: 800,
              marginBottom: 2,
            }}
          >
            Log Session
          </div>
          <div style={{ fontSize: 11, color: "var(--ink-muted)", marginBottom: 4 }}>
            Load = Duration × RPE
          </div>
          <LogForm form={form} setForm={setForm} onSubmit={submitSession} />
          <div style={{ marginTop: 10 }}>
            <button className="btn-ghost" onClick={() => setShowModal(false)}>
              Cancel
            </button>
          </div>
        </Sheet>
      )}

      {/* Phases bottom sheet — informational only (no tap-to-set) */}
      {showPhases && (
        <Sheet fullHeight onClose={() => setShowPhases(false)}>
          <PhasesView currentPhase={currentPhase} phasePeriods={phasePeriods} />
          <div style={{ marginTop: 10 }}>
            <button className="btn-ghost" onClick={() => setShowPhases(false)}>
              Close
            </button>
          </div>
        </Sheet>
      )}

      {/* Compact phase switcher — the actual "change phase" control (the sheet
          above is reference only). */}
      {showPhaseChange && (
        <Sheet onClose={() => setShowPhaseChange(false)}>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 20,
              fontWeight: 800,
              marginBottom: 2,
            }}
          >
            Change phase
          </div>
          <div style={{ fontSize: 11, color: "var(--ink-muted)", marginBottom: 12 }}>
            Sets the training block your sessions log under.
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {PHASES.map((p) => {
              const active = p.id === currentPhase;
              return (
                <button
                  key={p.id}
                  onClick={() => {
                    if (!active) {
                      void setPhase(p.id);
                      toast(`Phase set to ${p.name}`);
                    }
                    setShowPhaseChange(false);
                  }}
                  style={{
                    textAlign: "left",
                    padding: "12px 14px",
                    borderRadius: 10,
                    cursor: "pointer",
                    background: active ? p.bg : "var(--surface-1)",
                    border: `1px solid ${active ? p.color : "var(--border)"}`,
                    fontFamily: "inherit",
                  }}
                >
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      justifyContent: "space-between",
                    }}
                  >
                    <span style={{ fontSize: 14, fontWeight: 700, color: p.color }}>
                      {p.name}
                    </span>
                    {active && (
                      <span style={{ fontSize: 9, color: p.color, textTransform: "uppercase", letterSpacing: "0.08em" }}>
                        Current
                      </span>
                    )}
                  </div>
                  <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 2 }}>
                    {p.desc}
                  </div>
                </button>
              );
            })}
          </div>
          <div style={{ marginTop: 12 }}>
            <button className="btn-ghost" onClick={() => setShowPhaseChange(false)}>
              Cancel
            </button>
          </div>
        </Sheet>
      )}

      {/* Account bottom sheet */}
      {showWatchSheet && (
        <AccountSheet
          onClose={() => setShowWatchSheet(false)}
          onSignOut={onSignOut}
        />
      )}

      {/* Edit session bottom sheet */}
      {editingSession && (
        <EditSessionSheet
          session={editingSession}
          onSave={(patch) => void editSession(editingSession.id, patch)}
          onClose={() => setEditingSession(null)}
        />
      )}

      {/* Trash bottom sheet */}
      {showTrash && (
        <TrashSheet
          onClose={() => setShowTrash(false)}
          onSessionRestored={() => void reload()}
        />
      )}

    </div>
  );
}
