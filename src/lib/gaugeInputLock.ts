import type { ZoneSelection } from "./zoneSelection";
import type { TindeqPreset, TindeqSide } from "../types";

/// The gauge inputs a run must not see change mid-flight (#298 round 5): the
/// tag/side a rep is stamped with (both the resolved `tag` AND the raw
/// `pendingTag`/`pendingSide` a recording actually gets filed under — see
/// their own doc below), the armed zone-or-preset selection, the
/// session-intensity pct, and the PR a %-of-PR target resolves against.
/// Everything a run computes FROM these — the force-curve model, `zoneTag`,
/// `armedZone`, the expanded timeline, `presetRefs` — then stays constant
/// automatically, because its inputs do; there is nothing left to snapshot
/// separately.
export interface GaugeInputs {
  tag: string | null;
  chartSide: TindeqSide | null;
  zoneSel: ZoneSelection | null;
  preset: TindeqPreset | null;
  intensityPct: number;
  /// #298 round 5 (finding 2): the raw Exercise&Side card fields, kept
  /// SEPARATE from `tag` above — `tag` is `liveEffectiveTag`, which falls
  /// back to `allTags[0]` when the raw field doesn't match an existing tag,
  /// and stamping a recording with that fallback (instead of what the user
  /// actually set) would be worse than not locking it at all. This is what a
  /// saved rep's `tag`/`side` columns must read for the whole run.
  pendingTag: string;
  pendingSide: TindeqSide;
  /// #298 round 5 (finding 3): the PR a `pctBasis: "pr"` preset's target
  /// resolves against. Unlike `zoneSel`/`preset` (which only change on a
  /// deliberate re-pick), this drifts on its own — `curveRecordings` grows on
  /// every per-rep save — so it needs the same lock as everything else, or an
  /// early rep's new PR moves a later rep's target mid-set.
  prKg: number | null;
}

function gaugeInputsEqual(a: GaugeInputs, b: GaugeInputs): boolean {
  return (
    a.tag === b.tag &&
    a.chartSide === b.chartSide &&
    a.zoneSel === b.zoneSel &&
    a.preset === b.preset &&
    a.intensityPct === b.intensityPct &&
    a.pendingTag === b.pendingTag &&
    a.pendingSide === b.pendingSide &&
    a.prKg === b.prKg
  );
}

/// What the locked gauge-inputs snapshot should become this render.
///
/// Replaces the FrozenRun snapshot (#298 round 3), which froze the
/// *outputs* (protocol, timeline) while `presetRefs` and the values handed
/// to ForceFullscreen stayed render-derived — two sources of truth that
/// could disagree mid-run (a saved rep's zone diverging from a later rep of
/// the same set, the screen reading one side while the slice being saved was
/// stamped another). Locking the INPUTS instead means the per-rep recorder,
/// Stop, and the fullscreen display all derive from the exact same
/// tag/side/selection/intensity for the whole run, so they cannot disagree —
/// there is one plan, not a plan plus a copy to keep in sync.
///
/// While `runActive`, the snapshot holds regardless of what `live` says (a
/// tag/side/zone/intensity change mid-run is a structural no-op). While not,
/// it tracks `live` — so the very render where `runActive` turns true already
/// reads the correct snapshot, with no one-render lag: the caller re-derives
/// this on every render (the React "storing information from previous
/// renders" pattern, not an effect) and stores whatever comes back, so by the
/// time a run starts, `locked` has already been kept in sync up to the render
/// immediately before it.
///
/// `runActive` is NOT just "measuring" (#298 round 5, finding 1): a
/// mid-measurement BLE drop batches `setStatus("idle")` with claiming the
/// interruption in the same render (useTindeq's `handleDeviceDropped`), so
/// `measuring` alone already reads false before the deferred stop that
/// actually finishes the run has run. The caller passes
/// `measuring || tindeq.pendingInterruption` so the lock keeps holding across
/// that gap — `pendingInterruption` is cleared inside `tindeq.stop()`, i.e.
/// exactly when the run is really over.
export function nextLockedGaugeInputs(
  runActive: boolean,
  live: GaugeInputs,
  locked: GaugeInputs,
): GaugeInputs {
  if (runActive) return locked;
  return gaugeInputsEqual(live, locked) ? locked : live;
}
