import { useEffect, useRef, useState } from "react";
import type { PointerEvent, ReactNode } from "react";
import { sheetHaptic, tapHaptic } from "../lib/haptics";
import { shouldDismissSheetGesture } from "../lib/sheetGesture";

interface Props {
  /// Omit to make the sheet non-dismissable by backdrop click (e.g. a
  /// required-choice sheet like the legacy-data import prompt). Also disables
  /// drag-to-close.
  onClose?: () => void;
  /// Fix the sheet to full screen height instead of hugging its content
  /// (e.g. the Phases sheet, whose height otherwise jumps as it loads).
  fullHeight?: boolean;
  /// Optional scope for sheets that must sit above another fixed surface
  /// (the Force setup guide opens from the z-indexed fullscreen gauge).
  className?: string;
  children: ReactNode;
}

const FLICK_SAMPLE_MAX_AGE_MS = 100;

interface DragGesture {
  pointerId: number;
  startY: number;
  lastY: number;
  lastAt: number;
  velocitySampleY: number;
  velocitySampleAt: number;
}

export default function Sheet({ onClose, fullHeight, className, children }: Props) {
  const [dragY, setDragY] = useState(0);
  const gestureRef = useRef<DragGesture | null>(null);

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
    gestureRef.current = {
      pointerId: e.pointerId,
      startY: e.clientY,
      lastY: e.clientY,
      lastAt: e.timeStamp,
      velocitySampleY: e.clientY,
      velocitySampleAt: e.timeStamp,
    };
    e.currentTarget.setPointerCapture(e.pointerId);
  }
  function onMove(e: PointerEvent<HTMLDivElement>) {
    const gesture = gestureRef.current;
    if (!gesture || gesture.pointerId !== e.pointerId) return;

    if (e.timeStamp - gesture.velocitySampleAt > FLICK_SAMPLE_MAX_AGE_MS) {
      gesture.velocitySampleY = gesture.lastY;
      gesture.velocitySampleAt = gesture.lastAt;
    }
    gesture.lastY = e.clientY;
    gesture.lastAt = e.timeStamp;

    const dy = Math.max(0, e.clientY - gesture.startY);
    setDragY(dy);
  }
  function finishDrag(e: PointerEvent<HTMLDivElement>, cancelled: boolean) {
    const gesture = gestureRef.current;
    if (!gesture || gesture.pointerId !== e.pointerId) return;
    gestureRef.current = null;

    const distancePx = Math.max(0, e.clientY - gesture.startY);
    const velocitySampleAgeMs = e.timeStamp - gesture.velocitySampleAt;
    const velocityPxPerMs =
      velocitySampleAgeMs > 0 &&
      velocitySampleAgeMs <= FLICK_SAMPLE_MAX_AGE_MS
        ? Math.max(
            0,
            (e.clientY - gesture.velocitySampleY) / velocitySampleAgeMs,
          )
        : 0;
    if (
      shouldDismissSheetGesture({
        dismissible: Boolean(onClose),
        cancelled,
        distancePx,
        velocityPxPerMs,
      })
    ) {
      tapHaptic();
      onClose?.();
    }
    setDragY(0);
  }

  return (
    <div
      className={`modal-bg${className ? ` ${className}` : ""}`}
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
        className={`modal-sheet premium-sheet${fullHeight ? " full" : ""}`}
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
          onPointerUp={(e) => finishDrag(e, false)}
          onPointerCancel={(e) => finishDrag(e, true)}
        >
          <div className="modal-handle" />
        </div>
        <div className="modal-content">{children}</div>
      </div>
    </div>
  );
}
