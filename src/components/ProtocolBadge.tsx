import type { TindeqProtocolMode } from "../types";

export default function ProtocolBadge({
  mode,
  quality,
}: {
  mode: TindeqProtocolMode;
  quality?: string | null;
}) {
  return (
    <span style={{ display: "inline-flex", gap: 5, flexWrap: "wrap", alignItems: "center" }}>
      <span style={{
        borderRadius: 999, padding: "3px 8px", fontSize: "var(--t-2xs)",
        fontWeight: 850, letterSpacing: ".04em", whiteSpace: "nowrap",
        color: mode === "reverse_action" ? "var(--primary)" : "var(--ink-muted)",
        background: mode === "reverse_action"
          ? "color-mix(in srgb, var(--primary) 14%, var(--surface-1))"
          : "var(--surface-2)",
      }}>
        {mode === "reverse_action" ? "REVERSE ACTION" : "STATIC"}
      </span>
      {quality && <span style={{
        borderRadius: 999, padding: "3px 8px", fontSize: "var(--t-2xs)",
        fontWeight: 800, whiteSpace: "nowrap", color: "var(--ink-muted)",
        background: "var(--surface-2)",
      }}>{quality}</span>}
    </span>
  );
}
