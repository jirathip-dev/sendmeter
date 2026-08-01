import { useCallback, useEffect, useRef, useState } from "react";
import type {
  LogFormState,
  PhaseId,
  PhasePeriod,
  Session,
  SessionPatch,
} from "../types";
import { today } from "../lib/dates";
import * as repo from "../lib/repo";
import type { UserSettings } from "../lib/repo/settings";
import { supabase } from "../lib/supabase";
import { captureHandledOperationalFailure } from "../lib/monitoring";
import { useRealtimeVersion } from "./useRealtimeVersion";

export function sortSessions(list: Session[]): Session[] {
  return [...list].sort((a, b) => b.date.localeCompare(a.date));
}

/// Replaces a raw incrementing ref with an object exposing `start`/
/// `isCurrent` — pulled out so the stale-reload guard used by `runFetch` is
/// independently unit-testable (#220).
export function createGenerationGuard() {
  let generation = 0;
  return {
    start(): number {
      generation += 1;
      return generation;
    },
    isCurrent(candidate: number): boolean {
      return candidate === generation;
    },
  };
}

export interface RunFetchDeps {
  fetchAll: () => Promise<[Session[], UserSettings, PhasePeriod[]]>;
  refreshSession: () => Promise<unknown>;
  delay: (ms: number) => Promise<void>;
  guard: { isCurrent(generation: number): boolean };
  generation: number;
  onSuccess: (data: {
    sessions: Session[];
    currentPhase: PhaseId;
    phaseStartDate: string;
    phasePeriods: PhasePeriod[];
  }) => void;
  onError: (message: string) => void;
  onExhausted?: (error: unknown, attempts: number) => void;
}

/// Pure orchestrator for `runFetch`'s retry loop + stale-generation guard —
/// a direct lift of the original inline logic, generalized over injected
/// fakes so the retry/backoff/guard sequencing is testable without a real
/// Supabase client or timers (#220).
export async function runFetchAttempts(deps: RunFetchDeps): Promise<void> {
  const {
    fetchAll,
    refreshSession,
    delay,
    guard,
    generation,
    onSuccess,
    onError,
    onExhausted,
  } = deps;
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const [remoteSessions, settings, periods] = await fetchAll();
      if (!guard.isCurrent(generation)) return;
      onSuccess({
        sessions: remoteSessions,
        currentPhase: settings.currentPhase,
        phaseStartDate: settings.phaseStartDate,
        phasePeriods: periods,
      });
      return;
    } catch (e) {
      lastError = e;
      if (!guard.isCurrent(generation)) return;
      if (attempt < 2) {
        // A stale/expired access token is the usual cause a full page reload
        // "fixes" — force a refresh before retrying so an in-app Retry
        // actually recovers (the client keeps a fresh token going forward).
        await refreshSession().catch(() => {});
        await delay(400 * (attempt + 1));
      }
    }
  }
  if (!guard.isCurrent(generation)) return;
  onExhausted?.(lastError, 3);
  onError(lastError instanceof Error ? lastError.message : "Failed to load data");
}

/// Generic optimistic-apply/rollback control flow shared by addSession/
/// editSession/removeSession/setPhase — pulled out so each mutation's
/// success/failure sequencing is independently testable (#220).
export async function withOptimisticUpdate<T>(opts: {
  apply: () => void;
  action: () => Promise<T>;
  onSuccess: (result: T) => void;
  rollback: () => void;
  onError: (message: string) => void;
  fallbackMessage: string;
  onFailure?: (error: unknown) => void;
}): Promise<T | undefined> {
  opts.apply();
  try {
    const result = await opts.action();
    opts.onSuccess(result);
    return result;
  } catch (e) {
    opts.rollback();
    opts.onFailure?.(e);
    opts.onError(e instanceof Error ? e.message : opts.fallbackMessage);
    return undefined;
  }
}

/// `addTindeqSession`'s core action: insert then report success/failure —
/// pulled out so the boolean return contract the #295 auto-save failure
/// toast branches on is independently testable, mirroring
/// `withOptimisticUpdate`'s extraction above.
export async function addTindeqSessionAction(opts: {
  action: () => Promise<Session>;
  onSuccess: (saved: Session) => void;
  onError: (message: string) => void;
  onFailure?: (error: unknown) => void;
}): Promise<boolean> {
  try {
    const saved = await opts.action();
    opts.onSuccess(saved);
    return true;
  } catch (e) {
    opts.onFailure?.(e);
    opts.onError(e instanceof Error ? e.message : "Failed to log session");
    return false;
  }
}

/// `addSession`'s optimistic-apply step: append the temp row and re-sort.
export function applyAddSessionOptimistic(
  list: Session[],
  temp: Session,
): Session[] {
  return sortSessions([...list, temp]);
}

/// `addSession`'s success step: swap the temp row for the saved one by id.
export function reconcileAddSession(
  list: Session[],
  tempId: string,
  saved: Session,
): Session[] {
  return sortSessions(list.map((s) => (s.id === tempId ? saved : s)));
}

/// `addSession`'s rollback step: drop the temp row by id.
export function rollbackAddSession(list: Session[], tempId: string): Session[] {
  return list.filter((s) => s.id !== tempId);
}

/// `removeSession`'s optimistic-apply step: drop the row by id.
export function applyRemoveSessionOptimistic(
  list: Session[],
  id: string,
): Session[] {
  return list.filter((s) => s.id !== id);
}

export interface PhaseSnapshot {
  currentPhase: PhaseId;
  phaseStartDate: string;
}

/// `setPhase`'s optimistic-apply step: switch to the new phase immediately,
/// dating the start from today — the real start date (which may be earlier
/// than today on a same-day undo) arrives from switchPhase's onSuccess.
export function applySetPhaseOptimistic(
  id: PhaseId,
  todayDate: string,
): PhaseSnapshot {
  return { currentPhase: id, phaseStartDate: todayDate };
}

/// `setPhase`'s rollback step: restore the pre-mutation snapshot, picked
/// field-by-field (rather than returned verbatim) so a field swap/typo here
/// is caught the same way rollbackAddSession's filter would be.
export function rollbackSetPhase(prev: PhaseSnapshot): PhaseSnapshot {
  return { currentPhase: prev.currentPhase, phaseStartDate: prev.phaseStartDate };
}

/// `editSession`'s optimistic-apply step: merge the patch, force
/// `rpeConfirmed` true (reaching the edit sheet means a human reviewed this
/// RPE — issue #114), and recompute `load` to mirror the DB's generated
/// column.
export function applyEditSessionOptimistic(
  list: Session[],
  id: string,
  patch: SessionPatch,
): Session[] {
  return list.map((s) =>
    s.id === id
      ? {
          ...s,
          ...patch,
          rpeConfirmed: true,
          load: patch.duration * patch.rpe,
        }
      : s,
  );
}

export function useTrainingData(userId: string) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [currentPhase, setCurrentPhase] = useState<PhaseId>("capacity");
  const [phaseStartDate, setPhaseStartDate] = useState(today());
  const [phasePeriods, setPhasePeriods] = useState<PhasePeriod[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const realtimeVersion = useRealtimeVersion();
  // Guards against a stale in-flight reload clobbering a newer one's state
  // (e.g. realtimeVersion bumping again before the first fetch resolves).
  // A ref holding a single stable guard instance for this hook's lifetime —
  // createGenerationGuard's own state (not the ref) is what actually tracks
  // the generation counter (#220).
  const guardRef = useRef(createGenerationGuard());
  // Only the first current load for this hook instance is "initial". A later
  // realtime refetch failure is user-visible but not the launch failure #382
  // asks us to monitor; the monitoring entry point also dedupes across hook
  // remounts for the full app-launch lifecycle.
  const initialLoadPendingRef = useRef(true);

  // No synchronous setState before the first `await` here — the mount/
  // realtime-version effect below calls this directly (an effect calling
  // something that sets state synchronously up front causes an avoidable
  // cascading render).
  const runFetch = useCallback(async () => {
    const generation = guardRef.current.start();
    await runFetchAttempts({
      fetchAll: () =>
        Promise.all([
          repo.fetchSessions(),
          repo.fetchSettings(),
          repo.fetchPhasePeriods(),
        ]),
      refreshSession: () => supabase.auth.refreshSession(),
      delay: (ms) => new Promise((r) => setTimeout(r, ms)),
      guard: guardRef.current,
      generation,
      onSuccess: (data) => {
        initialLoadPendingRef.current = false;
        setSessions(data.sessions);
        setCurrentPhase(data.currentPhase);
        setPhaseStartDate(data.phaseStartDate);
        setPhasePeriods(data.phasePeriods);
        setError(null);
        setLoading(false);
      },
      onError: (message) => {
        setError(message);
        setLoading(false);
      },
      onExhausted: (failure, attempts) => {
        if (!initialLoadPendingRef.current) return;
        initialLoadPendingRef.current = false;
        captureHandledOperationalFailure("training-data.load", failure, {
          retryAttempts: attempts,
        });
      },
    });
  }, []);

  // Public reload, for explicit user-triggered refreshes (e.g. after a
  // legacy-data import or restoring from Trash) — shows the loading state
  // immediately rather than waiting on initial state alone.
  const reload = useCallback(async () => {
    setLoading(true);
    await runFetch();
  }, [runFetch]);

  useEffect(() => {
    void (async () => {
      await runFetch();
    })();
    // realtimeVersion bumps on any watch-side write (sessions/tindeq/health) —
    // refetch so the web/iOS app picks it up without a manual reload.
  }, [userId, realtimeVersion, runFetch]);

  async function addSession(form: LogFormState): Promise<Session | undefined> {
    const temp: Session = {
      id: `temp-${Math.random().toString(36).slice(2)}`,
      date: form.date,
      type: form.type,
      typeLabel: form.type,
      duration: form.duration,
      rpe: form.rpe,
      // Manually-entered — always confirmed, never the phone auto-save
      // placeholder (issue #114).
      rpeConfirmed: true,
      load: form.duration * form.rpe,
      note: form.note,
      phase: form.phase,
      groupId: null,
      workoutSource: null,
    };
    // Returned so callers can offer a same-day follow-up (SL-21's
    // unlinked-recordings nudge after the Log Session sheet saves).
    return withOptimisticUpdate({
      apply: () => setSessions((list) => applyAddSessionOptimistic(list, temp)),
      action: () => repo.insertSession(form),
      onSuccess: (saved) =>
        setSessions((list) => reconcileAddSession(list, temp.id, saved)),
      rollback: () => setSessions((list) => rollbackAddSession(list, temp.id)),
      onError: (message) => setError(message),
      fallbackMessage: "Failed to save session",
      onFailure: (failure) =>
        captureHandledOperationalFailure("session.insert", failure, {
          automatic: false,
        }),
    });
  }

  async function addTindeqSession(input: {
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
    /// False when the RPE is the #280 W'-depletion prediction (or its
    /// fallback) that the user left as-is — an unreviewed number, #114's
    /// column. True once they moved the stepper themselves.
    rpeConfirmed?: boolean;
  }): Promise<boolean> {
    return addTindeqSessionAction({
      action: () => repo.insertTindeqSession({ ...input, phase: currentPhase }),
      onSuccess: (saved) => setSessions((list) => sortSessions([...list, saved])),
      onError: (message) => setError(message),
      onFailure: (failure) =>
        captureHandledOperationalFailure("session.insert", failure, {
          automatic: true,
        }),
    });
  }

  async function editSession(id: string, patch: SessionPatch) {
    const prev = sessions;
    // Optimistic: apply the patch locally (load = duration × rpe mirrors the
    // DB's generated column), roll back on failure.
    await withOptimisticUpdate({
      apply: () =>
        setSessions((list) => applyEditSessionOptimistic(list, id, patch)),
      action: () => repo.updateSession(id, patch),
      onSuccess: (saved) =>
        setSessions((list) => list.map((s) => (s.id === id ? saved : s))),
      rollback: () => setSessions(prev),
      onError: (message) => setError(message),
      fallbackMessage: "Failed to update session",
      onFailure: (failure) =>
        captureHandledOperationalFailure("session.update", failure, {
          automatic: false,
        }),
    });
  }

  async function removeSession(id: string) {
    const prev = sessions;
    await withOptimisticUpdate({
      apply: () => setSessions((list) => applyRemoveSessionOptimistic(list, id)),
      action: () => repo.deleteSession(id),
      onSuccess: () => {},
      rollback: () => setSessions(prev),
      onError: (message) => setError(message),
      fallbackMessage: "Failed to delete session",
      onFailure: (failure) =>
        captureHandledOperationalFailure("session.delete", failure, {
          automatic: false,
        }),
    });
  }

  async function setPhase(id: PhaseId) {
    const prev: PhaseSnapshot = { currentPhase, phaseStartDate };
    // Optimistic: show the new phase immediately; real start date arrives
    // from switchPhase (it may be earlier than today on a same-day undo).
    await withOptimisticUpdate({
      apply: () => {
        const next = applySetPhaseOptimistic(id, today());
        setCurrentPhase(next.currentPhase);
        setPhaseStartDate(next.phaseStartDate);
      },
      action: () => repo.switchPhase(id),
      onSuccess: ({ periods, settings }) => {
        setPhasePeriods(periods);
        setCurrentPhase(settings.currentPhase);
        setPhaseStartDate(settings.phaseStartDate);
      },
      rollback: () => {
        const restored = rollbackSetPhase(prev);
        setCurrentPhase(restored.currentPhase);
        setPhaseStartDate(restored.phaseStartDate);
      },
      onError: (message) => setError(message),
      fallbackMessage: "Failed to update phase",
    });
  }

  return {
    sessions,
    currentPhase,
    phaseStartDate,
    phasePeriods,
    loading,
    error,
    dismissError: () => setError(null),
    addSession,
    addTindeqSession,
    editSession,
    removeSession,
    setPhase,
    reload,
  };
}
