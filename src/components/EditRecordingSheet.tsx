import { useState } from "react";
import { updateRecordingMeta, updateRecordingsMeta } from "../lib/repo";
import type { TindeqRecordingMeta, TindeqSide } from "../types";
import Sheet from "./Sheet";

/// How far an edit reaches (SL-79): just this rep, every rep of its set, or
/// every rep of the whole protocol run.
type EditScope = "rep" | "set" | "run";

interface Props {
  rec: TindeqRecordingMeta;
  /// Recordings sharing this rec's protocolRunId (including rec itself) —
  /// enables set/run bulk edits. Empty for free holds.
  runSiblings: TindeqRecordingMeta[];
  /// Existing exercise tags, for quick-pick chips (avoid re-typing).
  recentTags: string[];
  onSaved: (recs: TindeqRecordingMeta[]) => void;
  onClose: () => void;
}

const SIDES: { value: TindeqSide; label: string }[] = [
  { value: "", label: "—" },
  { value: "left", label: "Left" },
  { value: "right", label: "Right" },
  { value: "both", label: "Both" },
];

/// Fix a recording's tag / side / note after the fact — the common case is
/// forgetting to switch the side or set the tag before a rep (SL-58).
export default function EditRecordingSheet({
  rec,
  runSiblings,
  recentTags,
  onSaved,
  onClose,
}: Props) {
  const [tag, setTag] = useState(rec.tag);
  const [side, setSide] = useState<TindeqSide>(rec.side);
  const [note, setNote] = useState(rec.note);
  const [scope, setScope] = useState<EditScope>("rep");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const setSiblings = runSiblings.filter(
    (r) => rec.setNo !== null && r.setNo === rec.setNo,
  );
  const scopeIds: Record<EditScope, string[]> = {
    rep: [rec.id],
    set: setSiblings.map((r) => r.id),
    run: runSiblings.map((r) => r.id),
  };

  async function save() {
    setSaving(true);
    setError(null);
    const patch = { tag: tag.trim(), side, note: note.trim() };
    try {
      const ids = scopeIds[scope];
      const saved =
        ids.length > 1
          ? await updateRecordingsMeta(ids, patch)
          : [await updateRecordingMeta(rec.id, patch)];
      onSaved(saved);
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Sheet
      title="Edit recording"
      subtitle={
        rec.source === "manual"
          ? `${rec.externalLoadKg?.toFixed(1)} kg external · ${((rec.actualDurationMs ?? rec.durationMs) / 1000).toFixed(1)}s actual${rec.plannedDurationMs != null ? ` / ${(rec.plannedDurationMs / 1000).toFixed(1)}s planned` : ""}${rec.outcome ? ` · ${rec.outcome.replace("_", " ")}` : ""}`
          : `${rec.peakKg?.toFixed(1)} kg peak · ${(rec.durationMs / 1000).toFixed(1)}s`
      }
      onClose={onClose}
    >
      <span className="field-label">Exercise tag</span>
      <input
        className="field"
        value={tag}
        onChange={(e) => setTag(e.target.value)}
        placeholder="e.g. FDP"
      />
      {recentTags.length > 0 && (
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 8 }}>
          {recentTags.map((t) => (
            <button
              key={t}
              className="recording-tag-option"
              data-selected={tag === t ? "true" : "false"}
              onClick={() => setTag(t)}
            >
              {t}
            </button>
          ))}
        </div>
      )}

      <span className="field-label">Side</span>
      <div style={{ display: "flex", gap: 6 }}>
        {SIDES.map((s) => (
          <button
            key={s.value}
            className="recording-side-option"
            data-selected={side === s.value ? "true" : "false"}
            onClick={() => setSide(s.value)}
          >
            {s.label}
          </button>
        ))}
      </div>

      {/* Bulk scope — only for guided-protocol reps (SL-79) */}
      {runSiblings.length > 1 && (
        <>
          <span className="field-label">Apply to</span>
          <div style={{ display: "flex", gap: 6 }}>
            {(
              [
                ["rep", "This rep"],
                ["set", `Set ${rec.setNo ?? "?"} (${setSiblings.length})`],
                ["run", `Whole run (${runSiblings.length})`],
              ] as const
            ).map(([v, label]) => (
              <button
                key={v}
                className="recording-scope-option"
                data-selected={scope === v ? "true" : "false"}
                onClick={() => setScope(v)}
              >
                {label}
              </button>
            ))}
          </div>
        </>
      )}

      <span className="field-label">Note (optional)</span>
      <input
        className="field"
        value={note}
        onChange={(e) => setNote(e.target.value)}
        placeholder="Felt tweaky, half crimp…"
      />

      {error && (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 10 }}>{error}</div>
      )}

      <div style={{ marginTop: 16 }}>
        <button className="btn-primary" disabled={saving} onClick={() => void save()}>
          {saving ? "Saving…" : "Save"}
        </button>
      </div>
      <div style={{ marginTop: 8 }}>
        <button className="btn-ghost" disabled={saving} onClick={onClose}>
          Cancel
        </button>
      </div>
    </Sheet>
  );
}
