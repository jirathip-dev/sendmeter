import { createPortal } from "react-dom";
import { useContext, useEffect, useId, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent, ReactNode } from "react";
import { sheetHaptic, tapHaptic } from "../lib/haptics";
import { wrapFocusIndex } from "../lib/sheetFocus";
import { SheetLayerContext, type SheetLayer } from "../lib/sheetLayer";
import {
  isSheetDragExcludedTarget,
  shouldDismissSheetGesture,
  shouldStartSheetDrag,
} from "../lib/sheetGesture";

export interface SheetProps {
  /// Omit to make the sheet non-dismissible by backdrop click, Escape, the
  /// close button, and drag (e.g. a required-choice prompt).
  onClose?: () => void;
  /// Persistent accessible heading shown in the non-scrolling top region.
  title?: string;
  /// Optional supporting line that remains visible with the heading.
  subtitle?: string;
  /// Used when a sheet intentionally has no visible title.
  ariaLabel?: string;
  /// Override the close button's accessible name for a more specific action.
  closeLabel?: string;
  /// Fix the sheet to full screen height instead of hugging its content.
  fullHeight?: boolean;
  /// Place this sheet above a body-portaled fullscreen surface. When omitted,
  /// a sheet inherits the nearest SheetLayerProvider, so dialogs opened from a
  /// fullscreen flow cannot accidentally fall behind their opener.
  layer?: SheetLayer;
  /// Optional scope for sheets that must sit above another fixed surface.
  className?: string;
  children: ReactNode;
}

/**
 * Fullscreen surfaces render through their own body portal. React context is
 * retained across portals, which lets every nested Sheet (including a
 * ConfirmDialog) inherit the surface's stacking scope without requiring each
 * call site to remember a z-index class.
 */
export function SheetLayerProvider({
  layer,
  children,
}: {
  layer: SheetLayer;
  children: ReactNode;
}) {
  return (
    <SheetLayerContext.Provider value={layer}>
      {children}
    </SheetLayerContext.Provider>
  );
}

const FLICK_SAMPLE_MAX_AGE_MS = 100;
const SHEET_FONT_STACK = "Inter, -apple-system, BlinkMacSystemFont, sans-serif";
const SHEET_FONT_VARIANT = "tabular-nums";
const FOCUSABLE_SELECTOR = [
  "button:not([disabled])",
  "[href]",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex=\"-1\"])",
].join(",");

interface DragGesture {
  pointerId: number;
  startX: number;
  startY: number;
  lastY: number;
  lastAt: number;
  velocitySampleY: number;
  velocitySampleAt: number;
  engaged: boolean;
  blocked: boolean;
}

let bodyLockCount = 0;
let previousBodyOverflow = "";
let previousDocumentOverflow = "";
const sheetStack: HTMLElement[] = [];

function focusableElements(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)).filter(
    (element) => element.getAttribute("aria-hidden") !== "true",
  );
}

function targetIsExcluded(target: EventTarget | null): boolean {
  const element = target as Element | null;
  if (!element || typeof element.closest !== "function") return false;
  const candidate = element.closest(
    "button,a,input,textarea,select,option,summary,[role],[contenteditable],.chart-scrub,.sheet-no-drag",
  ) ?? element;
  return isSheetDragExcludedTarget({
    tagName: candidate.tagName,
    role: candidate.getAttribute("role"),
    classes: Array.from(candidate.classList ?? []),
    contentEditable: candidate.hasAttribute("contenteditable"),
  });
}

/**
 * Shared accessible bottom sheet. The handle, heading, and close control are
 * fixed in a top region; only the body scrolls. Keeping pointer handlers on
 * that region (rather than the whole surface) is what lets charts retain
 * their horizontal scrub stream.
 */
export default function Sheet({
  onClose,
  title,
  subtitle,
  ariaLabel,
  closeLabel,
  fullHeight,
  layer,
  className,
  children,
}: SheetProps) {
  const inheritedLayer = useContext(SheetLayerContext);
  const classTokens = className?.split(/\s+/).filter(Boolean) ?? [];
  // Keep the established class name useful on its own, while allowing an
  // explicit prop and the nearest fullscreen provider to handle every other
  // nested path. This means a future setup sheet cannot regress by omitting a
  // second, manually-maintained z-index declaration.
  const resolvedLayer =
    layer ??
    (classTokens.includes("force-setup-sheet")
      ? "fullscreen"
      : inheritedLayer ?? "default");
  const layerClass = `sheet-layer-${resolvedLayer}`;
  const [dragY, setDragY] = useState(0);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const closeRef = useRef<HTMLButtonElement | null>(null);
  const openerRef = useRef<HTMLElement | null>(null);
  const gestureRef = useRef<DragGesture | null>(null);
  const titleId = useId();
  const dialogLabel = title ? undefined : ariaLabel ?? "Dialog";

  // #171: opening from a plain surface (rather than a tappable control) still
  // gets the sheet tick, while a button/card opener's delegated tick wins.
  useEffect(() => {
    sheetHaptic();
  }, []);

  // Lock both scrolling roots while any sheet is open. A count is required
  // because session detail can open Edit Recording as a nested sheet.
  useEffect(() => {
    if (typeof document === "undefined") return;
    const body = document.body;
    const documentElement = document.documentElement;
    if (bodyLockCount === 0) {
      previousBodyOverflow = body.style.overflow;
      previousDocumentOverflow = documentElement.style.overflow;
    }
    bodyLockCount += 1;
    body.style.overflow = "hidden";
    documentElement.style.overflow = "hidden";
    return () => {
      bodyLockCount = Math.max(0, bodyLockCount - 1);
      if (bodyLockCount === 0) {
        body.style.overflow = previousBodyOverflow;
        documentElement.style.overflow = previousDocumentOverflow;
      }
    };
  }, []);

  // Track the sheet stack so only the topmost nested dialog owns Escape and
  // Tab. Restore the element that opened this particular sheet on close.
  useEffect(() => {
    if (typeof document === "undefined") return;
    const root = rootRef.current;
    if (!root) return;
    openerRef.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    sheetStack.push(root);
    return () => {
      const index = sheetStack.indexOf(root);
      if (index >= 0) sheetStack.splice(index, 1);
      const opener = openerRef.current;
      if (opener?.isConnected) {
        queueMicrotask(() => opener.focus());
      }
    };
  }, []);

  // Initial focus belongs to the dialog's close action. It is always present
  // for dismissible sheets and is the most useful first control for keyboard
  // and assistive-technology users. Non-dismissible prompts focus their first
  // available action instead; a content-only dialog focuses its root.
  useEffect(() => {
    if (typeof document === "undefined") return;
    const root = rootRef.current;
    if (!root) return;
    queueMicrotask(() => {
      if (!root.isConnected || sheetStack[sheetStack.length - 1] !== root) return;
      const first = closeRef.current ?? focusableElements(root)[0];
      (first ?? root).focus();
    });
  }, []);

  useEffect(() => {
    if (typeof document === "undefined") return;
    function onKeyDown(event: KeyboardEvent) {
      const root = rootRef.current;
      if (!root || sheetStack[sheetStack.length - 1] !== root) return;

      if (event.key === "Escape") {
        if (!onClose) return;
        event.preventDefault();
        event.stopPropagation();
        onClose();
        return;
      }
      if (event.key !== "Tab") return;

      const focusables = focusableElements(root);
      if (focusables.length === 0) {
        event.preventDefault();
        root.focus();
        return;
      }
      const activeIndex = focusables.indexOf(
        document.activeElement as HTMLElement,
      );
      const direction: 1 | -1 = event.shiftKey ? -1 : 1;
      const atBoundary =
        activeIndex < 0 ||
        (direction > 0 && activeIndex === focusables.length - 1) ||
        (direction < 0 && activeIndex === 0);
      if (atBoundary) {
        event.preventDefault();
        const nextIndex = wrapFocusIndex(activeIndex, direction, focusables.length);
        focusables[nextIndex]?.focus();
      }
    }
    function onFocusIn(event: FocusEvent) {
      const root = rootRef.current;
      if (
        !root ||
        sheetStack[sheetStack.length - 1] !== root ||
        root.contains(event.target as Node)
      ) {
        return;
      }
      const first = closeRef.current ?? focusableElements(root)[0];
      (first ?? root).focus();
    }
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("focusin", onFocusIn);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("focusin", onFocusIn);
    };
  }, [onClose]);

  function onPointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (!onClose || targetIsExcluded(event.target)) return;
    gestureRef.current = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      lastY: event.clientY,
      lastAt: event.timeStamp,
      velocitySampleY: event.clientY,
      velocitySampleAt: event.timeStamp,
      engaged: false,
      blocked: false,
    };
    try {
      event.currentTarget.setPointerCapture(event.pointerId);
    } catch {
      /* Pointer capture is unavailable in static test DOMs. */
    }
  }

  function onPointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    const gesture = gestureRef.current;
    if (!gesture || gesture.pointerId !== event.pointerId || gesture.blocked) return;

    const dx = event.clientX - gesture.startX;
    const dy = event.clientY - gesture.startY;
    if (!gesture.engaged) {
      if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
      if (!shouldStartSheetDrag({ dx, dy })) {
        gesture.blocked = true;
        return;
      }
      gesture.engaged = true;
    }

    if (event.timeStamp - gesture.velocitySampleAt > FLICK_SAMPLE_MAX_AGE_MS) {
      gesture.velocitySampleY = gesture.lastY;
      gesture.velocitySampleAt = gesture.lastAt;
    }
    gesture.lastY = event.clientY;
    gesture.lastAt = event.timeStamp;
    setDragY(Math.max(0, dy));
  }

  function finishDrag(event: ReactPointerEvent<HTMLDivElement>, cancelled: boolean) {
    const gesture = gestureRef.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    gestureRef.current = null;

    try {
      event.currentTarget.releasePointerCapture(event.pointerId);
    } catch {
      /* Pointer capture was not established. */
    }

    if (gesture.engaged) {
      const distancePx = Math.max(0, event.clientY - gesture.startY);
      const velocitySampleAgeMs = event.timeStamp - gesture.velocitySampleAt;
      const velocityPxPerMs =
        velocitySampleAgeMs > 0 && velocitySampleAgeMs <= FLICK_SAMPLE_MAX_AGE_MS
          ? Math.max(
              0,
              (event.clientY - gesture.velocitySampleY) / velocitySampleAgeMs,
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
    }
    setDragY(0);
  }

  const sheet = (
    <SheetLayerContext.Provider value={resolvedLayer}>
      <div
        ref={rootRef}
        className={`modal-bg ${layerClass}${className ? ` ${className}` : ""}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? titleId : undefined}
        aria-label={dialogLabel}
        data-haptic="off"
        data-sheet-layer={resolvedLayer}
        data-sheet-typography="inter-tabular"
        tabIndex={-1}
        style={{
          fontFamily: SHEET_FONT_STACK,
          fontVariantNumeric: SHEET_FONT_VARIANT,
        }}
        onClick={(event) => {
          event.stopPropagation();
          if (event.target !== event.currentTarget || !onClose) return;
          tapHaptic();
          onClose();
        }}
      >
        <div
          className={`modal-sheet premium-sheet${fullHeight ? " full" : ""}`}
          style={{
            transform: `translateY(${dragY}px)`,
            transition: dragY > 0 ? "none" : "transform 0.25s ease",
          }}
        >
          <div
            className="modal-top"
            onPointerDown={onPointerDown}
            onPointerMove={onPointerMove}
            onPointerUp={(event) => finishDrag(event, false)}
            onPointerCancel={(event) => finishDrag(event, true)}
          >
            <div className="modal-handle" aria-hidden="true" />
            <div className="modal-top-row">
              {title ? (
                <div className="modal-heading">
                  <h2 id={titleId} className="modal-title">
                    {title}
                  </h2>
                  {subtitle && <div className="modal-subtitle">{subtitle}</div>}
                </div>
              ) : (
                <span className="modal-title-spacer" aria-hidden="true" />
              )}
              {onClose && (
                <button
                  ref={closeRef}
                  type="button"
                  className="modal-close"
                  aria-label={closeLabel ?? (title ? `Close ${title}` : "Close dialog")}
                  style={{
                    fontFamily: SHEET_FONT_STACK,
                    fontVariantNumeric: SHEET_FONT_VARIANT,
                  }}
                  onClick={onClose}
                >
                  ×
                </button>
              )}
            </div>
          </div>
          <div className="modal-content">{children}</div>
        </div>
      </div>
    </SheetLayerContext.Provider>
  );

  // Static markup tests and any non-DOM render keep the sheet in place. In a
  // browser, the portal prevents a detail row's click handler from seeing
  // sheet content and gives nested sheets a predictable stacking context.
  return typeof document === "undefined" ? sheet : createPortal(sheet, document.body);
}
