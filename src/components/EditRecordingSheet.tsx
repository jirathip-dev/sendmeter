import { useState } from "react";
import { updateRecordingMeta } from "../lib/repo";
import type { TindeqRecordingMeta, TindeqSide } from "../types";
import Sheet from "./Sheet";

interface Props {
  rec: TindeqRecordingMeta;
  /// Existing exercise tags, for quick-pick chips (avoid re-typing).
  recentTags: string[];
  onSaved: (rec: TindeqRecordingMeta) => void;
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
export default function EditRecordingSheet({ rec, recentTags, onSaved, onClose }: Props) {
  const [tag, setTag] = useState(rec.tag);
  const [side, setSide] = useState<TindeqSide>(rec.side);
  const [note, setNote] = useState(rec.note);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const saved = await updateRecordingMeta(rec.id, {
        tag: tag.trim(),
        side,
        note: note.trim(),
      });
      onSaved(saved);
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Sheet onClose={onClose}>
      <div style={{ fontFamily: "Inter, sans-serif", fontSize: "var(--t-xl)", fontWeight: 800, marginBottom: 2 }}>
        Edit recording
      </div>
      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 4 }}>
        {rec.peakKg.toFixed(1)} kg peak · {(rec.durationMs / 1000).toFixed(1)}s
      </div>

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
              onClick={() => setTag(t)}
              style={{
                padding: "4px 10px",
                borderRadius: 999,
                fontSize: "var(--t-xs)",
                fontWeight: 600,
                cursor: "pointer",
                border: `1px solid ${tag === t ? "var(--info)" : "var(--border)"}`,
                background: tag === t ? "rgba(123,131,235,0.12)" : "transparent",
                color: tag === t ? "var(--ink)" : "var(--ink-muted)",
              }}
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
            onClick={() => setSide(s.value)}
            style={{
              flex: 1,
              padding: "9px 0",
              borderRadius: 8,
              fontSize: "var(--t-sm)",
              fontWeight: 600,
              cursor: "pointer",
              border: `1px solid ${side === s.value ? "var(--warning)" : "var(--border)"}`,
              background: side === s.value ? "rgba(221,177,58,0.12)" : "transparent",
              color: side === s.value ? "var(--ink)" : "var(--ink-muted)",
            }}
          >
            {s.label}
          </button>
        ))}
      </div>

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
