import { useEffect, useState } from "react";
import { deletePreset, fetchPresets, insertPreset } from "../lib/repo";
import { buildTimeline, timelineDurationS } from "../lib/protocol";
import type { TindeqPreset } from "../types";

interface Props {
  selectedId: string | null;
  onSelect: (preset: TindeqPreset | null) => void;
}

function fmt(sec: number): string {
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s === 0 ? `${m}m` : `${m}m${s}s`;
}

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
      <span style={{ fontSize: 9, color: "var(--ink-muted)", textTransform: "uppercase", letterSpacing: "0.06em" }}>
        {label}
      </span>
      <input
        className="field"
        type="number"
        inputMode="numeric"
        value={value}
        min={min}
        max={max}
        onChange={(e) => {
          const v = Number(e.target.value);
          if (Number.isFinite(v)) onChange(Math.max(min, Math.min(max, v)));
        }}
        style={{ padding: "9px 10px", fontSize: 14 }}
      />
    </label>
  );
}

/// Hang-protocol presets (hold / reps / sets / rests). Saved to Supabase;
/// selecting one arms the guided timer in the fullscreen gauge.
export default function PresetManager({ selectedId, onSelect }: Props) {
  const [presets, setPresets] = useState<TindeqPreset[]>([]);
  const [adding, setAdding] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [holdS, setHoldS] = useState(7);
  const [reps, setReps] = useState(6);
  const [sets, setSets] = useState(3);
  const [restRepsS, setRestRepsS] = useState(3);
  const [restSetsS, setRestSetsS] = useState(180);
  const [targetKg, setTargetKg] = useState(0); // 0 = no target
  const [alternateSides, setAlternateSides] = useState(false);

  useEffect(() => {
    let alive = true;
    fetchPresets()
      .then((list) => alive && setPresets(list))
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : "Failed to load presets"),
      );
    return () => {
      alive = false;
    };
  }, []);

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const saved = await insertPreset({
        name: name.trim() || `${holdS}s × ${reps} × ${sets}`,
        holdS,
        reps,
        sets,
        restRepsS,
        restSetsS,
        targetKg: targetKg > 0 ? targetKg : null,
        alternateSides,
      });
      setPresets((list) => [saved, ...list]);
      setAdding(false);
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
        <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 8 }}>{error}</div>
      )}

      {presets.length === 0 && !adding && (
        <div style={{ fontSize: 12, color: "var(--ink-faint)", marginBottom: 10, lineHeight: 1.5 }}>
          Save a hang protocol (hold · reps · sets · rest) — selecting one runs
          a guided HOLD/REST timer on the gauge.
        </div>
      )}

      {presets.map((p) => {
        const selected = p.id === selectedId;
        return (
          <div
            key={p.id}
            onClick={() => onSelect(selected ? null : p)}
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
              <div style={{ fontSize: 13, color: "var(--ink)", fontWeight: 600 }}>
                {p.name}
              </div>
              <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 2 }}>
                hold {fmt(p.holdS)} · {p.reps} reps · {p.sets} set{p.sets === 1 ? "" : "s"} · rest{" "}
                {fmt(p.restRepsS)}/{fmt(p.restSetsS)} · total{" "}
                {fmt(timelineDurationS(buildTimeline(p, { switchS: 3 })))}
                {p.targetKg !== null && (
                  <span style={{ color: "var(--success)" }}> · {p.targetKg.toFixed(1)} kg</span>
                )}
                {p.alternateSides && (
                  <span style={{ color: "var(--warning)" }}> · L⇄R</span>
                )}
              </div>
            </div>
            <button
              className="del-btn"
              onClick={(e) => {
                e.stopPropagation();
                void remove(p.id);
              }}
            >
              ×
            </button>
          </div>
        );
      })}

      {adding ? (
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
            <NumField label="Target kg (0 = off)" value={targetKg} onChange={setTargetKg} min={0} max={200} />
          </div>
          <label
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              marginTop: 12,
              fontSize: 12,
              color: "var(--ink-muted)",
              cursor: "pointer",
            }}
          >
            <input
              type="checkbox"
              checked={alternateSides}
              onChange={(e) => setAlternateSides(e.target.checked)}
            />
            Alternate left ⇄ right each rep (otherwise uses the selected side)
          </label>
          <div style={{ marginTop: 14 }}>
            <button className="btn-primary" disabled={saving} onClick={() => void save()}>
              {saving ? "Saving…" : "Save Preset"}
            </button>
          </div>
          <div style={{ marginTop: 8 }}>
            <button className="btn-ghost" disabled={saving} onClick={() => setAdding(false)}>
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <button className="btn-ghost" onClick={() => setAdding(true)}>
          + New preset
        </button>
      )}
    </div>
  );
}
