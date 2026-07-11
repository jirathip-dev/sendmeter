import { useCallback, useEffect, useState } from "react";
import type { LogFormState, PhaseId, Session } from "../types";
import { today } from "../lib/dates";
import * as repo from "../lib/repo";

function sortSessions(list: Session[]): Session[] {
  return [...list].sort((a, b) => b.date.localeCompare(a.date));
}

export function useTrainingData(userId: string) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [currentPhase, setCurrentPhase] = useState<PhaseId>("capacity");
  const [phaseStartDate, setPhaseStartDate] = useState(today());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [remoteSessions, settings] = await Promise.all([
        repo.fetchSessions(),
        repo.fetchSettings(),
      ]);
      setSessions(remoteSessions);
      setCurrentPhase(settings.currentPhase);
      setPhaseStartDate(settings.phaseStartDate);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load data");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    Promise.all([repo.fetchSessions(), repo.fetchSettings()])
      .then(([remoteSessions, settings]) => {
        if (cancelled) return;
        setSessions(remoteSessions);
        setCurrentPhase(settings.currentPhase);
        setPhaseStartDate(settings.phaseStartDate);
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
  }, [userId]);

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
    const next = { currentPhase: id, phaseStartDate: today() };
    setCurrentPhase(next.currentPhase);
    setPhaseStartDate(next.phaseStartDate);
    try {
      await repo.updateSettings(next);
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
    loading,
    error,
    dismissError: () => setError(null),
    addSession,
    removeSession,
    setPhase,
    reload,
  };
}
