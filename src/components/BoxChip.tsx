import type { CSSProperties } from "react";

/// Box-style selectable chip (SL-82) — replaces the tag/side dropdowns on the
/// Force tab and its fullscreen. Selected = info fill; idle = surface well.
export default function BoxChip({
  label,
  active,
  onClick,
  small,
  style,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
  /// Compact variant for the fullscreen's tight quick-pickers.
  small?: boolean;
  style?: CSSProperties;
}) {
  return (
    <button
      onClick={onClick}
      style={{
        padding: small ? "7px 12px" : "10px 14px",
        borderRadius: 9,
        border: `1px solid ${active ? "var(--info)" : "var(--border)"}`,
        background: active ? "var(--info)" : "var(--surface-1)",
        color: active ? "#ffffff" : "var(--ink)",
        fontFamily: "Inter, sans-serif",
        fontSize: small ? "var(--t-sm)" : "var(--t-base)",
        fontWeight: 600,
        cursor: "pointer",
        WebkitTapHighlightColor: "transparent",
        ...style,
      }}
    >
      {label}
    </button>
  );
}
