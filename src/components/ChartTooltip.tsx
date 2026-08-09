import type { CSSProperties, ReactNode } from "react";

type Align = "start" | "center" | "end";

const ALIGN_STYLE: Record<Align, CSSProperties> = {
  start: { left: 0 },
  center: { left: "50%", transform: "translateX(-50%)" },
  end: { right: 0 },
};

/// Floating tooltip for div-based bar/sparkline charts. Renders as a child
/// of the hovered bar (which must be position:relative) so it needs no
/// pixel math — `style` can override `left`/`transform` for callers that
/// position it themselves (e.g. a variable-width timeline segment).
export default function ChartTooltip({
  align = "center",
  style,
  children,
}: {
  align?: Align;
  style?: CSSProperties;
  children: ReactNode;
}) {
  return (
    <div
      role="status"
      style={{
        position: "absolute",
        bottom: "100%",
        marginBottom: 6,
        padding: "5px 7px",
        background: "var(--chart-tooltip)",
        border: "1px solid var(--chart-tooltip-border)",
        borderRadius: 6,
        boxShadow: "var(--shadow-card)",
        fontSize: "var(--t-2xs)",
        color: "var(--ink)",
        whiteSpace: "nowrap",
        pointerEvents: "none",
        zIndex: 10,
        ...ALIGN_STYLE[align],
        ...style,
      }}
    >
      {children}
    </div>
  );
}
