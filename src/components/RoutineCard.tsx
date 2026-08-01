import { useEffect, useState } from "react";
import {
  deleteRoutinePreset,
  deleteSession,
  fetchRoutinePresets,
  insertRoutinePreset,
  insertSession,
  updateRoutinePreset,
} from "../lib/repo";
import { today } from "../lib/dates";
import { expandRoutine, routineDurationS } from "../lib/routine";
import { restoreAt } from "../lib/restoreAt";
import { captureHandledOperationalFailure } from "../lib/monitoring";
import {
  clearRoutineRun,
  loadRoutineRun,
  partialMinutes,
  shouldLog,
  type RoutineRunState,
} from "../lib/routineRun";
import type { PhaseId, RoutinePreset, RoutineStep } from "../types";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import ConfirmDialog from "./ConfirmDialog";
import NumInput from "./NumInput";
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
  const total = routineDurationS(expandRoutine(steps));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return s === 0 ? `${m}m` : `${m}m${s}s`;
}

/// Routine presets (Workout tab) — user-defined guided routines (warm-ups,
/// conditioning circuits, mobility flows). Same interaction model as the Force
/// tab's PresetManager: selectable rows, pencil edit, inline add form.
/// Selecting a row arms it; Start runs it in the fullscreen guided timer.
export default function RoutineCard({
  currentPhase,
  blockedReason = null,
  onRunningChange,
}: {
  currentPhase: PhaseId;
  /// Why a routine can't be started right now — a phone or watch workout is
  /// already running (#222). Null when free to start. Never blocks the
  /// auto-resume path: an interrupted routine still comes back on mount.
  blockedReason?: string | null;
  /// Reports the running flag up to WorkoutView so the phone-workout card can
  /// refuse to start a second timer (#222).
  onRunningChange?: (running: boolean) => void;
}) {
  const toast = useToast();
  const bumpRealtime = useRealtimeBump();
  const [presets, setPresets] = useState<RoutinePreset[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  // A routine left running when the app was last closed (SL-97). Read once
  // (lazy init — the sanctioned impure spot); consumed when its preset loads,
  // then cleared so a fresh Start doesn't resume a stale run.
  const [resumeRun, setResumeRun] = useState<RoutineRunState | null>(() =>
    loadRoutineRun(),
  );
  const [adding, setAdding] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [seeding, setSeeding] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [steps, setSteps] = useState<RoutineStep[]>([{ label: "", s: 60 }]);
  // Issue #143: gate routine delete behind a confirm dialog. Holds the
  // preset being confirmed (need its name for the dialog copy).
  const [confirmDelete, setConfirmDelete] = useState<RoutinePreset | null>(
    null,
  );

  /// Every write to `running` goes through here so WorkoutView sees it too
  /// (#222). Called from event handlers and async callbacks only — never from
  /// an effect body, per this codebase's react-compiler rules.
  function setRunningState(next: boolean) {
    setRunning(next);
    onRunningChange?.(next);
  }

  useEffect(() => {
    let alive = true;
    fetchRoutinePresets()
      .then((list) => {
        if (!alive) return;
        setPresets(list);
        // Auto-resume an interrupted run if its preset still exists (SL-97);
        // otherwise default-select the first preset and drop the stale run.
        const resume = resumeRun && list.some((p) => p.id === resumeRun.presetId);
        if (resume) {
          setSelectedId(resumeRun!.presetId);
          // Auto-resume is deliberately NOT guarded (#222): a routine that was
          // already in progress must come back, blocked-state or not.
          setRunningState(true);
        } else {
          setSelectedId(list[0]?.id ?? null);
          if (resumeRun) {
            clearRoutineRun();
            setResumeRun(null);
          }
        }
      })
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : "Failed to load routines"),
      );
    return () => {
      alive = false;
    };
    // Mount-only: resumeRun is read once at load; adding it would re-run.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const selected = presets.find((p) => p.id === selectedId) ?? presets[0] ?? null;

  /// Log a routine as a session (feeds ACWR + History). `undo` adds an Undo
  /// action to the toast — used for partial auto-saves on early exit (SL-97)
  /// since the user didn't explicitly choose to save.
  async function logRoutine(durationMin: number, note: string, undo = false) {
    try {
      const s = await insertSession({
        date: today(),
        type: "routine",
        duration: durationMin,
        rpe: 4,
        note,
        phase: currentPhase,
      });
      bumpRealtime();
      toast(
        `Routine logged · ${durationMin} min`,
        "success",
        undo
          ? {
              label: "Undo",
              onClick: () => {
                void (async () => {
                  await deleteSession(s.id);
                  bumpRealtime();
                })();
              },
            }
          : undefined,
      );
    } catch (e) {
      captureHandledOperationalFailure("session.insert", e, {
        automatic: true,
      });
      setError(e instanceof Error ? e.message : "Failed to log routine");
    }
  }

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
      toast(editingId ? "Routine updated" : "Routine saved");
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
    const index = presets.findIndex((p) => p.id === id);
    const removed = presets[index];
    if (!removed) return; // double-fire guard
    setPresets((list) => list.filter((p) => p.id !== id));
    if (selectedId === id) {
      setSelectedId(presets.filter((p) => p.id !== id)[0]?.id ?? null);
    }
    try {
      await deleteRoutinePreset(id);
      // Issue #143: plain confirmation toast — no Undo (routine presets
      // aren't soft-deleted, unlike sessions/recordings).
      toast("Routine deleted");
    } catch {
      // Rollback: put it back where it was (issue #215/#166 — the same
      // swallowed-failure bug PresetManager.tsx fixed via restoreAt).
      setPresets((list) => restoreAt(list, removed, index));
      setSelectedId((cur) => cur ?? removed.id);
      toast("Couldn't delete routine — restored", "error");
    }
  }

  // Issue #143: called after the confirm dialog is accepted.
  function confirmRemove() {
    if (!confirmDelete) return;
    const id = confirmDelete.id;
    setConfirmDelete(null);
    void remove(id);
  }

  return (
    <div className="card" style={{ marginTop: 10 }}>
      <div className="card-title" style={{ marginBottom: 8 }}>
        Routines
      </div>
      {error && (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginBottom: 8 }}>{error}</div>
      )}

      {presets.length === 0 && !adding && (
        <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-faint)", marginBottom: 12, lineHeight: 1.5 }}>
          Build a timed step routine — a warm-up, conditioning circuit or
          mobility flow — and run it as a guided fullscreen timer.
        </div>
      )}

      {presets.map((p) => {
        const isSelected = p.id === selectedId;
        return (
          <div
            key={p.id}
            // #171: selecting a preset is a selection, not a button — opt
            // into the delegated tick. The row's own Edit/Delete buttons sit
            // inside it and win the nearest-match, so they tick once, not twice.
            data-haptic="light"
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
              <div style={{ fontSize: "var(--t-base)", color: "var(--ink)", fontWeight: 600 }}>
                {p.name}
              </div>
              <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 2 }}>
                <span style={{ color: "var(--info)", fontWeight: 600 }}>
                  {p.steps.length} step{p.steps.length === 1 ? "" : "s"}
                </span>{" "}
                · <span style={{ color: "var(--info)", fontWeight: 600 }}>{fmtTotal(p.steps)}</span>
                {" · "}
                {p.steps
                  .map((st) => ((st.reps ?? 1) > 1 ? `${st.label} ×${st.reps}` : st.label))
                  .join(" → ")}
              </div>
            </div>
            <button
              className="del-btn"
              aria-label="Edit routine"
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
                setConfirmDelete(p);
              }}
            >
              ×
            </button>
          </div>
        );
      })}

      {/* Delete-routine confirm (issue #143) */}
      {confirmDelete && (
        <ConfirmDialog
          title={`Delete routine '${confirmDelete.name}'?`}
          body="This can't be undone."
          confirmLabel="Delete"
          onConfirm={confirmRemove}
          onClose={() => setConfirmDelete(null)}
        />
      )}

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
            <div key={i} style={{ marginBottom: 10 }}>
              <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
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
              {/* duration ×reps + rest between reps (SL-83) */}
              <div style={{ display: "flex", gap: 6, alignItems: "center", marginTop: 6 }}>
                <NumInput
                  value={st.s}
                  min={5}
                  max={1800}
                  onCommit={(v) =>
                    setSteps((list) =>
                      list.map((x, j) => (j === i ? { ...x, s: v } : x)),
                    )
                  }
                  style={{ width: 54, flexShrink: 0, textAlign: "center", fontSize: "var(--t-sm)", padding: "10px 6px" }}
                />
                <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>s</span>
                <span style={{ fontSize: "var(--t-sm)", color: "var(--ink-faint)" }}>×</span>
                <NumInput
                  value={st.reps ?? 1}
                  min={1}
                  max={50}
                  onCommit={(v) =>
                    setSteps((list) =>
                      list.map((x, j) => (j === i ? { ...x, reps: v } : x)),
                    )
                  }
                  style={{ width: 44, flexShrink: 0, textAlign: "center", fontSize: "var(--t-sm)", padding: "10px 6px" }}
                />
                <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>reps</span>
                <NumInput
                  value={st.restS ?? 0}
                  min={0}
                  max={600}
                  onCommit={(v) =>
                    setSteps((list) =>
                      list.map((x, j) => (j === i ? { ...x, restS: v } : x)),
                    )
                  }
                  style={{ width: 54, flexShrink: 0, textAlign: "center", fontSize: "var(--t-sm)", padding: "10px 6px" }}
                />
                <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)" }}>rest s</span>
              </div>
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
          <button
            className="btn-primary"
            style={blockedReason ? { flex: 1, opacity: 0.5 } : { flex: 1 }}
            // #222: one timer at a time. Kept clickable while blocked (rather
            // than `disabled`) so the tap names the reason instead of doing
            // nothing — the aria-disabled + dimming carry the "off" state.
            aria-disabled={blockedReason ? true : undefined}
            onClick={() => {
              if (blockedReason) {
                toast(blockedReason, "info");
                return;
              }
              // A fresh Start must not resume a stale saved run.
              if (resumeRun) {
                clearRoutineRun();
                setResumeRun(null);
              }
              setRunningState(true);
            }}
          >
            Start Routine
          </button>
          <button
            className="btn-ghost"
            style={
              blockedReason
                ? { width: "auto", flexShrink: 0, whiteSpace: "nowrap", opacity: 0.5 }
                : { width: "auto", flexShrink: 0, whiteSpace: "nowrap" }
            }
            aria-disabled={blockedReason ? true : undefined}
            onClick={() => {
              if (blockedReason) {
                toast(blockedReason, "info");
                return;
              }
              setAdding(true);
            }}
          >
            + New Routine
          </button>
        </div>
      ) : (
        <div style={{ display: "flex", gap: 8, alignItems: "stretch" }}>
          <button
            className="btn-primary"
            style={blockedReason ? { flex: 1, opacity: 0.5 } : { flex: 1 }}
            aria-disabled={blockedReason ? true : undefined}
            onClick={() => {
              if (blockedReason) {
                toast(blockedReason, "info");
                return;
              }
              setAdding(true);
            }}
          >
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
          presetId={selected.id}
          steps={selected.steps}
          initial={
            resumeRun && resumeRun.presetId === selected.id
              ? resumeRun
              : undefined
          }
          onClose={() => {
            setResumeRun(null);
            setRunningState(false);
          }}
          onExitEarly={(elapsed) => {
            setResumeRun(null);
            setRunningState(false);
            // Left before finishing — log the partial time (SL-97) unless it
            // barely ran, with an Undo since it wasn't an explicit save.
            if (!shouldLog(elapsed)) return;
            void logRoutine(partialMinutes(elapsed), `${selected.name} (partial)`, true);
          }}
          onFinish={(durationMin) => {
            // A completed routine IS a workout (SL-83) — log it so it feeds
            // ACWR and shows in History. RPE defaults; edit in History.
            setResumeRun(null);
            void logRoutine(durationMin, selected.name);
          }}
        />
      )}
    </div>
  );
}
