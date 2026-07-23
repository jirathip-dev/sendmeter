import { supabase } from "../supabase";
import type { HealthMetric } from "../../types";
import { unwrap } from "./shared";

export async function fetchHealthMetrics(days = 14): Promise<HealthMetric[]> {
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - days);
  const cutoffStr = `${cutoff.getFullYear()}-${String(cutoff.getMonth() + 1).padStart(2, "0")}-${String(cutoff.getDate()).padStart(2, "0")}`;
  const data = unwrap(
    await supabase
      .from("health_metrics")
      .select(
        "date, readiness, zone, computed_at, hrv_sdnn_ms, resting_hr, sleep_hours, sleep_deep_hours, sleep_rem_hours, body_mass_kg, resp_rate_bpm",
      )
      .gte("date", cutoffStr)
      .order("date", { ascending: true }),
  );
  return data.map((r) => ({
    date: r.date,
    readiness: r.readiness,
    zone: r.zone,
    computedAt: r.computed_at,
    hrvSdnnMs: r.hrv_sdnn_ms,
    restingHr: r.resting_hr,
    sleepHours: r.sleep_hours,
    sleepDeepHours: r.sleep_deep_hours,
    sleepRemHours: r.sleep_rem_hours,
    bodyMassKg: r.body_mass_kg,
    respRateBpm: r.resp_rate_bpm,
  }));
}

/// Full body-weight history (SL-88) — every dated weigh-in, oldest first.
/// The strength-to-weight trend forward-fills these across rep dates, so it
/// needs the whole history, not the dashboard's 14-day window.
export async function fetchWeightHistory(): Promise<
  { date: string; kg: number }[]
> {
  const data = unwrap(
    await supabase
      .from("health_metrics")
      .select("date, body_mass_kg")
      .not("body_mass_kg", "is", null)
      .order("date", { ascending: true }),
  );
  return data.map((r) => ({ date: r.date, kg: r.body_mass_kg as number }));
}

/// Hard-deletes the signed-in user's health_metrics rows (RLS scopes to
/// auth.uid()). Used by "Clear health data & resync" to recover from data
/// polluted by e.g. the watch being worn by someone else. Defaults to all
/// rows; pass `from`/`to` (YYYY-MM-DD) to limit to a date range. A lower
/// date bound is always sent so PostgREST never sees an unfiltered delete.
export async function deleteHealthMetrics(opts?: {
  from?: string;
  to?: string;
}): Promise<void> {
  // Guard: an unauthenticated DELETE isn't an error — RLS just matches zero
  // rows and reports success, so the UI would claim "cleared" while nothing
  // happened (seen when a revoked session fell back to anon). Fail loudly
  // instead so the user knows to sign in again.
  const { data, error: userError } = await supabase.auth.getUser();
  if (userError || !data.user) {
    throw new Error("Session expired — sign in again, then retry the clear.");
  }
  let q = supabase
    .from("health_metrics")
    .delete()
    .gte("date", opts?.from ?? "2000-01-01");
  if (opts?.to) q = q.lte("date", opts.to);
  const { error } = await q;
  if (error) throw error;
}
