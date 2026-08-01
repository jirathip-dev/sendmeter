import type { ForceCurveModel, TrainingQuality } from "./force-curve";
import {
  buildZoneSelection,
  rederiveSelection,
  selectedQuality,
  type ZoneSelection,
} from "./zoneSelection";

export type ZoneUnarmedNotice = {
  quality: "endurance" | "power-endurance";
  tag: string;
};

export interface PostFitZoneState {
  selection: ZoneSelection | null;
  notice: ZoneUnarmedNotice | null;
  revision: number;
}

/// Apply a settled curve to the currently armed zone and its explanatory
/// status as one state transition. `fitTag` identifies the request that
/// produced `model`; comparing it with the state passed to this function is
/// what prevents an old promise from changing a newer selection.
export function postFitZoneDecision(
  current: PostFitZoneState,
  model: ForceCurveModel | null,
  fitTag: string | null,
  intensityPct: number,
  expectedRevision: number,
): PostFitZoneState {
  if (current.revision !== expectedRevision) return current;
  // #298: an absent/still-loading fit is not a rejection and must not disarm.
  if (!model || !fitTag) return current;

  if (!current.selection) {
    if (
      current.notice?.tag === fitTag &&
      buildZoneSelection(model, current.notice.quality, fitTag, false, intensityPct)
    ) {
      return { ...current, notice: null };
    }
    return current;
  }

  // The settled model belongs to some older tag/side, or this isn't one of
  // the two curve-derived zones whose post-run loss needs an explanation.
  if (current.selection.tag !== fitTag) return current;
  const quality = selectedQuality(current.selection);
  const next = rederiveSelection(current.selection, model, fitTag, intensityPct);
  if (next) {
    return current.notice ? { ...current, notice: null } : current;
  }
  if (!isNoticeQuality(quality)) return { ...current, selection: null, notice: null };
  return { ...current, selection: null, notice: { quality, tag: fitTag } };
}

function isNoticeQuality(
  quality: TrainingQuality | null,
): quality is ZoneUnarmedNotice["quality"] {
  return quality === "endurance" || quality === "power-endurance";
}

export function zoneUnarmedNoticeText(notice: ZoneUnarmedNotice): string {
  return notice.quality === "endurance"
    ? "Endurance unarmed — the updated curve no longer has a valid critical-force fit. Add an all-out 30–60s hold to restore it."
    : "Power Endurance unarmed — the updated curve no longer has a usable Hill capability fit. Add all-out holds at varied durations to restore it.";
}
