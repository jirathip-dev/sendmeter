import { useState, type CSSProperties } from "react";

/// Numeric input that lets you TYPE freely — including clearing the field and
/// intermediate values — and clamps only when you leave it (blur/Enter).
/// Clamping every keystroke made values like 180 unreachable: deleting down to
/// "" snapped to the min and the caret fought you (SL-77). Parent state only
/// ever sees valid clamped numbers.
export default function NumInput({
  value,
  onCommit,
  min,
  max,
  style,
}: {
  value: number;
  onCommit: (v: number) => void;
  min: number;
  max: number;
  style?: CSSProperties;
}) {
  const [draft, setDraft] = useState<string | null>(null);

  function commit(raw: string) {
    const v = Number(raw);
    onCommit(
      Number.isFinite(v) && raw.trim() !== ""
        ? Math.max(min, Math.min(max, v))
        : value,
    );
    setDraft(null);
  }

  return (
    <input
      className="field"
      type="number"
      inputMode="numeric"
      value={draft ?? String(value)}
      min={min}
      max={max}
      onFocus={() => setDraft(String(value))}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={(e) => commit(e.target.value)}
      onKeyDown={(e) => {
        if (e.key === "Enter") (e.target as HTMLInputElement).blur();
      }}
      style={style}
    />
  );
}
