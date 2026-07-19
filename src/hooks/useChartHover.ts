import { useEffect, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { selectionHaptic } from "../lib/haptics";

/// Shared hover/tap/drag tracking for chart data points. Desktop hovers via
/// pointerenter/leave. Touch supports **scrubbing**: pointerdown releases the
/// implicit pointer capture so pointerenter keeps firing on the points the
/// finger drags across, moving the tooltip live instead of needing a fresh tap
/// each time. Entering a new point fires a light haptic tick (native only).
/// Chart hit areas should carry the `.chart-scrub` class (touch-action: pan-y)
/// so a horizontal drag scrubs instead of being claimed as a page scroll.
export function useChartHover<T = number>() {
  const [hovered, setHovered] = useState<T | null>(null);
  const dragging = useRef(false);

  // End the touch drag when the finger lifts anywhere on screen.
  useEffect(() => {
    const end = () => {
      dragging.current = false;
    };
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
    return () => {
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
    };
  }, []);

  function select(value: T) {
    if (hovered !== value) selectionHaptic();
    setHovered(value);
  }

  function hoverProps(value: T) {
    return {
      onPointerEnter: (e: ReactPointerEvent) => {
        if (e.pointerType === "mouse" || dragging.current) select(value);
      },
      onPointerLeave: (e: ReactPointerEvent) => {
        if (e.pointerType === "mouse") setHovered(null);
      },
      onPointerDown: (e: ReactPointerEvent) => {
        if (e.pointerType !== "mouse") {
          try {
            (e.currentTarget as Element).releasePointerCapture(e.pointerId);
          } catch {
            /* wasn't captured */
          }
          dragging.current = true;
        }
        select(value);
      },
    };
  }

  return [hovered, hoverProps] as const;
}
