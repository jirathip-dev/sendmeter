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
import {
  dropPendingForAccount,
  mergeFetchedSessions,
  reconcilePendingSession,
  rollbackPendingSession,
  upsertPendingSession,
  type PendingWorkout,
} from "../lib/pendingWorkouts";
import {
  applySessionRealtimeEvents,
  sessionEventsAllApplied,
} from "../lib/sessionRealtimeApply";
import {
  useRealtimeSessionEvents,
  useRealtimeSessionOverflowed,
} from "./useRealtimeVersion";
import { useRealtimeVersion } from "./useRealtimeVersion";

export function sortSessions(list: Session[]): Session[] {
  return [...list].sort((a, b) => b.date.localeCompare(a.date));
}

/** A retry of a client-keyed session can resolve to the row already present
 * in state. Replace by id so exactly-once persistence is also exactly-once in
 * the visible timeline. */
export function upsertSessionById(list: Session[], saved: Session): Session[] {
  const found = list.some((session) => session.id === saved.id);
  return sortSessions(found
    ? list.map((session) => session.id === saved.id ? saved : session)
    : [...list, saved]);
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

/// `editSession`'s rollback step: restore only the edited row, against
/// whatever `list` CURRENTLY is — not a whole-list snapshot taken before the
/// optimistic apply ran. #485 F4: a plain `setSessions(prevSnapshot)` also
/// reverts any OTHER mutation that landed in the async window between the
/// snapshot and this rollback (a concurrent add/edit/delete succeeding, or a
/// realtime refetch) — a decision made from state captured earlier than the
/// decision, this repo's named defect class (CLAUDE.md #295/#296). A missing
/// `original` (the row left `list` some other way in the meantime) is a
/// no-op: there is nothing to restore it FROM.
export function rollbackEditSession(
  list: Session[],
  id: string,
  original: Session | undefined,
): Session[] {
  if (!original) return list;
  return list.map((s) => (s.id === id ? original : s));
}

/// `removeSession`'s rollback step: reinsert only the removed row, against
/// whatever `list` CURRENTLY is. Same #485 F4 reasoning as
/// `rollbackEditSession`. Guarded against a double-insert on the unlikely
/// chance `id` is already back in `list` by the time this runs.
export function rollbackRemoveSession(
  list: Session[],
  removed: Session | undefined,
): Session[] {
  if (!removed || list.some((s) => s.id === removed.id)) return list;
  return sortSessions([...list, removed]);
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
  const sessionEvents = useRealtimeSessionEvents();
  const sessionEventsOverflowed = useRealtimeSessionOverflowed();
  // Guards against a stale in-flight reload clobbering a newer one's state
  // (e.g. realtimeVersion bumping again before the first fetch resolves).
  // A ref holding a single stable guard instance for this hook's lifetime —
  // createGenerationGuard's own state (not the ref) is what actually tracks
  // the generation counter (#220).
  const guardRef = useRef(createGenerationGuard());
  // #615: the account the current render belongs to. Pending (optimistic)
  // workout rows are stamped with the account that registered them; the
  // fetch merge and the watch-completion listener both filter on this so an
  // account switch never carries the old account's pending row into the new
  // account's view. A ref (not the closed-over `userId`): `runFetch` is a
  // `[]`-deps callback, and the merge must read the CURRENT account even
  // after a switch, not the one captured at mount.
  const userIdRef = useRef(userId);
  // Mirror of `sessions` for the refetch-guard decision (the guard effect
  // must not depend on `sessions` itself or it re-runs every render).
  const sessionsRef = useRef<Session[]>([]);
  // #615: cursor into the bounded session-events queue (see the apply effect
  // below) — same pattern as ForceView's recording-events cursor (#613).
  const appliedSessionEventsRef = useRef(0);
  // #615 F5: a SEPARATE generation guard for the drain-triggered by-id
  // reconcile — it must not share runFetch's guard, or the narrower
  // reconcile starting mid-refetch would invalidate the full fetch (its
  // whole-list + settings result discarded) under the shared guard's rule.
  const pendingReconcileGuardRef = useRef(createGenerationGuard());
  // Only the first current load for this hook instance is "initial". A later
  // realtime refetch failure is user-visible but not the launch failure #382
  // asks us to monitor; the monitoring entry point also dedupes across hook
  // remounts for the full app-launch lifecycle.
  const initialLoadPendingRef = useRef(true);

  useEffect(() => {
    userIdRef.current = userId;
    // #615 F4: an account switch must not carry the old account's pending
    // (optimistic) workout rows into the new account's view — without this
    // they survive until the refetch's merge drops them (and indefinitely if
    // that refetch fails), rendering the old account's data under the new
    // account. Written via an async callback per the set-state-in-effect
    // rule; the functional update applies to whatever list is current.
    void (async () => {
      setSessions((list) => dropPendingForAccount(list, userId));
    })();
  }, [userId]);

  useEffect(() => {
    sessionsRef.current = sessions;
  }, [sessions]);

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
        // #615: merge — not replace. Pending (optimistic) workout rows that
        // haven't reached the server yet survive the refetch; rows the
        // server now has replace their pending placeholder by id, so
        // realtime echo and optimistic reconcile converge exactly once.
        setSessions((list) =>
          mergeFetchedSessions(list, data.sessions, userIdRef.current),
        );
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
    // #615: skip the coarse refetch when THIS bump was a sessions write the
    // payload apply path already handled (mirrors ForceView's #613 guard).
    // The events queue only ever holds session writes; a bump from any other
    // table (or an un-applied/overflowed session event) still refetches.
    const allApplied = sessionEventsAllApplied(
      sessionEvents,
      sessionsRef.current,
    );
    if (sessionEvents.length > 0 && allApplied && !sessionEventsOverflowed) {
      return;
    }
    void runFetch();
    // realtimeVersion bumps on any watch-side write (sessions/tindeq/health) —
    // refetch so the web/iOS app picks it up without a manual reload.
  }, [userId, realtimeVersion, sessionEvents, sessionEventsOverflowed, runFetch]);

  // #615: apply `sessions` realtime INSERT payloads directly, by id — the
  // pending placeholder for a just-uploaded workout reconciles the instant
  // its server row lands, without waiting on the refetch. Idempotent, so the
  // bounded queue is re-walked (only the fresh tail is re-applied).
  useEffect(() => {
    if (sessionEvents.length === 0) return;
    if (appliedSessionEventsRef.current > sessionEvents.length) {
      // The bounded queue was trimmed (overflow) — re-walk what's left.
      appliedSessionEventsRef.current = 0;
    }
    const fresh = sessionEvents.slice(appliedSessionEventsRef.current);
    if (fresh.length === 0) return;
    setSessions((list) => applySessionRealtimeEvents(list, fresh));
    appliedSessionEventsRef.current = sessionEvents.length;
  }, [sessionEvents]);

  // #615: optimistic completed-workout plumbing. The registering caller
  // (WorkoutView's auto-save, or the watch-completion listener) builds the
  // PendingWorkout with the account stamp; these three functions apply it,
  // reconcile it by stable id, and roll it back — pure by-id operations, so
  // overlapping realtime echo / notification replay / retries converge.
  // useCallback'd (stable identity) so a listener hook can subscribe once.

  /// Show a completed workout immediately (pending marker). Idempotent by id.
  const addPendingSession = useCallback((pending: PendingWorkout) => {
    setSessions((list) => upsertPendingSession(list, pending));
  }, []);

  /// The server row for a pending id landed (RPC return, realtime payload,
  /// or refetch) — replace by id, dropping the pending marker.
  const reconcilePendingWorkout = useCallback((saved: Session) => {
    setSessions((list) => reconcilePendingSession(list, saved));
  }, []);

  /// The save failed and nothing durable exists — remove the pending row.
  const rollbackPendingWorkout = useCallback((id: string) => {
    setSessions((list) => rollbackPendingSession(list, id));
  }, []);

  /// #615 F5: a watch completion drained after the WebView was suspended had
  /// its realtime INSERT missed — the pending row registers but nothing
  /// would ever reconcile it (the refetch guard only runs on a version
  /// bump). Fetch the drained ids from the server and reconcile what exists:
  /// a pending placeholder is replaced by its canonical row, a row already
  /// canonical re-fetched is unchanged. Fenced by its own generation guard
  /// (see `pendingReconcileGuardRef`), and the account is re-checked at
  /// resolve time — same #615 F4 rule as the phone save: a switch mid-flight
  /// must not land the old account's rows in the new account's list.
  const reconcilePendingByIds = useCallback(async (ids: string[]) => {
    if (ids.length === 0) return;
    const generation = pendingReconcileGuardRef.current.start();
    const accountAtStart = userIdRef.current;
    try {
      const found = await repo.fetchSessionsByIds(ids);
      if (!pendingReconcileGuardRef.current.isCurrent(generation)) return;
      if (userIdRef.current !== accountAtStart) return;
      if (found.length === 0) return;
      setSessions((list) => {
        let next = list;
        for (const s of found) next = reconcilePendingSession(next, s);
        return next;
      });
    } catch {
      // Best-effort: the pending row stays; a later realtime event, refetch
      // or foreground drain retries the reconcile.
    }
  }, []);

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
    id?: string;
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
    /// False when the RPE is the #280 W'-depletion prediction (or its
    /// fallback) that the user left as-is — an unreviewed number, #114's
    /// column. True once they moved the stepper themselves.
    rpeConfirmed?: boolean;
    typeLabel?: string;
  }): Promise<boolean> {
    return addTindeqSessionAction({
      action: () => repo.insertTindeqSession({ ...input, phase: currentPhase }),
      onSuccess: (saved) => setSessions((list) => upsertSessionById(list, saved)),
      onError: (message) => setError(message),
      onFailure: (failure) =>
        captureHandledOperationalFailure("session.insert", failure, {
          automatic: true,
        }),
    });
  }

  async function editSession(id: string, patch: SessionPatch) {
    // #485 F4: captured once, up front, same as before — but only the ONE
    // row rollback needs, not the whole list. See `rollbackEditSession`.
    const original = sessions.find((s) => s.id === id);
    // Optimistic: apply the patch locally (load = duration × rpe mirrors the
    // DB's generated column), roll back on failure.
    await withOptimisticUpdate({
      apply: () =>
        setSessions((list) => applyEditSessionOptimistic(list, id, patch)),
      action: () => repo.updateSession(id, patch),
      onSuccess: (saved) =>
        setSessions((list) => list.map((s) => (s.id === id ? saved : s))),
      rollback: () => setSessions((list) => rollbackEditSession(list, id, original)),
      onError: (message) => setError(message),
      fallbackMessage: "Failed to update session",
      onFailure: (failure) =>
        captureHandledOperationalFailure("session.update", failure, {
          automatic: false,
        }),
    });
  }

  async function removeSession(id: string) {
    // #485 F4: captured once, up front — just the removed row, not the
    // whole list. See `rollbackRemoveSession`.
    const removed = sessions.find((s) => s.id === id);
    // #615: a pending row has no server row to soft-delete — removing it is
    // a local drop (the save RPC's stable-id replay is the retry path; a
    // user delete while pending is a deliberate discard, and the persisted
    // confirming state is what would re-create it, not this call).
    if (removed?.pending) {
      setSessions((list) => rollbackPendingSession(list, id));
      return;
    }
    await withOptimisticUpdate({
      apply: () => setSessions((list) => applyRemoveSessionOptimistic(list, id)),
      action: () => repo.deleteSession(id),
      onSuccess: () => {},
      rollback: () => setSessions((list) => rollbackRemoveSession(list, removed)),
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
    // #615: optimistic completed-workout plumbing (see their docs above).
    addPendingSession,
    reconcilePendingWorkout,
    rollbackPendingWorkout,
    reconcilePendingByIds,
  };
}
