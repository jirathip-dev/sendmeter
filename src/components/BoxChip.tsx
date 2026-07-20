import type { CSSProperties } from "react";

/// Box-style selectable chip (SL-82) — replaces the tag/side dropdowns on the
/// Force tab and its fullscreen. Selected = info fill; idle = surface well.
export default function BoxChip({
  label,
  active,
  onClick,
  small,
  color,
  style,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
  /// Compact variant for the fullscreen's tight quick-pickers.
  small?: boolean;
  /// Accent hue: fill when active, text + border tint when idle.
  /// Defaults to the info violet.
  color?: string;
  style?: CSSProperties;
}) {
  const hue = color ?? "var(--info)";
  return (
    <button
      onClick={onClick}
      style={{
        padding: small ? "7px 12px" : "10px 14px",
        borderRadius: 9,
        border: `1px solid ${active ? hue : color ? hue : "var(--border)"}`,
        background: active ? hue : "var(--surface-1)",
        color: active ? "#ffffff" : color ? hue : "var(--ink)",
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
