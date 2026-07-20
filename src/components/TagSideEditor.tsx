import { useState } from "react";
import BoxChip from "./BoxChip";
import type { TindeqSide } from "../types";

const SIDE_OPTIONS: { value: TindeqSide; label: string }[] = [
  { value: "", label: "—" },
  { value: "left", label: "Left" },
  { value: "right", label: "Right" },
  { value: "both", label: "Both" },
];

/// Shared exercise setup (SL-82: no dropdowns): a LARGE current-exercise box,
/// every tag as a selectable box chip with a "+" chip to add a new tag, and
/// the side as box chips too. Set once, tweak between reps.
export default function TagSideEditor({
  tag,
  side,
  allTags,
  onTag,
  onSide,
}: {
  tag: string;
  side: TindeqSide;
  allTags: string[];
  onTag: (t: string) => void;
  onSide: (s: TindeqSide) => void;
}) {
  const [addingTag, setAddingTag] = useState(false);
  const [draft, setDraft] = useState("");
  const trimmed = tag.trim();
  // A brand-new tag (no recordings yet) still gets a chip so the selection
  // is visible and toggleable.
  const tags =
    !trimmed || allTags.includes(trimmed) ? allTags : [trimmed, ...allTags];

  function commitDraft() {
    const t = draft.trim();
    if (t) onTag(t);
    setDraft("");
    setAddingTag(false);
  }

  const sideLabel = SIDE_OPTIONS.find((o) => o.value === side)?.label ?? "—";

  return (
    <div>
      {/* Current exercise — the big box */}
      <div
        style={{
          padding: "13px 16px",
          borderRadius: 12,
          background: "var(--surface-1)",
          border: "1px solid var(--border)",
          marginBottom: 10,
        }}
      >
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontSize: 22,
            fontWeight: 800,
            letterSpacing: "-0.01em",
            color: trimmed ? "var(--ink)" : "var(--ink-faint)",
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {trimmed || "Pick an exercise"}
        </div>
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginTop: 2 }}>
          Side: <span style={{ fontWeight: 700, color: "var(--ink)" }}>{sideLabel}</span>
        </div>
      </div>

      {/* Tag chips + "+" to add a new one */}
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
        {tags.map((t) => (
          <BoxChip
            key={t}
            label={t}
            active={t === trimmed}
            onClick={() => onTag(t === trimmed ? "" : t)}
          />
        ))}
        <BoxChip
          label="＋"
          active={addingTag}
          onClick={() => setAddingTag((v) => !v)}
        />
      </div>
      {addingTag && (
        <div style={{ display: "flex", gap: 6, marginTop: 8 }}>
          <input
            className="field"
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") commitDraft();
            }}
            placeholder="New exercise — e.g. FDP"
            style={{ flex: 1, minWidth: 0 }}
          />
          <button
            className="btn-primary"
            style={{ width: "auto", flexShrink: 0, padding: "0 16px" }}
            disabled={!draft.trim()}
            onClick={commitDraft}
          >
            Add
          </button>
        </div>
      )}

      {/* Side — box chips, no dropdown */}
      <span className="field-label">Side</span>
      <div style={{ display: "flex", gap: 6 }}>
        {SIDE_OPTIONS.map((o) => (
          <BoxChip
            key={o.value}
            label={o.label}
            active={side === o.value}
            onClick={() => onSide(o.value)}
            style={{ flex: 1 }}
          />
        ))}
      </div>
    </div>
  );
}
