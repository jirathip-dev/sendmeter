import { useEffect, useMemo, useRef, useState } from "react";
import { PHASES } from "./constants";
import { today } from "./lib/dates";
import { computeAcwr, computeWeeklyLoads, getACWRStatus } from "./lib/metrics";
import { useAuth } from "./hooks/useAuth";
import { useTrainingData } from "./hooks/useTrainingData";
import type { LogFormState, ViewId } from "./types";
import Dashboard from "./components/Dashboard";
import HistoryView from "./components/HistoryView";
import LoginScreen from "./components/LoginScreen";
import RecoveryScreen from "./components/RecoveryScreen";
import LogForm from "./components/LogForm";
import PhasesView from "./components/PhasesView";
import TindeqView from "./components/TindeqView";
import BottomNav from "./components/BottomNav";
import PasskeyPrompt from "./components/PasskeyPrompt";
import AccountSheet from "./components/AccountSheet";
import Sheet from "./components/Sheet";
import TrashSheet from "./components/TrashSheet";
import RealtimeVersionProvider from "./components/RealtimeVersionProvider";

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
        <div style={{ fontSize: 11, color: "var(--ink-muted)" }}>loading…</div>
      </div>
    );
  }

  if (!session) return <LoginScreen />;

  return (
    <RealtimeVersionProvider userId={session.user.id}>
      <AuthedApp userId={session.user.id} onSignOut={signOut} />
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
    removeSession,
    setPhase,
    reload,
  } = useTrainingData(userId);

  const [view, setView] = useState<ViewId>("dashboard");
  const [showModal, setShowModal] = useState(false);
  const [showPhases, setShowPhases] = useState(false);
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
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              gap: 8,
              padding: "10px 14px",
              marginBottom: 10,
              background: "rgba(255,69,58,0.12)",
              border: "1px solid rgba(255,69,58,0.35)",
              borderRadius: 10,
              fontSize: 11,
              color: "var(--danger)",
            }}
          >
            <span>{error}</span>
            <button
              onClick={dismissError}
              style={{
                background: "none",
                border: "none",
                color: "var(--danger)",
                fontSize: 16,
                cursor: "pointer",
              }}
            >
              ×
            </button>
          </div>
        )}
        {loading ? (
          <div
            style={{
              textAlign: "center",
              color: "var(--ink-faint)",
              fontSize: 13,
              padding: "60px 0",
            }}
          >
            loading…
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
                onDelete={(id) => void removeSession(id)}
                onLog={openLog}
                onOpenPhases={() => setShowPhases(true)}
              />
            )}
            {view === "history" && (
              <HistoryView
                sessions={sessions}
                onDelete={(id) => void removeSession(id)}
                onOpenTrash={() => setShowTrash(true)}
              />
            )}
            {view === "tindeq" && (
              <TindeqView onLogSession={addTindeqSession} />
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

      {/* Phases bottom sheet */}
      {showPhases && (
        <Sheet fullHeight onClose={() => setShowPhases(false)}>
          <PhasesView
            currentPhase={currentPhase}
            phasePeriods={phasePeriods}
            onSetPhase={(id) => void setPhase(id)}
          />
          <div style={{ marginTop: 10 }}>
            <button className="btn-ghost" onClick={() => setShowPhases(false)}>
              Close
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
