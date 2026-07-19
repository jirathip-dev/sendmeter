import { useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { selectionHaptic } from "../lib/haptics";

/// Shared hover/tap tracking for chart data points. Desktop gets continuous
/// hover via pointerenter/leave; touch gets tap-to-inspect via pointerdown
/// (pointerType check keeps the two from fighting on hybrid devices). Entering
/// a new point fires a light haptic tick (SL-68, native only).
export function useChartHover<T = number>() {
  const [hovered, setHovered] = useState<T | null>(null);

  function select(value: T) {
    if (hovered !== value) selectionHaptic();
    setHovered(value);
  }

  function hoverProps(value: T) {
    return {
      onPointerEnter: (e: ReactPointerEvent) => {
        if (e.pointerType === "mouse") select(value);
      },
      onPointerLeave: (e: ReactPointerEvent) => {
        if (e.pointerType === "mouse") setHovered(null);
      },
      onPointerDown: () => select(value),
    };
  }

  return [hovered, hoverProps] as const;
}
