import { Fragment, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  deletePreset,
  fetchPresets,
  insertPreset,
  updatePreset,
} from "../lib/repo";
import { buildTimeline, presetTargetKg, timelineDurationS } from "../lib/protocol";
import type { PresetRefs } from "../lib/protocol";
import { QUALITIES } from "../lib/force-curve";
import { classifyZoneLoaded } from "../lib/zoneHistory";
import { QUALITY_COLORS } from "../lib/zoneSelection";
import { useToast } from "../hooks/useToast";
import { restoreAt } from "../lib/restoreAt";
import { FORCE_PRESET_SELECTED_KEY } from "../lib/forcePresetStorage";
import ConfirmDialog from "./ConfirmDialog";
import NumInput from "./NumInput";
import type { TindeqPreset } from "../types";

interface Props {
  selectedId: string | null;
  onSelect: (preset: TindeqPreset | null) => void;
  /// Mount-time re-arm only (#296) — separate from onSelect so the caller can
  /// refuse to resurrect a preset past a zone armed in the meantime.
  onRestore: (preset: TindeqPreset) => void;
  /// Force references for the active exercise, so each row can show the load
  /// its %/curve target resolves to right now.
  presetRefs: PresetRefs;
  /// #298 round 6 (finding A2): ForceView locks the gauge inputs for the
  /// whole duration of a run — selecting a different preset, editing one, or
  /// creating/deleting one out from under an in-progress run would mean the
  /// set you finish isn't the set you started. Disables all of them rather
  /// than leaving a control that looks live but is inert.
  locked: boolean;
}

function fmt(sec: number): string {
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s === 0 ? `${m}m` : `${m}m${s}s`;
}

/// The training quality a protocol trains — load-aware (SL-97) when the
/// preset has a resolved target load, so the badge re-classifies live as the
/// underlying curve moves (a preset's own load is never touched by the
/// session-intensity dial — only recommended zones respond to it); falls
/// back to the SL-100 duration-only classifier for untargeted presets.
function QualityBadge({
  holdS,
  kg,
  refs,
}: {
  holdS: number;
  kg: number | null;
  refs: { maxF: number | null; cf: number | null };
}) {
  const q = classifyZoneLoaded(holdS, kg, refs);
  if (!q) return null;
  const color = QUALITY_COLORS[q];
  const label = QUALITIES.find((x) => x.id === q)?.label ?? q;
  return (
    <span
      style={{
        fontSize: "var(--t-2xs)",
        fontWeight: 700,
        color,
        border: `1px solid ${color}`,
        borderRadius: 6,
        padding: "1px 6px",
        flexShrink: 0,
        textTransform: "uppercase",
        letterSpacing: "0.04em",
      }}
    >
      {label}
    </span>
  );
}

// Selected-protocol persistence (SL-76): ForceView unmounts on tab switch and
// its preset state dies with it, so the armed protocol vanished every time
// you peeked at another tab. Remember the id and re-arm on mount. Key lives
// in forcePresetStorage.ts so ForceView can clear it too (#296).
const SELECTED_KEY = FORCE_PRESET_SELECTED_KEY;

function NumField({
  label,
  value,
  onChange,
  min,
  max,
}: {
  label: string;
  value: number;
  onChange: (v: number) => void;
  min: number;
  max: number;
}) {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 4, flex: 1, minWidth: 62 }}>
      <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)", textTransform: "uppercase", letterSpacing: "0.06em" }}>
        {label}
      </span>
      <NumInput
        value={value}
        onCommit={onChange}
        min={min}
        max={max}
        style={{ padding: "9px 10px", fontSize: "var(--t-base)" }}
      />
    </label>
  );
}

/// Hang-protocol presets (hold / reps / sets / rests). Saved to Supabase;
/// selecting one arms the guided timer in the fullscreen gauge.
export default function PresetManager({ selectedId, onSelect, onRestore, presetRefs, locked }: Props) {
  const toast = useToast();
  const [presets, setPresets] = useState<TindeqPreset[]>([]);
  const [adding, setAdding] = useState(false);
  // Non-null while the form edits an existing preset (pencil).
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [holdS, setHoldS] = useState(7);
  const [reps, setReps] = useState(6);
  const [sets, setSets] = useState(3);
  const [restRepsS, setRestRepsS] = useState(3);
  const [restSetsS, setRestSetsS] = useState(180);
  const [targetMode, setTargetMode] = useState<"off" | "kg" | "pct" | "curve">("off");
  const [targetKg, setTargetKg] = useState(0);
  const [targetPct, setTargetPct] = useState(60);
  const [pctBasis, setPctBasis] = useState<"pr" | "cf">("pr");
  const [pctStep, setPctStep] = useState(0); // +% per set
  const [alternateSides, setAlternateSides] = useState(false);
  // Issue #143: gate preset delete behind a confirm dialog. Holds the preset
  // being confirmed (need its name for the dialog copy).
  const [confirmDelete, setConfirmDelete] = useState<TindeqPreset | null>(null);

  function openEdit(p: TindeqPreset) {
    setEditingId(p.id);
    setName(p.name);
    setHoldS(p.holdS);
    setReps(p.reps);
    setSets(p.sets);
    setRestRepsS(p.restRepsS);
    setRestSetsS(p.restSetsS);
    setTargetMode(
      p.targetCurve ? "curve" : p.targetPct != null ? "pct" : p.targetKg != null ? "kg" : "off",
    );
    setTargetKg(p.targetKg ?? 0);
    setTargetPct(p.targetPct ?? 60);
    setPctBasis(p.pctBasis);
    setPctStep(p.pctStep);
    setAlternateSides(p.alternateSides);
    setAdding(true);
  }

  // #296 follow-up: this effect's fetch `.then()` runs once, whenever the
  // fetch happens to resolve — a zone (or a preset) can be armed in the
  // meantime, off the independent zone fetch. Reading `selectedId`/`onRestore`
  // straight from the effect closure would freeze both at their MOUNT-render
  // values (both null), so the guard below would wrongly pass and resurrect
  // the persisted preset past whatever the user armed since. These refs are
  // kept current every render so the guard and the restore call always see
  // the latest values, not the mount-time ones.
  //
  // Sync via useLayoutEffect, not useEffect: passive effects flush in a
  // scheduler task after commit, but the fetch's `.then()` is a microtask
  // that can run before that task — so a discrete event (a zone/preset tap)
  // could commit, and the fetch could resolve and read these refs, before a
  // passive effect ever updated them. useLayoutEffect runs synchronously
  // inside the commit, so the refs are current before any later-scheduled
  // task (including this microtask) can observe them.
  const selectedIdRef = useRef(selectedId);
  useLayoutEffect(() => {
    selectedIdRef.current = selectedId;
  }, [selectedId]);
  const onRestoreRef = useRef(onRestore);
  useLayoutEffect(() => {
    onRestoreRef.current = onRestore;
  }, [onRestore]);

  useEffect(() => {
    let alive = true;
    fetchPresets()
      .then((list) => {
        if (!alive) return;
        setPresets(list);
        // Re-arm the previously selected protocol (survives tab switches).
        const savedId = localStorage.getItem(SELECTED_KEY);
        if (savedId && selectedIdRef.current === null) {
          const saved = list.find((p) => p.id === savedId);
          if (saved) onRestoreRef.current(saved);
        }
      })
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : "Failed to load presets"),
      );
    return () => {
      alive = false;
    };
    // The fetch itself only ever needs to run once; selectedId/onRestore are
    // read via the refs above, kept current independently.
  }, []);

  async function save() {
    setSaving(true);
    setError(null);
    const fields: Omit<TindeqPreset, "id"> = {
      name: name.trim() || `${holdS}s × ${reps} × ${sets}`,
      holdS,
      reps,
      sets,
      restRepsS,
      restSetsS,
      targetKg: targetMode === "kg" && targetKg > 0 ? targetKg : null,
      targetPct: targetMode === "pct" && targetPct > 0 ? targetPct : null,
      pctBasis,
      pctStep: targetMode === "pct" && targetPct > 0 ? pctStep : 0,
      targetCurve: targetMode === "curve",
      alternateSides,
    };
    try {
      if (editingId) {
        const saved = await updatePreset(editingId, fields);
        setPresets((list) => list.map((p) => (p.id === editingId ? saved : p)));
        if (selectedId === editingId) onSelect(saved); // refresh armed copy
      } else {
        const saved = await insertPreset(fields);
        setPresets((list) => [saved, ...list]);
      }
      toast(editingId ? "Preset updated" : "Preset saved");
      setAdding(false);
      setEditingId(null);
      setName("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save preset");
    } finally {
      setSaving(false);
    }
  }

  async function remove(id: string) {
    const index = presets.findIndex((p) => p.id === id);
    const removed = presets[index];
    if (!removed) return; // double-fire guard
    setPresets((list) => list.filter((p) => p.id !== id));
    if (selectedId === id) onSelect(null);
    if (localStorage.getItem(SELECTED_KEY) === id) localStorage.removeItem(SELECTED_KEY);
    try {
      await deletePreset(id);
      toast("Preset deleted");
    } catch {
      // Rollback: put it back where it was; leave it deselected (deliberate —
      // don't re-arm a protocol the user just tried to delete).
      setPresets((list) => restoreAt(list, removed, index));
      toast("Couldn't delete preset — restored", "error");
    }
  }

  // Issue #143: called after the confirm dialog is accepted. Delegates to
  // `remove`, which since issue #166 rolls the preset back into the list and
  // toasts an error if the server call fails.
  function confirmRemove() {
    if (!confirmDelete) return;
    const id = confirmDelete.id;
    setConfirmDelete(null);
    void remove(id);
  }

  return (
    <div style={{ marginTop: 8 }}>
      {error && (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginBottom: 8 }}>{error}</div>
      )}

      {presets.length === 0 && !adding && (
        <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-faint)", marginBottom: 10, lineHeight: 1.5 }}>
          Save a hang protocol (hold · reps · sets · rest) — selecting one runs
          a guided HOLD/REST timer on the gauge.
        </div>
      )}

      {presets.map((p) => {
        const selected = p.id === selectedId;
        // The load this preset's target (fixed kg, %/curve — any mode)
        // resolves to for the active exercise right now — used by the quality
        // badge below (SL-97 load-aware classification) even for fixed-kg
        // presets. Null when the preset has no target at all, or a %/curve
        // target whose reference (PR/CF/W') isn't computed yet. NOT touched
        // by the session-intensity dial — that only scales recommended zones.
        const hasTarget = p.targetCurve || p.targetPct !== null || p.targetKg !== null;
        const resolvedKg = hasTarget ? presetTargetKg(p, presetRefs, 1) : null;
        return (
          <Fragment key={p.id}>
          <div
            // #171: arming/disarming a preset is a selection, not a button.
            // Muted while locked (#298): this row is a div, so it cannot carry
            // the native `disabled` that `hapticForCandidate` keys off — without
            // this, a tap refused by the `locked` guard below would buzz exactly
            // like an accepted arm. A refused tap must not feel like an
            // accepted one.
            data-haptic={locked ? "off" : "light"}
            onClick={() => {
              if (locked) return;
              if (selected) localStorage.removeItem(SELECTED_KEY);
              else localStorage.setItem(SELECTED_KEY, p.id);
              onSelect(selected ? null : p);
            }}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 10,
              padding: "11px 14px",
              marginBottom: 8,
              background: "var(--canvas)",
              border: `1px solid ${selected ? "var(--success)" : "var(--card-border)"}`,
              borderRadius: 10,
              cursor: locked ? "default" : "pointer",
              opacity: locked ? 0.75 : 1,
              boxShadow: "var(--shadow-card)",
            }}
          >
            <div
              aria-hidden="true"
              style={{
                width: 14,
                height: 14,
                borderRadius: "50%",
                flexShrink: 0,
                border: `2px solid ${selected ? "var(--success)" : "var(--border)"}`,
                background: selected ? "var(--success)" : "transparent",
              }}
            />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
                <span
                  style={{
                    fontSize: "var(--t-base)",
                    color: "var(--ink)",
                    fontWeight: 600,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {p.name}
                </span>
                <QualityBadge holdS={p.holdS} kg={resolvedKg} refs={presetRefs} />
              </div>
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 2 }}>
                hold {fmt(p.holdS)} · {p.reps} reps · {p.sets} set{p.sets === 1 ? "" : "s"} · rest{" "}
                {fmt(p.restRepsS)}/{fmt(p.restSetsS)} · total{" "}
                {fmt(timelineDurationS(buildTimeline(p, { switchS: 3 })))}
                {p.targetCurve ? (
                  <span style={{ color: "var(--success)" }}>
                    {" "}
                    · auto CF @ {fmt(p.holdS)}
                    {resolvedKg !== null && ` · ${resolvedKg.toFixed(1)} kg`}
                  </span>
                ) : p.targetPct !== null ? (
                  <span style={{ color: "var(--success)" }}>
                    {" "}
                    · {p.targetPct}
                    {p.pctStep > 0 &&
                      `→${Math.min(150, p.targetPct + (p.sets - 1) * p.pctStep)}`}
                    % {p.pctBasis === "cf" ? "CF" : "PR"}
                    {resolvedKg !== null && ` · ${resolvedKg.toFixed(1)} kg`}
                  </span>
                ) : (
                  p.targetKg !== null && (
                    <span style={{ color: "var(--success)" }}> · {p.targetKg.toFixed(1)} kg</span>
                  )
                )}
                {p.alternateSides && (
                  <span style={{ color: "var(--warning)" }}> · L⇄R</span>
                )}
              </div>
            </div>
            <button
              className="del-btn"
              aria-label="Edit preset"
              style={{ fontSize: "var(--t-base)" }}
              disabled={locked}
              onClick={(e) => {
                e.stopPropagation();
                openEdit(p);
              }}
            >
              ✎
            </button>
            <button
              className="del-btn"
              style={{ marginLeft: 0 }}
              disabled={locked}
              onClick={(e) => {
                e.stopPropagation();
                setConfirmDelete(p);
              }}
            >
              ×
            </button>
          </div>
          {adding && editingId === p.id && renderForm()}
          </Fragment>
        );
      })}

      {/* New-preset form sits at the bottom; an edit form renders inline
          under its own row (see the map above). */}
      {adding && !editingId && renderForm()}
      {!adding && (
        <button className="btn-ghost" disabled={locked} onClick={() => setAdding(true)}>
          + New preset
        </button>
      )}
      {locked && (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 4 }}>
          Locked while measuring — applies to your next run.
        </div>
      )}

      {/* Delete-preset confirm (issue #143) */}
      {confirmDelete && (
        <ConfirmDialog
          title={`Delete preset '${confirmDelete.name}'?`}
          body="This can't be undone."
          confirmLabel="Delete"
          onConfirm={confirmRemove}
          onClose={() => setConfirmDelete(null)}
        />
      )}
    </div>
  );

  function renderForm() {
    return (
        <div className="card">
          <span className="field-label" style={{ marginTop: 0 }}>Name (optional)</span>
          <input
            className="field"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Repeaters 7:3"
          />
          <div style={{ display: "flex", gap: 8, marginTop: 12, flexWrap: "wrap" }}>
            <NumField label="Hold s" value={holdS} onChange={setHoldS} min={1} max={600} />
            <NumField label="Reps" value={reps} onChange={setReps} min={1} max={50} />
            <NumField label="Sets" value={sets} onChange={setSets} min={1} max={20} />
          </div>
          <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
            <NumField label="Rest / rep s" value={restRepsS} onChange={setRestRepsS} min={0} max={600} />
            <NumField label="Rest / set s" value={restSetsS} onChange={setRestSetsS} min={0} max={1200} />
          </div>
          {/* Target load — how the band on the live gauge is set. */}
          <span className="field-label">Target load</span>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {(
              [
                ["off", "None"],
                ["kg", "Fixed kg"],
                ["pct", "% of…"],
                ["curve", "Auto (curve)"],
              ] as const
            ).map(([m, label]) => (
              <button
                key={m}
                className="tag"
                onClick={() => setTargetMode(m)}
                style={{
                  background: targetMode === m ? "var(--primary)" : "var(--surface-1)",
                  color: targetMode === m ? "#ffffff" : "var(--ink-muted)",
                  border: `1px solid ${targetMode === m ? "var(--primary)" : "var(--border)"}`,
                  cursor: "pointer",
                  fontFamily: "Inter, sans-serif",
                }}
              >
                {label}
              </button>
            ))}
          </div>

          {targetMode === "kg" && (
            <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
              <NumField label="Target kg" value={targetKg} onChange={setTargetKg} min={1} max={200} />
            </div>
          )}

          {targetMode === "pct" && (
            <>
              {/* Reference: % of PR (max strength) or % of Critical Force (endurance) */}
              <div style={{ display: "flex", gap: 6, marginTop: 8 }}>
                {(
                  [
                    ["pr", "% of PR"],
                    ["cf", "% of Critical Force"],
                  ] as const
                ).map(([b, label]) => (
                  <button
                    key={b}
                    className="tag"
                    onClick={() => setPctBasis(b)}
                    style={{
                      background: pctBasis === b ? "var(--info)" : "var(--surface-1)",
                      color: pctBasis === b ? "#ffffff" : "var(--ink-muted)",
                      border: `1px solid ${pctBasis === b ? "var(--info)" : "var(--border)"}`,
                      cursor: "pointer",
                      fontFamily: "Inter, sans-serif",
                    }}
                  >
                    {label}
                  </button>
                ))}
              </div>
              <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
                <NumField
                  label={pctBasis === "pr" ? "% of PR" : "% of CF"}
                  value={targetPct}
                  onChange={setTargetPct}
                  min={1}
                  max={150}
                />
                <NumField label="+% / set" value={pctStep} onChange={setPctStep} min={0} max={50} />
              </div>
              <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 6, lineHeight: 1.5 }}>
                {pctBasis === "pr"
                  ? "% of your best recorded peak for the exercise (max-strength work)."
                  : "% of critical force — the sustainable-force asymptote of the curve (endurance work)."}
                {pctStep > 0 &&
                  ` Sets run ${targetPct}%${Array.from(
                    { length: Math.min(sets, 4) - 1 },
                    (_, i) => ` → ${Math.min(150, targetPct + (i + 1) * pctStep)}%`,
                  ).join("")}${sets > 4 ? " → …" : ""}.`}
              </div>
            </>
          )}

          {targetMode === "curve" && (
            <>
              <span className="field-label">Hold time — {holdS}s</span>
              <input
                type="range"
                min={3}
                max={240}
                value={holdS}
                onChange={(e) => setHoldS(Number(e.target.value))}
                style={{ width: "100%", accentColor: "var(--primary)" }}
              />
              <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 6, lineHeight: 1.5 }}>
                Smart target: the load auto-adjusts to the force you can sustain
                for a {holdS}s hold, read off this exercise's force curve
                (CF + W′/{holdS}s). Longer holds → lighter, more endurance-y load.
              </div>
            </>
          )}
          <label
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              marginTop: 12,
              fontSize: "var(--t-sm)",
              color: "var(--ink-muted)",
              cursor: "pointer",
            }}
          >
            <input
              type="checkbox"
              checked={alternateSides}
              onChange={(e) => setAlternateSides(e.target.checked)}
            />
            Alternate left ⇄ right each set (otherwise uses the selected side)
          </label>
          <div style={{ marginTop: 14 }}>
            <button className="btn-primary" disabled={saving} onClick={() => void save()}>
              {saving ? "Saving…" : editingId ? "Save Changes" : "Save Preset"}
            </button>
          </div>
          <div style={{ marginTop: 8 }}>
            <button
              className="btn-ghost"
              disabled={saving}
              onClick={() => {
                setAdding(false);
                setEditingId(null);
              }}
            >
              Cancel
            </button>
          </div>
        </div>
    );
  }
}
