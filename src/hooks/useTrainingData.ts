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
import { supabase } from "../lib/supabase";
import { useRealtimeVersion } from "./useRealtimeVersion";

function sortSessions(list: Session[]): Session[] {
  return [...list].sort((a, b) => b.date.localeCompare(a.date));
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
  const generationRef = useRef(0);

  // No synchronous setState before the first `await` here — the mount/
  // realtime-version effect below calls this directly (an effect calling
  // something that sets state synchronously up front causes an avoidable
  // cascading render).
  const runFetch = useCallback(async () => {
    const generation = ++generationRef.current;
    // Retry transient failures (Supabase cold start, a brief network blip)
    // with backoff before surfacing an error — this is why a manual refresh
    // used to "fix" it. Only the final attempt shows the error banner.
    let lastError: unknown;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const [remoteSessions, settings, periods] = await Promise.all([
          repo.fetchSessions(),
          repo.fetchSettings(),
          repo.fetchPhasePeriods(),
        ]);
        if (generation !== generationRef.current) return;
        setSessions(remoteSessions);
        setCurrentPhase(settings.currentPhase);
        setPhaseStartDate(settings.phaseStartDate);
        setPhasePeriods(periods);
        setError(null);
        setLoading(false);
        return;
      } catch (e) {
        lastError = e;
        if (generation !== generationRef.current) return;
        if (attempt < 2) {
          // A stale/expired access token is the usual cause a full page reload
          // "fixes" — force a refresh before retrying so an in-app Retry
          // actually recovers (the client keeps a fresh token going forward).
          await supabase.auth.refreshSession().catch(() => {});
          await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
        }
      }
    }
    if (generation !== generationRef.current) return;
    setError(lastError instanceof Error ? lastError.message : "Failed to load data");
    setLoading(false);
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
    setSessions((list) => sortSessions([...list, temp]));
    try {
      const saved = await repo.insertSession(form);
      setSessions((list) =>
        sortSessions(list.map((s) => (s.id === temp.id ? saved : s))),
      );
      // Returned so callers can offer a same-day follow-up (SL-21's
      // unlinked-recordings nudge after the Log Session sheet saves).
      return saved;
    } catch (e) {
      setSessions((list) => list.filter((s) => s.id !== temp.id));
      setError(e instanceof Error ? e.message : "Failed to save session");
      return undefined;
    }
  }

  async function addTindeqSession(input: {
    durationMin: number;
    rpe: number;
    note: string;
    groupId: string;
  }) {
    try {
      const saved = await repo.insertTindeqSession({
        ...input,
        phase: currentPhase,
      });
      setSessions((list) => sortSessions([...list, saved]));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to log session");
    }
  }

  async function editSession(id: string, patch: SessionPatch) {
    const prev = sessions;
    // Optimistic: apply the patch locally (load = duration × rpe mirrors the
    // DB's generated column), roll back on failure.
    setSessions((list) =>
      list.map((s) =>
        s.id === id
          ? {
              ...s,
              ...patch,
              // Reaching the edit sheet means a human reviewed this RPE —
              // un-mute the bar immediately (issue #114).
              rpeConfirmed: true,
              load: patch.duration * patch.rpe,
            }
          : s,
      ),
    );
    try {
      const saved = await repo.updateSession(id, patch);
      setSessions((list) => list.map((s) => (s.id === id ? saved : s)));
    } catch (e) {
      setSessions(prev);
      setError(e instanceof Error ? e.message : "Failed to update session");
    }
  }

  async function removeSession(id: string) {
    const prev = sessions;
    setSessions((list) => list.filter((s) => s.id !== id));
    try {
      await repo.deleteSession(id);
    } catch (e) {
      setSessions(prev);
      setError(e instanceof Error ? e.message : "Failed to delete session");
    }
  }

  async function setPhase(id: PhaseId) {
    const prev = { currentPhase, phaseStartDate };
    // Optimistic: show the new phase immediately; real start date arrives
    // from switchPhase (it may be earlier than today on a same-day undo).
    setCurrentPhase(id);
    setPhaseStartDate(today());
    try {
      const { periods, settings } = await repo.switchPhase(id);
      setPhasePeriods(periods);
      setCurrentPhase(settings.currentPhase);
      setPhaseStartDate(settings.phaseStartDate);
    } catch (e) {
      setCurrentPhase(prev.currentPhase);
      setPhaseStartDate(prev.phaseStartDate);
      setError(e instanceof Error ? e.message : "Failed to update phase");
    }
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
