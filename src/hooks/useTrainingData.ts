import { useCallback, useEffect, useState } from "react";
import type { LogFormState, PhaseId, PhasePeriod, Session } from "../types";
import { today } from "../lib/dates";
import * as repo from "../lib/repo";
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

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [remoteSessions, settings, periods] = await Promise.all([
        repo.fetchSessions(),
        repo.fetchSettings(),
        repo.fetchPhasePeriods(),
      ]);
      setSessions(remoteSessions);
      setCurrentPhase(settings.currentPhase);
      setPhaseStartDate(settings.phaseStartDate);
      setPhasePeriods(periods);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load data");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      repo.fetchSessions(),
      repo.fetchSettings(),
      repo.fetchPhasePeriods(),
    ])
      .then(([remoteSessions, settings, periods]) => {
        if (cancelled) return;
        setSessions(remoteSessions);
        setCurrentPhase(settings.currentPhase);
        setPhaseStartDate(settings.phaseStartDate);
        setPhasePeriods(periods);
        setError(null);
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : "Failed to load data");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
    // realtimeVersion bumps on any watch-side write (sessions/tindeq/health) —
    // refetch so the web/iOS app picks it up without a manual reload.
  }, [userId, realtimeVersion]);

  async function addSession(form: LogFormState) {
    const temp: Session = {
      id: `temp-${Math.random().toString(36).slice(2)}`,
      date: form.date,
      type: form.type,
      typeLabel: form.type,
      duration: form.duration,
      rpe: form.rpe,
      load: form.duration * form.rpe,
      note: form.note,
      phase: form.phase,
      groupId: null,
    };
    setSessions((list) => sortSessions([...list, temp]));
    try {
      const saved = await repo.insertSession(form);
      setSessions((list) =>
        sortSessions(list.map((s) => (s.id === temp.id ? saved : s))),
      );
    } catch (e) {
      setSessions((list) => list.filter((s) => s.id !== temp.id));
      setError(e instanceof Error ? e.message : "Failed to save session");
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
    removeSession,
    setPhase,
    reload,
  };
}
