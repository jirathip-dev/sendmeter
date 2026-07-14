import { useId } from "react";
import type { TindeqSide } from "../types";

const SIDE_OPTIONS: { value: TindeqSide; label: string }[] = [
  { value: "", label: "—" },
  { value: "left", label: "Left" },
  { value: "right", label: "Right" },
  { value: "both", label: "Both" },
];

/// Shared exercise setup: used before starting a measure AND in the save
/// card, editing the same state — set once, tweak between reps.
export default function TagSideEditor({
  tag,
  side,
  recentTags,
  allTags,
  onTag,
  onSide,
}: {
  tag: string;
  side: TindeqSide;
  recentTags: string[];
  allTags: string[];
  onTag: (t: string) => void;
  onSide: (s: TindeqSide) => void;
}) {
  const listId = useId();
  return (
    <div>
      <div className="grid-2" style={{ gap: 10 }}>
        <div>
          <span className="field-label" style={{ marginTop: 0 }}>
            Exercise tag
          </span>
          <input
            className="field"
            value={tag}
            onChange={(e) => onTag(e.target.value)}
            placeholder="e.g. FDP"
            list={listId}
          />
          <datalist id={listId}>
            {allTags.map((t) => (
              <option key={t} value={t} />
            ))}
          </datalist>
        </div>
        <div>
          <span className="field-label" style={{ marginTop: 0 }}>
            Side
          </span>
          <select
            className="field"
            value={side}
            onChange={(e) => onSide(e.target.value as TindeqSide)}
          >
            {SIDE_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </div>
      </div>
      {recentTags.length > 0 && (
        <div
          style={{ display: "flex", gap: 5, flexWrap: "wrap", marginTop: 7 }}
        >
          {recentTags.map((t) => (
            <button
              key={t}
              className="tag"
              onClick={() => onTag(tag === t ? "" : t)}
              style={{
                background: tag === t ? "var(--info)" : "var(--surface-1)",
                color: tag === t ? "#ffffff" : "var(--ink-muted)",
                border: `1px solid ${tag === t ? "var(--info)" : "var(--border)"}`,
                cursor: "pointer",
                fontFamily: "Inter, sans-serif",
              }}
            >
              {t}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
