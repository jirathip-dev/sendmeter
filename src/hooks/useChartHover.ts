import { useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";

/// Shared hover/tap tracking for chart data points. Desktop gets continuous
/// hover via pointerenter/leave; touch gets tap-to-inspect via pointerdown
/// (pointerType check keeps the two from fighting on hybrid devices).
export function useChartHover<T = number>() {
  const [hovered, setHovered] = useState<T | null>(null);

  function hoverProps(value: T) {
    return {
      onPointerEnter: (e: ReactPointerEvent) => {
        if (e.pointerType === "mouse") setHovered(value);
      },
      onPointerLeave: (e: ReactPointerEvent) => {
        if (e.pointerType === "mouse") setHovered(null);
      },
      onPointerDown: () => setHovered(value),
    };
  }

  return [hovered, hoverProps] as const;
}
