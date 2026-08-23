import { supabase } from "../supabase";
import type { PhaseId, PhasePeriod } from "../../types";
import { today } from "../dates";
import { unwrap } from "./shared";
import { updateSettings, type UserSettings } from "./settings";

function toPhasePeriod(r: {
  id: string;
  phase: string;
  started_on: string;
  ended_on: string | null;
}): PhasePeriod {
  return {
    id: r.id,
    phase: r.phase as PhaseId,
    startedOn: r.started_on,
    endedOn: r.ended_on,
  };
}

export async function fetchPhasePeriods(): Promise<PhasePeriod[]> {
  const data = unwrap(
    await supabase
      .from("phase_periods")
      .select("id, phase, started_on, ended_on")
      .is("deleted_at", null)
      .order("started_on", { ascending: false })
      .order("created_at", { ascending: false }),
  );
  return data.map(toPhasePeriod);
}

/// Switch the current phase, preserving history. Exactly one open period
/// (ended_on null) exists per user — enforced by a partial unique index.
/// Same-day switches never leave 1-day sliver rows: switching back to the
/// phase you just left reopens it (full undo, day count restored).
export async function switchPhase(
  newPhase: PhaseId,
): Promise<{ periods: PhasePeriod[]; settings: UserSettings }> {
  const t = today();
  const periods = await fetchPhasePeriods();
  const open = periods.find((p) => p.endedOn === null);

  async function syncSettings(startedOn: string): Promise<void> {
    await updateSettings({ currentPhase: newPhase, phaseStartDate: startedOn });
  }

  if (!open) {
    unwrap(
      await supabase
        .from("phase_periods")
        .insert({ phase: newPhase, started_on: t }),
    );
    await syncSettings(t);
  } else if (open.phase === newPhase) {
    // no-op
  } else if (open.startedOn === t) {
    // Same-day sliver: undo back to the previous phase, or relabel in place.
    const prev = periods
      .filter((p) => p.endedOn !== null)
      .sort((a, b) => b.endedOn!.localeCompare(a.endedOn!))[0];
    if (prev && prev.phase === newPhase && prev.endedOn === t) {
      // Undo: delete the sliver first so the one-open index never sees two.
      unwrap(
        await supabase
          .from("phase_periods")
          .update({ deleted_at: new Date().toISOString() })
          .eq("id", open.id),
      );
      unwrap(
        await supabase
          .from("phase_periods")
          .update({ ended_on: null })
          .eq("id", prev.id),
      );
      await syncSettings(prev.startedOn);
    } else {
      unwrap(
        await supabase
          .from("phase_periods")
          .update({ phase: newPhase })
          .eq("id", open.id),
      );
      await syncSettings(open.startedOn);
    }
  } else {
    unwrap(
      await supabase
        .from("phase_periods")
        .update({ ended_on: t })
        .eq("id", open.id),
    );
    unwrap(
      await supabase
        .from("phase_periods")
        .insert({ phase: newPhase, started_on: t }),
    );
    await syncSettings(t);
  }

  const refreshed = await fetchPhasePeriods();
  const nowOpen = refreshed.find((p) => p.endedOn === null);
  return {
    periods: refreshed,
    settings: {
      currentPhase: (nowOpen?.phase ?? newPhase) as PhaseId,
      phaseStartDate: nowOpen?.startedOn ?? t,
    },
  };
}
