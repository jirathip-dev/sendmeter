import { useEffect, useRef, useState } from "react";
import type { PointerEvent, ReactNode } from "react";
import { sheetHaptic, tapHaptic } from "../lib/haptics";

interface Props {
  /// Omit to make the sheet non-dismissable by backdrop click (e.g. a
  /// required-choice sheet like the legacy-data import prompt). Also disables
  /// drag-to-close.
  onClose?: () => void;
  /// Fix the sheet to full screen height instead of hugging its content
  /// (e.g. the Phases sheet, whose height otherwise jumps as it loads).
  fullHeight?: boolean;
  children: ReactNode;
}

const CLOSE_THRESHOLD = 100; // px dragged down before release dismisses

export default function Sheet({ onClose, fullHeight, children }: Props) {
  const [dragY, setDragY] = useState(0);
  const dragging = useRef(false);
  const startY = useRef(0);
  const dragYRef = useRef(0);

  // #171: the sheet appearing IS the feedback for whatever opened it. The
  // gesture guard means the opening tap (a button, a card) has usually spent
  // this gesture's tick already, so this only actually fires for openers with
  // no tappable element of their own — and stays silent for a sheet that
  // mounts with no recent gesture behind it at all.
  useEffect(() => {
    sheetHaptic();
  }, []);

  function onDown(e: PointerEvent<HTMLDivElement>) {
    if (!onClose) return;
    dragging.current = true;
    startY.current = e.clientY;
    e.currentTarget.setPointerCapture(e.pointerId);
  }
  function onMove(e: PointerEvent<HTMLDivElement>) {
    if (!dragging.current) return;
    const dy = Math.max(0, e.clientY - startY.current);
    dragYRef.current = dy;
    setDragY(dy);
  }
  function onUp() {
    if (!dragging.current) return;
    dragging.current = false;
    if (dragYRef.current > CLOSE_THRESHOLD) {
      tapHaptic();
      onClose?.();
    }
    dragYRef.current = 0;
    setDragY(0);
  }

  return (
    <div
      className="modal-bg"
      // The backdrop dismisses on its own tap (below) — but it is also an
      // ancestor of everything in the sheet, so without muting it a tap on
      // plain sheet copy would resolve to whatever tappable card the sheet
      // happens to be rendered inside and tick for an action that never ran.
      data-haptic="off"
      onClick={(e) => {
        if (!onClose || e.target !== e.currentTarget) return;
        tapHaptic();
        onClose();
      }}
    >
      <div
        className={`modal-sheet${fullHeight ? " full" : ""}`}
        style={{
          transform: `translateY(${dragY}px)`,
          // No transition while the finger is down (dragY > 0 = actively
          // dragging); snap back smoothly once released (dragY returns to 0).
          transition: dragY > 0 ? "none" : "transform 0.25s ease",
        }}
      >
        {/* Grab area — drag down to dismiss (native bottom-sheet feel) */}
        <div
          className="modal-drag"
          onPointerDown={onDown}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onPointerCancel={onUp}
        >
          <div className="modal-handle" />
        </div>
        {children}
      </div>
    </div>
  );
}
