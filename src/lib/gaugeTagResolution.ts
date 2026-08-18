import type { TindeqSide } from "../types";

// #684: the tag/side a recording is STAMPED with at the persist boundary.
//
// `gaugeInputLock.ts` documents the footgun this is the fix for: the gauge's
// display tag (`liveEffectiveTag`) falls back to `allTags[0]` — an arbitrary
// first-in-list exercise — when the raw Exercise field doesn't match an
// existing tag. That fallback is harmless for the charts it feeds (they show
// *something*), but stamping a SAVED recording with it would file the rep
// under an exercise the user never picked — "worse than not locking it at
// all" (#298 round 5, finding 2). Today it survives only because the phone
// required a tag before Start; always-armed hands-free removes that
// precondition, so the boundary must resolve its own tag and never inherit
// the display fallback.
//
// Resolution rule at the persist boundary:
//
//     explicitSelection ?? lastUsedTag ?? untagged('')
//
// `explicitSelection` is the raw Exercise&Side field the user actually set
// (`pendingTag`/`pendingSide` in ForceView); a brand-new typed tag counts as
// explicit even though it isn't in `allTags` yet. `lastUsedTag` is whatever
// explicit tag was last persisted — a real default because the user chose it,
// the precise property `allTags[0]` lacks. `''` is untagged: the schema
// already defaults `tindeq_recordings.tag` to `''` and the partial index
// `where tag <> ''` treats it as "no tag", so no migration is needed.
//
// The two last-used fields are remembered INDEPENDENTLY (`#684 F2`): picking
// a side while the Exercise field is empty must not wipe the remembered tag,
// so each selection merges onto the existing pair rather than overwriting it
// wholesale. See `rememberGaugeLabelSelection`.
//
// This module owns the localStorage keys too, so the read (at the persist
// boundary) and the write (on every explicit selection) can never drift apart
// from the resolution rule.

export const GAUGE_LAST_TAG_KEY = "sendmeter:gauge-last-tag";
export const GAUGE_LAST_SIDE_KEY = "sendmeter:gauge-last-side";

export interface LastUsedGaugeLabel {
  tag: string;
  side: TindeqSide;
}

const VALID_SIDES: readonly TindeqSide[] = ["", "left", "right", "both"];

export interface GaugeLabelStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

function defaultStorage(): GaugeLabelStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
}

/// The tag a recording gets stamped with at the persist boundary.
/// `explicitSelection` wins; an empty explicit field falls back to the
/// remembered last-used tag; with neither, the recording is untagged (`''`).
/// `allTags` is deliberately NOT an input — the display fallback it feeds
/// (`allTags[0]`) must never reach a saved rep, and the pure signature makes
/// that impossible to reintroduce.
export function resolveRecordingTag(
  explicitSelection: string,
  lastUsedTag: string | null,
): string {
  const explicit = explicitSelection.trim();
  if (explicit) return explicit;
  return lastUsedTag?.trim() ?? "";
}

/// The side a recording gets stamped with at the persist boundary, paired
/// with `resolveRecordingTag`: explicit side wins, then the remembered
/// last-used side, then unspecified (`""`).
export function resolveRecordingSide(
  explicitSelection: TindeqSide,
  lastUsedSide: TindeqSide | null,
): TindeqSide {
  if (explicitSelection) return explicitSelection;
  return lastUsedSide ?? "";
}

/// The last explicitly-selected tag/side, read from storage. A missing,
/// disabled or corrupt record reads as "nothing remembered" — never a throw.
/// The persisted side is validated against the `TindeqSide` union, so a
/// hand-edited/corrupted value degrades to `""` instead of flowing into a
/// `NewTindeqRecording.side` that would trip the DB `CHECK (side in …)`
/// constraint and permanently strand the rep in the retry queue (#684 F5).
export function loadLastUsedGaugeLabel(
  storage: GaugeLabelStorage | null = defaultStorage(),
): LastUsedGaugeLabel {
  if (!storage) return { tag: "", side: "" };
  try {
    const tag = storage.getItem(GAUGE_LAST_TAG_KEY)?.trim() ?? "";
    const rawSide = storage.getItem(GAUGE_LAST_SIDE_KEY) ?? "";
    const side: TindeqSide = (VALID_SIDES as readonly string[]).includes(rawSide)
      ? (rawSide as TindeqSide)
      : "";
    return { tag, side };
  } catch {
    return { tag: "", side: "" };
  }
}

/// Remember an explicit tag/side selection for the next untagged free hold.
/// Written on EVERY explicit selection, best-effort: storage refused/quota is
/// not a user-facing failure (the choice still applies to this run's rep).
///
/// The two fields are stored INDEPENDENTLY: an explicit selection of one
/// field never writes the other field's current (possibly empty) value over
/// the remembered one. A caller that picked only a side (with the Exercise
/// field still empty) passes the current tag through, and vice versa — see
/// `rememberGaugeLabelSelection`. This low-level writer is what pins that:
/// it trims the tag and validates the side, so a caller merging is always
/// writing a real selection.
export function saveLastUsedGaugeLabel(
  tag: string,
  side: TindeqSide,
  storage: GaugeLabelStorage | null = defaultStorage(),
): void {
  if (!storage) return;
  try {
    storage.setItem(GAUGE_LAST_TAG_KEY, tag.trim());
    storage.setItem(GAUGE_LAST_SIDE_KEY, side);
  } catch {
    /* quota / disabled storage — persistence is best-effort */
  }
}

/// Merge one freshly-picked field onto the remembered pair, and persist the
/// result. The merge is what makes the remember-rule survive an ordinary
/// mid-untagged-run side tap (#684 F2): picking a side while the Exercise
/// field is empty must NOT wipe the remembered tag (and vice versa), so the
/// picked side is written while the remembered tag is carried through — the
/// two fields are remembered independently, never as whatever the other raw
/// field happens to hold at that moment.
///
/// `explicit`'s non-empty fields win; the other field falls back to the
/// remembered pair. Returns the merged pair so the caller can mirror it in a
/// ref without re-reading storage.
export function rememberGaugeLabelSelection(
  explicit: { tag: string; side: TindeqSide },
  remembered: LastUsedGaugeLabel,
  storage: GaugeLabelStorage | null = defaultStorage(),
): LastUsedGaugeLabel {
  const tag = explicit.tag.trim();
  const side = explicit.side;
  const merged: LastUsedGaugeLabel = {
    tag: tag || remembered.tag,
    side: side || remembered.side,
  };
  saveLastUsedGaugeLabel(merged.tag, merged.side, storage);
  return merged;
}

/// Resolve a full tag+side at the persist boundary from the raw Exercise&Side
/// fields and the remembered last-used pair. `allTags[0]` cannot appear.
export function resolveRecordingGaugeLabel(
  explicit: { tag: string; side: TindeqSide },
  lastUsed: LastUsedGaugeLabel,
): LastUsedGaugeLabel {
  return {
    tag: resolveRecordingTag(explicit.tag, lastUsed.tag),
    side: resolveRecordingSide(explicit.side, lastUsed.side),
  };
}
