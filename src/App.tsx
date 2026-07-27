import { useEffect, useMemo, useRef, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { App as CapacitorApp } from "@capacitor/app";
import { PHASES } from "./constants";
import { today } from "./lib/dates";
import {
  computeAcwr,
  computeWeeklyLoads,
  currentPeriodStart,
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
import ConfirmDialog from "./components/ConfirmDialog";
import Sheet from "./components/Sheet";
import TrashSheet from "./components/TrashSheet";
import UnlinkedSessionNudge from "./components/UnlinkedSessionNudge";
import RealtimeVersionProvider from "./components/RealtimeVersionProvider";
import ToastProvider from "./components/ToastProvider";
import { TindeqProvider } from "./hooks/TindeqProvider";
import { useToast } from "./hooks/useToast";
import { useRealtimeBump } from "./hooks/useRealtimeVersion";
import type { HealthSyncSource } from "./lib/healthSync";
import { insertRecording, restoreSession } from "./lib/repo";
import { drainPendingRecordingsQueue } from "./lib/recordingQueue";
import { takeLostRecordingsNotice } from "./lib/lostRecordings";

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
  const bumpRealtime = useRealtimeBump();
  const [view, setView] = useState<ViewId>("dashboard");
  const [showModal, setShowModal] = useState(false);
  const [editingSession, setEditingSession] = useState<Session | null>(null);
  const [showPhases, setShowPhases] = useState(false);
  const [showPhaseChange, setShowPhaseChange] = useState(false);
  const [showAccountSheet, setShowAccountSheet] = useState(false);
  const [showTrash, setShowTrash] = useState(false);
  // Issue #143: session delete is gated behind a confirm dialog instead of
  // firing instantly. Non-null while the dialog for that session id is open.
  const [confirmDeleteSessionId, setConfirmDeleteSessionId] = useState<
    string | null
  >(null);
  const [deletingSession, setDeletingSession] = useState(false);
  // The just-logged session, while it may still have same-day unlinked
  // Tindeq recordings to nudge-link (SL-21). Cleared on dismiss/link, or by
  // logging another session.
  const [nudgeSession, setNudgeSession] = useState<Session | null>(null);
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

  // #106: recover any tindeq recordings that failed to save (dead auth
  // session, dropped connection) while we were signed out — AuthedApp only
  // renders once `session` exists, so a fresh mount here IS "auth just
  // succeeded" (login or a session restore). drainPendingRecordingsQueue
  // guards its own re-entrancy, so a duplicate mount can't double-insert.
  // #269: this is also where the two stores reconcile — the drain first moves
  // anything in the synchronous localStorage lane (a salvage-on-unmount, or a
  // pre-#269 queue left behind by an older build) into the IndexedDB main
  // queue, then attempts the lot. That migration is idempotent, so a run
  // interrupted halfway re-copies rather than duplicating.
  // No manual list refresh needed on success — `tindeq_recordings` is a
  // WATCHED_TABLES table, so each recovered insert bumps the realtime
  // version and ForceView's own fetch effect picks it up.
  useEffect(() => {
    let cancelled = false;
    void drainPendingRecordingsQueue(userId, insertRecording).then((n) => {
      if (!cancelled && n > 0) {
        toast(`Recovered ${n} unsaved recording${n === 1 ? "" : "s"}`);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [userId, toast]);

  // #264: the other side of the queue — recordings that could not even be
  // queued. The path that loses one (useTindeq's salvage-on-unmount cleanup)
  // has no UI it can reach, so it parks a durable one-shot notice instead;
  // this is where the user finally hears about it. Mount covers sign-in and a
  // cold launch, appStateChange covers a loss that happened while the app was
  // backgrounded. `take` clears the record, so it shows exactly once.
  useEffect(() => {
    function surface() {
      const notice = takeLostRecordingsNotice();
      if (!notice) return;
      toast(
        `${notice.count} recording${notice.count === 1 ? "" : "s"} couldn't be saved — device storage was full`,
        "error",
      );
    }
    // Deferred, not called inline: a toast is a setState, and this effect must
    // not write state synchronously in its body (react-compiler lint).
    const t = setTimeout(surface, 0);
    if (!Capacitor.isNativePlatform()) return () => clearTimeout(t);
    const sub = CapacitorApp.addListener("appStateChange", ({ isActive }) => {
      if (isActive) surface();
    });
    return () => {
      clearTimeout(t);
      void sub.then((h) => h.remove());
    };
  }, [toast]);

  // SL-31 sync toast: only for a foreground resync the user is actively
  // looking at. The cold-launch background sync fires on every app open
  // (would be noisy) and the "Clear & resync" path already toasts itself.
  // #146: source alone isn't enough — the native plugin always re-upserts
  // on every foreground call regardless of whether anything actually
  // changed, so also require `changed` or the toast fires on every
  // foreground even with no new data.
  // #223: bump realtime on any source that actually landed new data — the
  // Supabase Realtime echo that normally bumps this isn't reliably delivered
  // on a cold launch, so readiness/recovery cards (keyed on `realtimeVersion`)
  // can stay stale until the app is restarted. Same defensive bump already
  // used after "Clear & resync" in AccountSheet.tsx.
  //
  // Gated on `changed`, NOT on source, and not unconditional: this event
  // fires on every foreground including the cold-launch background sync, and
  // a bump forces every realtime-keyed consumer to refetch (~10 components).
  // Bumping unconditionally would trade a stale card for a full refetch on
  // every app open. `changed` is the right gate — per healthSync.ts it
  // reflects whether today's health_metrics row content actually differed,
  // and it's carried for every source (unlike the toast's source check).
  useEffect(() => {
    const onHealthSynced = (e: Event) => {
      const detail = (e as CustomEvent<{ source?: HealthSyncSource; changed?: boolean }>)
        .detail;
      if (detail?.changed) bumpRealtime();
      if (detail?.source === "foreground" && detail.changed) {
        toast("Health data synced");
      }
    };
    window.addEventListener("sendmeter:health-synced", onHealthSynced);
    return () =>
      window.removeEventListener("sendmeter:health-synced", onHealthSynced);
  }, [toast, bumpRealtime]);

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
  // "Day N" counts from the current phase's streak of logged sessions (auto
  // from history), so toggling to another phase and back doesn't reset it. The
  // open period's start (or phaseStartDate) is only the fallback when nothing's
  // been logged in the phase yet.
  const periodStart = currentPeriodStart(phasePeriods, currentPhase, phaseStartDate);
  const phaseStart = phaseStartFromHistory(sessions, currentPhase, periodStart);
  const phaseDays =
    Math.floor(
      (new Date(today()).getTime() - new Date(phaseStart).getTime()) / 86400000,
    ) + 1;
  // Today's date for the phase strip (parse as LOCAL midnight so the label is
  // right regardless of UTC offset).
  const todayLabel = new Date(today() + "T00:00:00").toLocaleDateString(
    undefined,
    { weekday: "short", month: "short", day: "numeric" },
  );

  function submitSession() {
    void (async () => {
      const saved = await addSession(form);
      toast("Session logged");
      if (saved) setNudgeSession(saved);
    })();
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

  // Issue #143: confirmed session delete — soft-delete then toast an Undo
  // that restores it and reloads so the list reflects the restore.
  async function confirmDeleteSession() {
    const id = confirmDeleteSessionId;
    if (!id) return;
    setDeletingSession(true);
    await removeSession(id);
    setDeletingSession(false);
    setConfirmDeleteSessionId(null);
    toast("Session moved to Trash", "success", {
      label: "Undo",
      onClick: () => {
        void (async () => {
          await restoreSession(id);
          await reload();
        })();
      },
    });
  }

  return (
    <div className={`app-shell${chromeHidden ? " chrome-hidden" : ""}`}>
      {/* Floating account button — the whole header is just this circle;
          branding and phase info live in the content (phase banner). */}
      <button
        className="account-fab"
        aria-label="Account"
        onClick={() => setShowAccountSheet(true)}
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
        {/* SL-21 nudge: appears right after the Log Session sheet saves, if
            same-day Tindeq recordings are still ungrouped. */}
        {nudgeSession && (
          <UnlinkedSessionNudge
            session={nudgeSession}
            onDismiss={() => setNudgeSession(null)}
          />
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
                todayLabel={todayLabel}
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
                userId={userId}
                sessions={sessions}
                currentPhase={currentPhase}
                onDelete={(id) => setConfirmDeleteSessionId(id)}
                onEdit={setEditingSession}
                onOpenTrash={() => setShowTrash(true)}
              />
            )}
            {view === "workout" && (
              <WorkoutView
                userId={userId}
                currentPhase={currentPhase}
                sessions={sessions}
                onLog={openLog}
              />
            )}
            {view === "tindeq" && (
              <ForceView userId={userId} onLogSession={addTindeqSession} />
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
              fontSize: "var(--t-xl)",
              fontWeight: 800,
              marginBottom: 2,
            }}
          >
            Log Session
          </div>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 4 }}>
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
          <PhasesView
            currentPhase={currentPhase}
            phasePeriods={phasePeriods}
            phaseStartDate={phaseStartDate}
          />
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
              fontSize: "var(--t-xl)",
              fontWeight: 800,
              marginBottom: 2,
            }}
          >
            Change phase
          </div>
          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 12 }}>
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
                    <span style={{ fontSize: "var(--t-base)", fontWeight: 700, color: p.color }}>
                      {p.name}
                    </span>
                    {active && (
                      <span style={{ fontSize: "var(--t-eyebrow)", color: p.color, textTransform: "uppercase", letterSpacing: "0.08em" }}>
                        Current
                      </span>
                    )}
                  </div>
                  <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 2 }}>
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
      {showAccountSheet && (
        <AccountSheet
          onClose={() => setShowAccountSheet(false)}
          onSignOut={onSignOut}
        />
      )}

      {/* Edit session bottom sheet */}
      {editingSession && (
        <EditSessionSheet
          session={editingSession}
          onSave={(patch) => {
            void editSession(editingSession.id, patch);
            toast("Session updated");
          }}
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

      {/* Delete-session confirm (issue #143) */}
      {confirmDeleteSessionId && (
        <ConfirmDialog
          title="Delete session?"
          body="It moves to Trash — you can restore it there."
          confirmLabel="Delete"
          busy={deletingSession}
          onConfirm={() => void confirmDeleteSession()}
          onClose={() => setConfirmDeleteSessionId(null)}
        />
      )}

    </div>
  );
}
