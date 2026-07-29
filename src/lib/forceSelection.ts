import type { TindeqPreset } from "../types";
import type { ZoneSelection } from "./zoneSelection";

export interface ForceSelection {
  zoneSel: ZoneSelection | null;
  preset: TindeqPreset | null;
}

/// #296: a recommended zone and a custom preset used to be independent
/// selections that both fed the fullscreen's `activeProtocol` precedence, so
/// arming one never disarmed the other — whichever precedence favored
/// silently won. These two functions are the single source of truth for
/// keeping them mutually exclusive: arming one (non-null) clears the other.
/// Arming null (deselect) or re-arming an already-armed zone (the intensity
/// dial, the alternate-sides toggle) touches only that side, so a custom
/// preset never gets resurrected by an unrelated zone tweak.
export function withZoneSelected(
  current: ForceSelection,
  sel: ZoneSelection | null,
): ForceSelection {
  if (sel == null) return { ...current, zoneSel: null };
  return { zoneSel: sel, preset: null };
}

export function withPresetSelected(
  current: ForceSelection,
  preset: TindeqPreset | null,
): ForceSelection {
  if (preset == null) return { ...current, preset: null };
  return { zoneSel: null, preset };
}

export interface ZoneSelectionOutcome {
  selection: ForceSelection;
  clearsPersistedPreset: boolean;
}

/// #296 follow-up: arming a zone must ALWAYS clear the persisted custom-preset
/// id (localStorage), not just when `preset` state itself was non-null. The
/// persisted key and `preset` state can drift apart during the mount-restore
/// race below — a zone armed before the restore lands leaves `preset` null
/// while the key still points at some other preset — and a clear gated on
/// `preset !== null` misses exactly that case, letting the stale key re-arm
/// the preset on the next mount.
export function selectZoneOutcome(
  current: ForceSelection,
  sel: ZoneSelection | null,
): ZoneSelectionOutcome {
  return { selection: withZoneSelected(current, sel), clearsPersistedPreset: sel != null };
}

/// #296 follow-up: the persisted-preset restore fires from a fetch that
/// started at mount, and can land after the user has since armed a zone or a
/// preset directly — restoring must always check the CURRENT selection,
/// never what was armed at mount, or a zone the user just tapped loses to a
/// resurrected preset (the original #296 symptom, reintroduced as a race).
export function restoredSelection(
  current: ForceSelection,
  saved: TindeqPreset,
): ForceSelection {
  if (current.zoneSel != null || current.preset != null) return current;
  return { zoneSel: null, preset: saved };
}
