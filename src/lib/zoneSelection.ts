import {
  PREHAB_PROTOCOL,
  WARMUP_PROTOCOL,
  prehabTarget,
  warmupTarget,
  ZONE_INTENSITY,
  zonePrescription,
  type ForceCurveModel,
  type RecordedZone,
  type TrainingQuality,
} from "./force-curve";
import { classifyZoneLoaded } from "./zoneHistory";
import { holdForSet } from "./protocol";
import type { GaugeTarget } from "../components/ForceCurveCard";
import type { TindeqPreset, TindeqSide } from "../types";

/// A selected zone = a load band for the live chart + a full guided protocol
/// (pull time / rest / reps / sets) for the fullscreen countdown. Shared by
/// TargetZonesCard (the chips) and ZoneFocusCard (the SL-100 recommendation).
export interface ZoneSelection {
  /// The zoneTag (exercise, plus " · side" when single-handed) this selection
  /// was built against (#298 round 6, finding 3) — NOT necessarily the
  /// current one: `rederiveSelection` holds this selection as-is while the
  /// curve for a NEW tag is still fitting, so `tag` is what lets a caller
  /// detect that staleness (`armedForDifferentTag`) instead of assuming a
  /// held selection always matches whatever tag is live now.
  tag: string;
  target: GaugeTarget;
  protocol: TindeqPreset;
}

/// Each training quality gets its own hue (cool → warm as it moves from
/// endurance to power), so the zone chips read as a spectrum, not one color.
export const QUALITY_COLORS: Record<TrainingQuality, string> = {
  power: "var(--danger)", // orange — max intensity
  strength: "var(--warning)", // yellow
  "power-endurance": "var(--info)", // violet
  endurance: "var(--success)", // electric blue
};

/// Build the gauge band + guided protocol for a zone (pure). Returns null if
/// the curve can't derive this zone (e.g. no CF for endurance / pow-end).
/// `intensityPct` (SL-97) scales the target load; the hold/reps prescription
/// is adjusted to keep the training dose equivalent — see
/// `zonePrescription` in force-curve.ts for the math.
export function buildZoneSelection(
  model: ForceCurveModel | null,
  q: TrainingQuality,
  tag: string,
  alt: boolean,
  intensityPct = 100,
): ZoneSelection | null {
  if (!model) return null;
  const p = zonePrescription(model, q, intensityPct);
  if (!p) return null;
  const t = p.target;
  return {
    tag,
    target: {
      kg: t.targetKg,
      lowKg: t.lowKg,
      highKg: t.highKg,
      workS: t.workS,
      label: `${t.label} · ${tag}`,
    },
    protocol: {
      id: `zone:${q}`,
      name: `${t.label} · ${tag}`,
      holdS: p.holdS,
      holdsS: null,
      reps: p.reps,
      sets: p.sets,
      restRepsS: p.restRepsS,
      restSetsS: p.restSetsS,
      targetKg: t.targetKg,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides: alt,
    },
  };
}

/// Build the gauge band + guided protocol for Prehab (#325) — mirrors
/// `buildZoneSelection` but isn't one: Prehab has no `TrainingQuality`, so it
/// can't go through `zonePrescription`. Single-sided by design (`sets: 1` —
/// #320's alternation fires per SET, and one set never triggers it, so there
/// is no "alternate sides" option here to thread through). Null when the
/// model can't derive a Prehab target (see `prehabTarget`).
export function buildPrehabSelection(
  model: ForceCurveModel | null,
  tag: string,
): ZoneSelection | null {
  if (!model) return null;
  const t = prehabTarget(model);
  if (!t) return null;
  return {
    tag,
    target: {
      kg: t.targetKg,
      lowKg: t.lowKg,
      highKg: t.highKg,
      workS: t.workS,
      label: `${t.label} · ${tag}`,
    },
    protocol: {
      id: "zone:prehab",
      name: `${t.label} · ${tag}`,
      holdS: PREHAB_PROTOCOL.holdS,
      holdsS: null,
      reps: PREHAB_PROTOCOL.reps,
      sets: PREHAB_PROTOCOL.sets,
      restRepsS: PREHAB_PROTOCOL.restRepsS,
      restSetsS: PREHAB_PROTOCOL.restSetsS,
      targetKg: t.targetKg,
      targetPct: null,
      pctBasis: "pr",
      pctStep: 0,
      targetCurve: false,
      alternateSides: false,
    },
  };
}

/// Build the progressive Warm-up primer (#297 Part B2). Like Prehab, this is
/// a recorded maintenance zone rather than a `TrainingQuality`; unlike
/// Prehab, both hold duration and %-of-PR target ramp per set.
export function buildWarmupSelection(
  model: ForceCurveModel | null,
  tag: string,
  prKg = model?.maxF ?? 0,
): ZoneSelection | null {
  if (!model) return null;
  const t = warmupTarget(model, prKg);
  if (!t) return null;
  return {
    tag,
    target: {
      kg: t.targetKg,
      lowKg: t.lowKg,
      highKg: t.highKg,
      workS: t.workS,
      label: `${t.label} · ${tag}`,
    },
    protocol: {
      id: "zone:warmup",
      name: `${t.label} · ${tag}`,
      holdS: WARMUP_PROTOCOL.holdS,
      holdsS: [...WARMUP_PROTOCOL.holdsS],
      reps: WARMUP_PROTOCOL.reps,
      sets: WARMUP_PROTOCOL.sets,
      restRepsS: WARMUP_PROTOCOL.restRepsS,
      restSetsS: WARMUP_PROTOCOL.restSetsS,
      targetKg: null,
      targetPct: WARMUP_PROTOCOL.targetPct,
      pctBasis: WARMUP_PROTOCOL.pctBasis,
      pctStep: WARMUP_PROTOCOL.pctStep,
      targetCurve: false,
      alternateSides: false,
    },
  };
}

/// Every zone a saved hold can carry, recommended-protocol side (#325) — the
/// membership check `protocolQuality` parses a `zone:${q}` id against.
/// Separate from `QUALITY_COLORS`' keys, which deliberately stay at the four
/// TRAINABLE qualities (a color per hue on the chip spectrum); maintenance
/// protocols stay outside that table.
const RECORDED_ZONES: RecordedZone[] = [
  "power",
  "strength",
  "power-endurance",
  "endurance",
  "warmup",
  "prehab",
];

/// The color a hold's recorded zone should show as, across the four trainable
/// hues plus distinct maintenance colors.
export function zoneColor(z: RecordedZone): string {
  if (z === "warmup") return "var(--primary)";
  if (z === "prehab") return "var(--ink-muted)";
  return QUALITY_COLORS[z];
}

const INTENSITY_KEY = "sendmeter:zone-intensity";

/// ONE global intensity pct (SL-97b) — a single dial (rendered in the
/// recommended-zone card, #172) rather than each zone remembering its own.
/// It scales RECOMMENDED ZONES ONLY; custom presets are never rescaled.
/// Persisted as a plain number; an invalid or missing value (including a
/// stale per-quality map from before SL-97b) falls back to 100
/// (ZONE_INTENSITY.default).
export function loadIntensity(): number {
  try {
    const raw = localStorage.getItem(INTENSITY_KEY);
    if (!raw) return ZONE_INTENSITY.default;
    const v = JSON.parse(raw) as unknown;
    if (typeof v === "number" && v >= ZONE_INTENSITY.min && v <= ZONE_INTENSITY.max) {
      return v;
    }
    return ZONE_INTENSITY.default;
  } catch {
    return ZONE_INTENSITY.default;
  }
}

export function saveIntensity(pct: number): void {
  try {
    localStorage.setItem(INTENSITY_KEY, JSON.stringify(pct));
  } catch {
    /* quota / disabled storage — persistence is best-effort */
  }
}

/// Re-derive whatever is currently armed at a new intensity pct. RECOMMENDED
/// ZONES ONLY: anything without a `zone:${q}` id (i.e. a custom preset) is
/// returned untouched — that guard is what keeps the dial from ever rescaling
/// a user-defined preset's load. Falls back to the current selection if the
/// zone can no longer be derived, so moving the dial can't silently disarm.
export function applyIntensity(
  sel: ZoneSelection | null,
  model: ForceCurveModel | null,
  tag: string | null,
  intensityPct: number,
): ZoneSelection | null {
  const q = selectedQuality(sel);
  if (!sel || !q || !model || !tag) return sel;
  return buildZoneSelection(model, q, tag, sel.protocol.alternateSides, intensityPct) ?? sel;
}

/// Re-derive whatever is currently armed for a NEW tag/side/intensity
/// (#298). `buildZoneSelection` only runs when a zone chip (or the
/// recommendation card) is tapped, so `zoneSel` otherwise keeps whatever
/// tag/kg it was armed under — switching tag/side afterwards (the
/// fullscreen's tag chips) left the armed protocol/band on the OLD tag's
/// numbers. Callers re-derive from this on every render instead. Unlike
/// `applyIntensity` (which keeps the current selection when a zone briefly
/// can't be derived — a dial nudge shouldn't disarm), this returns **null**
/// on failure: a tag switch that can't derive the zone must read as a free
/// hold, never as the previous tag's numbers. A non-zone id (custom preset)
/// and a null selection both pass through untouched.
///
/// A `null` model is held rather than treated as failure (mirrors
/// `applyIntensity`) — `model` goes null both when the curve genuinely
/// rejects this zone AND when there simply isn't one yet (still fitting, or
/// a fetch failure), and the latter is reachable mid-run: a rep saved under a
/// freshly-typed tag joins `allTags`, flips `effectiveTag`/`tagSideKey`, and
/// the recompute effect (blocked by `curveFrozen`) never refreshes `model`
/// for the new key. Disarming here would drop the guided UI and gauge band
/// out from under a frozen, still-recording run.
export function rederiveSelection(
  sel: ZoneSelection | null,
  model: ForceCurveModel | null,
  tag: string | null,
  intensityPct: number,
  prKg?: number | null,
): ZoneSelection | null {
  // Maintenance protocols checked FIRST, via the full `protocolQuality`
  // (not `selectedQuality`, which filters them out). Their targets are
  // tag-derived, unlike a custom preset's fixed number, so a tag switch must
  // rebuild them just like a recommended training zone would.
  const recordedZone = sel ? protocolQuality(sel.protocol) : null;
  if (sel && (recordedZone === "prehab" || recordedZone === "warmup")) {
    if (!model) return sel;
    if (!tag) return null;
    return recordedZone === "prehab"
      ? buildPrehabSelection(model, tag)
      : buildWarmupSelection(model, tag, prKg ?? model.maxF);
  }
  const q = selectedQuality(sel);
  if (!sel || !q) return sel;
  if (!model) return sel;
  if (!tag) return null;
  return buildZoneSelection(model, q, tag, sel.protocol.alternateSides, intensityPct);
}

/// Whether the currently ARMED protocol (custom preset or zone) alternates
/// sides (#298). Read straight off the selection's own `alternateSides` —
/// set once, at pick time, and preserved as-is across a tag/side switch (see
/// `rederiveSelection`) — never off a value derived FROM the side/tag
/// picked, or a caller deriving the picked side FROM this would be circular.
/// `preset` and `zoneSel` are mutually exclusive (see `selectZoneOutcome` /
/// `withPresetSelected` in forceSelection.ts); neither armed is `false`, not
/// an error — a free hold has no side of its own to protect.
export function armedAlternates(
  preset: TindeqPreset | null,
  zoneSel: ZoneSelection | null,
): boolean {
  return preset ? preset.alternateSides : (zoneSel?.protocol.alternateSides ?? false);
}

/// The side a curve reference (chart filter / armed-zone target) should use
/// (#298). An alternating protocol trains BOTH hands, so while one is armed
/// this is always null (all sides) regardless of whatever side is otherwise
/// picked — that side only ever applies to a single-hand protocol or a free
/// hold, and letting it leak through here would silently target (and
/// curve-fit) one hand's data for a two-handed run.
export function chartSideFor(
  alternates: boolean,
  pendingSide: TindeqSide,
): TindeqSide | null {
  if (alternates) return null;
  return pendingSide === "left" || pendingSide === "right" ? pendingSide : null;
}

/// Whether the armed zone was built under a DIFFERENT tag than the one now
/// live (#298 round 6, finding 3) — e.g. ticking "Alternate left ⇄ right"
/// flips `chartSideFor` to null, changing `zoneTag` out from under a
/// selection baked for a single side. `rederiveSelection` deliberately HOLDS
/// a selection as-is while its model is still fitting (see that function's
/// own doc — a still-fitting curve isn't a rejection), so `armedZone` keeps
/// existing but its numbers belong to the OLD tag until the new tag's curve
/// lands. Combined with the caller's own "is that curve still fetching" check
/// (ForceView's `curveComputing` — a tag that will NEVER get a curve must not
/// block Start forever), this is what tells the caller to block Start rather
/// than run a whole set against the wrong tag's prescription.
export function armedForDifferentTag(
  sel: ZoneSelection | null,
  tag: string | null,
): boolean {
  return sel !== null && sel.tag !== tag;
}

/// The zone a PROTOCOL arms, parsed back from the `zone:${q}` id
/// the recommended-protocol builders mint. Null for a custom
/// preset, which has no declared quality — only a load and a hold time.
/// Returns `RecordedZone` (#325), not `TrainingQuality` — Prehab arms itself
/// via `zone:prehab` exactly like a trainable zone does, so this has to admit
/// it; use `selectedQuality` below for the four-quality-only view (the chip
/// highlight, the intensity dial's gate).
export function protocolQuality(p: TindeqPreset): RecordedZone | null {
  const m = /^zone:(.+)$/.exec(p.id);
  const q = m?.[1] as RecordedZone | undefined;
  return q && RECORDED_ZONES.includes(q) ? q : null;
}

/// The TRAINABLE zone a selection arms — so the recommended-zone chips
/// highlight from `selected` alone. Null for a custom preset and both
/// maintenance protocols; filtering them here also keeps the intensity dial
/// from modifying their fixed prescriptions.
export function selectedQuality(
  sel: ZoneSelection | null,
): TrainingQuality | null {
  const q = sel ? protocolQuality(sel.protocol) : null;
  return q && q !== "prehab" && q !== "warmup" ? q : null;
}

/// The quality a hold saved from this protocol was PERFORMED under (#259) —
/// what the recording stores, so neither History nor the training-balance
/// chart has to re-derive it from duration afterwards.
///
/// An armed zone states its own quality outright. A custom preset doesn't, so
/// it gets the LOAD-AWARE classification — the exact call `PresetManager`'s
/// badge makes (`classifyZoneLoaded`, duration AND resolved load), so what
/// gets stored is what the user was shown when they armed it. That load half
/// is precisely what a later duration-only re-derivation throws away: a 7s
/// hold at 85% of max is Strength on the badge and Power Endurance by
/// duration alone, and before this the second one silently won.
///
/// `targetKg` is the preset's target for the SET being saved (per-set ramps
/// mean set 3 can classify differently from set 1). Null with no protocol —
/// a freehand hold records no zone rather than a guess. `set` (#332) is that
/// same set, so a per-set hold list classifies against the hold actually
/// performed rather than always the base `holdS`.
///
/// Returns `RecordedZone | null`: an armed maintenance protocol states its
/// zone outright, preventing its holds from falling through to a trainable
/// duration/load classification.
export function performedQuality(
  p: TindeqPreset | null,
  targetKg: number | null,
  refs: { maxF: number | null; cf: number | null },
  set: number,
): RecordedZone | null {
  if (!p) return null;
  return protocolQuality(p) ?? classifyZoneLoaded(holdForSet(p, set), targetKg, refs);
}
