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
  disabled,
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
  /// Locks the chip as a live indicator instead of a control (#298) — e.g.
  /// an alternating protocol's side chip mirrors the timeline's own hand, so
  /// tapping it must not fight what the guided run is already doing.
  disabled?: boolean;
}) {
  const hue = color ?? "var(--info)";
  return (
    <span
      className="box-chip-host"
      style={{ "--box-chip-hue": hue, ...style } as CSSProperties}
    >
      <button
        className={`box-chip${small ? " box-chip-small" : ""}`}
        data-active={active ? "true" : "false"}
        data-disabled={disabled ? "true" : "false"}
        data-has-color={color ? "true" : "false"}
        onClick={onClick}
        disabled={disabled}
      >
        {label}
      </button>
    </span>
  );
}
