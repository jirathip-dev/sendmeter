import { useRef, useState } from "react";
import type { PointerEvent, ReactNode } from "react";

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
    if (dragYRef.current > CLOSE_THRESHOLD) onClose?.();
    dragYRef.current = 0;
    setDragY(0);
  }

  return (
    <div
      className="modal-bg"
      onClick={(e) => onClose && e.target === e.currentTarget && onClose()}
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
