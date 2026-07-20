import { useEffect, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent, ReactNode } from "react";
import { createPortal } from "react-dom";

const CLOSE_THRESHOLD = 90; // px dragged right before release dismisses
const SLIDE_MS = 260;

/// Full-screen detail page that slides in from the RIGHT (iOS push style) —
/// swipe right anywhere (or the back chevron) to dismiss. Vertical scrolling
/// stays native: the horizontal drag only engages once the gesture is
/// clearly sideways. Sits BELOW bottom sheets (z 150 < modal's 200) so an
/// edit sheet opened from inside still stacks on top.
export default function DetailPage({
  title,
  subtitle,
  onClose,
  children,
}: {
  title: string;
  subtitle?: string;
  onClose: () => void;
  children: ReactNode;
}) {
  const [entered, setEntered] = useState(false);
  const [closing, setClosing] = useState(false);
  const [dragX, setDragX] = useState(0);
  const dragging = useRef(false);
  const engaged = useRef(false);
  const start = useRef({ x: 0, y: 0 });
  const dragXRef = useRef(0);

  // Slide in on mount (transform animates from 100% → 0).
  useEffect(() => {
    const id = requestAnimationFrame(() => setEntered(true));
    return () => cancelAnimationFrame(id);
  }, []);

  function close() {
    if (closing) return;
    setClosing(true);
    setTimeout(onClose, SLIDE_MS);
  }

  function onDown(e: ReactPointerEvent<HTMLDivElement>) {
    dragging.current = true;
    engaged.current = false;
    start.current = { x: e.clientX, y: e.clientY };
  }
  function onMove(e: ReactPointerEvent<HTMLDivElement>) {
    if (!dragging.current) return;
    const dx = e.clientX - start.current.x;
    const dy = e.clientY - start.current.y;
    // Engage only on a clearly sideways rightward gesture; otherwise leave
    // the event stream alone so vertical scrolling behaves natively.
    if (!engaged.current) {
      if (dx > 14 && Math.abs(dx) > Math.abs(dy) * 1.4) {
        engaged.current = true;
        e.currentTarget.setPointerCapture(e.pointerId);
      } else {
        return;
      }
    }
    const clamped = Math.max(0, dx);
    dragXRef.current = clamped;
    setDragX(clamped);
  }
  function onUp() {
    if (!dragging.current) return;
    dragging.current = false;
    if (engaged.current && dragXRef.current > CLOSE_THRESHOLD) {
      close();
    }
    engaged.current = false;
    dragXRef.current = 0;
    setDragX(0);
  }

  const offscreen = !entered || closing;

  return createPortal(
    <div
      onPointerDown={onDown}
      onPointerMove={onMove}
      onPointerUp={onUp}
      onPointerCancel={onUp}
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 150,
        background: "var(--bg)",
        color: "var(--ink)",
        fontFamily: "Inter, -apple-system, BlinkMacSystemFont, sans-serif",
        fontVariantNumeric: "tabular-nums",
        display: "flex",
        flexDirection: "column",
        transform: offscreen ? "translateX(100%)" : `translateX(${dragX}px)`,
        // dragX > 0 = a live drag: track the finger with no easing.
        transition:
          dragX > 0
            ? "none"
            : `transform ${SLIDE_MS}ms cubic-bezier(0.32, 0.72, 0.3, 1)`,
        touchAction: "pan-y",
        boxShadow: "-12px 0 32px rgba(0,0,0,0.25)",
      }}
    >
      {/* Header: back chevron + title */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "max(14px, env(safe-area-inset-top)) 16px 10px",
          flexShrink: 0,
        }}
      >
        <button onClick={close} aria-label="Back" className="glass-chip">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 6l-6 6 6 6" />
          </svg>
        </button>
        <div style={{ minWidth: 0 }}>
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: "var(--t-lg)",
              fontWeight: 800,
              letterSpacing: "-0.01em",
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
          >
            {title}
          </div>
          {subtitle && (
            <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
              {subtitle}
            </div>
          )}
        </div>
      </div>

      <div
        style={{
          flex: 1,
          overflowY: "auto",
          padding: "4px 16px calc(24px + env(safe-area-inset-bottom))",
        }}
      >
        {children}
      </div>
    </div>,
    document.body,
  );
}
