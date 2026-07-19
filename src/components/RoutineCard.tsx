import { useEffect, useState } from "react";
import {
  deleteRoutinePreset,
  fetchRoutinePresets,
  insertRoutinePreset,
  updateRoutinePreset,
} from "../lib/repo";
import type { RoutinePreset, RoutineStep } from "../types";
import RoutineFullscreen from "./RoutineFullscreen";

/// Seeded on demand ("Add example") as a real, editable/deletable preset — a
/// starting point, not a fixed default. Shows how a routine is structured.
const EXAMPLE_ROUTINE: Omit<RoutinePreset, "id"> = {
  name: "Climbing warm-up",
  steps: [
    { label: "Pulse raiser", detail: "Jog, jacks or rower — break a light sweat", s: 120 },
    { label: "Joint circles", detail: "Wrists, elbows, shoulders, hips", s: 90 },
    { label: "Band / scap pulls", detail: "Shoulder activation, slow reps", s: 90 },
    { label: "Easy climbing", detail: "Big holds, slow traverses, perfect feet", s: 240 },
    { label: "Progressive hangs", detail: "Bodyweight — open hand, then half crimp", s: 120 },
    { label: "Ramp-up boulders", detail: "3–4 problems, building toward session grade", s: 180 },
  ],
};

function fmtTotal(steps: RoutineStep[]): string {
  const total = steps.reduce((sum, st) => sum + st.s, 0);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return s === 0 ? `${m}m` : `${m}m${s}s`;
}

/// Routine presets (Workout tab) — user-defined guided routines (warm-ups,
/// conditioning circuits, mobility flows). Same interaction model as the Force
/// tab's PresetManager: selectable rows, pencil edit, inline add form.
/// Selecting a row arms it; Start runs it in the fullscreen guided timer.
export default function RoutineCard() {
  const [presets, setPresets] = useState<RoutinePreset[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [adding, setAdding] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [seeding, setSeeding] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [steps, setSteps] = useState<RoutineStep[]>([{ label: "", s: 60 }]);

  useEffect(() => {
    let alive = true;
    fetchRoutinePresets()
      .then((list) => {
        if (!alive) return;
        setPresets(list);
        setSelectedId(list[0]?.id ?? null);
      })
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : "Failed to load routines"),
      );
    return () => {
      alive = false;
    };
  }, []);

  const selected = presets.find((p) => p.id === selectedId) ?? presets[0] ?? null;

  function openEdit(p: RoutinePreset) {
    setEditingId(p.id);
    setName(p.name);
    setSteps(p.steps.map((st) => ({ ...st })));
    setAdding(true);
  }

  function closeForm() {
    setAdding(false);
    setEditingId(null);
    setName("");
    setSteps([{ label: "", s: 60 }]);
  }

  async function save() {
    const cleaned = steps
      .map((st) => ({ ...st, label: st.label.trim() }))
      .filter((st) => st.label && st.s > 0);
    if (cleaned.length === 0) {
      setError("Add at least one step with a name and duration.");
      return;
    }
    setSaving(true);
    setError(null);
    const fields = { name: name.trim() || `${cleaned.length}-step routine`, steps: cleaned };
    try {
      if (editingId) {
        const saved = await updateRoutinePreset(editingId, fields);
        setPresets((list) => list.map((p) => (p.id === editingId ? saved : p)));
      } else {
        const saved = await insertRoutinePreset(fields);
        setPresets((list) => [saved, ...list]);
        setSelectedId(saved.id);
      }
      closeForm();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save routine");
    } finally {
      setSaving(false);
    }
  }

  async function addExample() {
    setSeeding(true);
    setError(null);
    try {
      const saved = await insertRoutinePreset(EXAMPLE_ROUTINE);
      setPresets((list) => [saved, ...list]);
      setSelectedId(saved.id);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to add example");
    } finally {
      setSeeding(false);
    }
  }

  async function remove(id: string) {
    setPresets((list) => {
      const next = list.filter((p) => p.id !== id);
      if (selectedId === id) setSelectedId(next[0]?.id ?? null);
      return next;
    });
    try {
      await deleteRoutinePreset(id);
    } catch {
      // no realtime/refetch wired for presets; a failed delete resurfaces on
      // next visit — acceptable (same tradeoff as tindeq PresetManager)
    }
  }

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="card-title" style={{ marginBottom: 8 }}>
        Routines
      </div>
      {error && (
        <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 8 }}>{error}</div>
      )}

      {presets.length === 0 && !adding && (
        <div style={{ fontSize: 12, color: "var(--ink-faint)", marginBottom: 12, lineHeight: 1.5 }}>
          Build a timed step routine — a warm-up, conditioning circuit or
          mobility flow — and run it as a guided fullscreen timer.
        </div>
      )}

      {presets.map((p) => {
        const isSelected = p.id === selectedId;
        return (
          <div
            key={p.id}
            onClick={() => setSelectedId(p.id)}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 10,
              padding: "11px 14px",
              marginBottom: 8,
              background: "var(--canvas)",
              border: `1px solid ${isSelected ? "var(--success)" : "var(--card-border)"}`,
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
                border: `2px solid ${isSelected ? "var(--success)" : "var(--border)"}`,
                background: isSelected ? "var(--success)" : "transparent",
              }}
            />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, color: "var(--ink)", fontWeight: 600 }}>
                {p.name}
              </div>
              <div style={{ fontSize: 11, color: "var(--ink-muted)", marginTop: 2 }}>
                <span style={{ color: "var(--info)", fontWeight: 600 }}>
                  {p.steps.length} step{p.steps.length === 1 ? "" : "s"}
                </span>{" "}
                · <span style={{ color: "var(--info)", fontWeight: 600 }}>{fmtTotal(p.steps)}</span>
                {" · "}
                {p.steps.map((st) => st.label).join(" → ")}
              </div>
            </div>
            <button
              className="del-btn"
              aria-label="Edit routine"
              style={{ fontSize: 13 }}
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
        );
      })}

      {adding ? (
        <div style={{ marginTop: 4 }}>
          <span className="field-label" style={{ marginTop: 0 }}>Name (optional)</span>
          <input
            className="field"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Gym day warm-up"
          />
          <span className="field-label">Steps</span>
          {steps.map((st, i) => (
            <div key={i} style={{ display: "flex", gap: 6, marginBottom: 6, alignItems: "center" }}>
              <input
                className="field"
                value={st.label}
                placeholder={`Step ${i + 1} — e.g. Easy traversing`}
                onChange={(e) =>
                  setSteps((list) =>
                    list.map((x, j) => (j === i ? { ...x, label: e.target.value } : x)),
                  )
                }
                style={{ flex: 1, minWidth: 0 }}
              />
              <input
                className="field"
                type="number"
                inputMode="numeric"
                min={5}
                max={1800}
                value={st.s}
                onChange={(e) => {
                  const v = Number(e.target.value);
                  if (!Number.isFinite(v)) return;
                  const clamped = Math.max(0, Math.min(1800, v));
                  if (e.target.value !== String(clamped)) e.target.value = String(clamped);
                  setSteps((list) =>
                    list.map((x, j) => (j === i ? { ...x, s: clamped } : x)),
                  );
                }}
                style={{ width: 60, flexShrink: 0, textAlign: "center" }}
              />
              <span style={{ fontSize: 10, color: "var(--ink-faint)" }}>s</span>
              <button
                className="del-btn"
                aria-label="Remove step"
                disabled={steps.length === 1}
                style={{ opacity: steps.length === 1 ? 0.3 : 1 }}
                onClick={() => setSteps((list) => list.filter((_, j) => j !== i))}
              >
                ×
              </button>
            </div>
          ))}
          <button
            className="btn-ghost"
            style={{ marginBottom: 10 }}
            onClick={() => setSteps((list) => [...list, { label: "", s: 60 }])}
          >
            + Add Step
          </button>
          <button className="btn-primary" disabled={saving} onClick={() => void save()}>
            {saving ? "Saving…" : editingId ? "Save Changes" : "Save Routine"}
          </button>
          <div style={{ marginTop: 8 }}>
            <button className="btn-ghost" disabled={saving} onClick={closeForm}>
              Cancel
            </button>
          </div>
        </div>
      ) : selected ? (
        <div style={{ display: "flex", gap: 8, alignItems: "stretch" }}>
          <button className="btn-primary" style={{ flex: 1 }} onClick={() => setRunning(true)}>
            Start Routine
          </button>
          <button
            className="btn-ghost"
            style={{ width: "auto", flexShrink: 0, whiteSpace: "nowrap" }}
            onClick={() => setAdding(true)}
          >
            + New Routine
          </button>
        </div>
      ) : (
        <div style={{ display: "flex", gap: 8, alignItems: "stretch" }}>
          <button className="btn-primary" style={{ flex: 1 }} onClick={() => setAdding(true)}>
            + New Routine
          </button>
          <button
            className="btn-ghost"
            style={{ width: "auto", flexShrink: 0, whiteSpace: "nowrap" }}
            disabled={seeding}
            onClick={() => void addExample()}
          >
            {seeding ? "Adding…" : "Add Example"}
          </button>
        </div>
      )}

      {running && selected && (
        <RoutineFullscreen
          name={selected.name}
          steps={selected.steps}
          onClose={() => setRunning(false)}
        />
      )}
    </div>
  );
}
