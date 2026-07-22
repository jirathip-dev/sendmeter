import { Fragment, useEffect, useState } from "react";
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
import NumInput from "./NumInput";
import type { TindeqPreset } from "../types";

interface Props {
  selectedId: string | null;
  onSelect: (preset: TindeqPreset | null) => void;
  /// Force references for the active exercise, so each row can show the load
  /// its %/curve target resolves to right now.
  presetRefs: PresetRefs;
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

/// Selected-protocol persistence (SL-76): ForceView unmounts on tab switch and
/// its preset state dies with it, so the armed protocol vanished every time
/// you peeked at another tab. Remember the id and re-arm on mount.
const SELECTED_KEY = "sendmeter:force-preset";

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
export default function PresetManager({ selectedId, onSelect, presetRefs }: Props) {
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

  useEffect(() => {
    let alive = true;
    fetchPresets()
      .then((list) => {
        if (!alive) return;
        setPresets(list);
        // Re-arm the previously selected protocol (survives tab switches).
        const savedId = localStorage.getItem(SELECTED_KEY);
        if (savedId && selectedId === null) {
          const saved = list.find((p) => p.id === savedId);
          if (saved) onSelect(saved);
        }
      })
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : "Failed to load presets"),
      );
    return () => {
      alive = false;
    };
    // Restore uses mount-time selection only; re-running on selection change
    // would re-arm a deliberately deselected preset.
    // eslint-disable-next-line react-hooks/exhaustive-deps
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
    setPresets((list) => list.filter((p) => p.id !== id));
    if (selectedId === id) onSelect(null);
    if (localStorage.getItem(SELECTED_KEY) === id) localStorage.removeItem(SELECTED_KEY);
    toast("Preset deleted");
    try {
      await deletePreset(id);
    } catch {
      // realtime/refetch isn't wired for presets; a failed delete resurfaces
      // on next visit — acceptable for v1
    }
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
            onClick={() => {
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
              cursor: "pointer",
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
              onClick={(e) => {
                e.stopPropagation();
                void remove(p.id);
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
        <button className="btn-ghost" onClick={() => setAdding(true)}>
          + New preset
        </button>
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
