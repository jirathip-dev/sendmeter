import { useEffect, useRef, useState } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, PointerEvent as ReactPointerEvent } from "react";
import { selectionHaptic } from "../lib/haptics";
import { nearestDatumFromClientX } from "../lib/chartInteraction";

/// Pure decision logic for #299: on touch, tapping a chart point leaves its
/// tooltip up (no hover to clear it — see `onPointerLeave` below), so
/// something else has to clear it when the user taps elsewhere in the app.
/// Extracted as a plain factory (no DOM types) so it's unit-testable in the
/// repo's node-environment vitest setup, same convention as `useTindeq.ts`'s
/// exported pure helpers — no jsdom dependency needed.
///
/// Design: each `claim(ev)` records the event that a point's own
/// `onPointerDown` just handled. A window-level bubble-phase `pointerdown`
/// listener then calls `onWindowPointerDown(ev)` for every pointerdown that
/// reaches it; if `ev` isn't the one just claimed, the tooltip clears. Because
/// React 19 attaches handlers at the root container, the point's own handler
/// (which claims the event) always runs before the same event bubbles to
/// `window`, so a tap that lands on this chart's own point never
/// self-dismisses, while a tap anywhere else — another chart, blank space,
/// the nav, or the start of a page scroll — does.
///
/// Known limitation (see `useChartHover` below): this only works because
/// nothing currently calls `stopPropagation()` on `pointerdown`.
export function createOutsideClearTracker(clear: () => void) {
  let claimed: unknown = null;
  return {
    claim: (ev: unknown) => {
      claimed = ev;
    },
    onWindowPointerDown: (ev: unknown) => {
      if (ev !== claimed) clear();
    },
  };
}

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
  const outsideClear = useRef(
    createOutsideClearTracker(() => setHovered(null)),
  );

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

  // #299: clear a lingering touch tooltip/highlight when the user taps
  // anywhere that isn't this chart's own just-claimed point. Bubble phase
  // (not capture) is required — the claim has to be recorded by the point's
  // own React bubble handler before this listener runs its comparison. That
  // means a future `stopPropagation()` on a pointerdown handler would shield
  // taps from this clear; audited today, every existing `stopPropagation` in
  // `src/` is on `click` handlers only, so nothing blocks it currently.
  useEffect(() => {
    const onWindowPointerDown = (e: PointerEvent) => {
      outsideClear.current.onWindowPointerDown(e);
    };
    window.addEventListener("pointerdown", onWindowPointerDown);
    return () => {
      window.removeEventListener("pointerdown", onWindowPointerDown);
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
        outsideClear.current.claim(e.nativeEvent);
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
      onFocus: () => select(value),
      onBlur: () => setHovered((current) => (current === value ? null : current)),
      onKeyDown: (e: ReactKeyboardEvent) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          select(value);
        }
      },
    };
  }

  /**
   * Props for one chart-level scrub surface.  `values` is the ordered datum
   * list and `positionForIndex` maps each datum to the chart's x coordinate.
   * The surface owns pointer and keyboard selection; visual marks remain
   * pointer-transparent, so nearby marks can never steal a scrub gesture.
   */
  function surfaceProps(
    values: readonly T[],
    chartWidth: number,
    positionForIndex: (index: number) => number,
  ) {
    // Compute positions once per render rather than allocating a new array on
    // every pointermove of a live scrub gesture.
    const positions = values.map((_, i) => positionForIndex(i));
    const chooseAt = (event: ReactPointerEvent) => {
      const current = event.currentTarget as SVGElement | HTMLElement;
      const chartElement = "ownerSVGElement" in current
        ? current.ownerSVGElement ?? current
        : current;
      const rect = chartElement.getBoundingClientRect();
      const index = nearestDatumFromClientX(
        positions,
        event.clientX,
        rect,
        chartWidth,
      );
      if (index !== null) select(values[index]!);
    };

    const currentIndex = hovered === null ? -1 : values.indexOf(hovered);
    const chooseKeyboard = (index: number) => {
      if (values.length > 0) select(values[Math.max(0, Math.min(values.length - 1, index))]!);
    };

    return {
      onPointerEnter: (event: ReactPointerEvent) => {
        if (event.pointerType === "mouse") chooseAt(event);
      },
      onPointerMove: (event: ReactPointerEvent) => {
        if (event.pointerType === "mouse" || dragging.current) chooseAt(event);
      },
      onPointerLeave: (event: ReactPointerEvent) => {
        if (event.pointerType === "mouse") setHovered(null);
      },
      onPointerDown: (event: ReactPointerEvent) => {
        outsideClear.current.claim(event.nativeEvent);
        if (event.pointerType !== "mouse") {
          try {
            (event.currentTarget as Element).releasePointerCapture(event.pointerId);
          } catch {
            /* wasn't captured */
          }
          dragging.current = true;
        }
        chooseAt(event);
      },
      onFocus: () => chooseKeyboard(currentIndex < 0 ? 0 : currentIndex),
      onBlur: () => setHovered(null),
      onKeyDown: (event: ReactKeyboardEvent) => {
        if (values.length === 0) return;
        const index = currentIndex < 0 ? 0 : currentIndex;
        let next: number | null = null;
        if (event.key === "ArrowLeft" || event.key === "ArrowDown") next = index - 1;
        if (event.key === "ArrowRight" || event.key === "ArrowUp") next = index + 1;
        if (event.key === "Home") next = 0;
        if (event.key === "End") next = values.length - 1;
        if (event.key === "Enter" || event.key === " ") next = index;
        if (next !== null) {
          event.preventDefault();
          chooseKeyboard(next);
        }
      },
    };
  }

  return [hovered, hoverProps, select, surfaceProps] as const;
}
