import { useCallback, useRef, useState } from "react";
import type { ReactNode } from "react";
import {
  ToastContext,
  type Toast,
  type ToastAction,
  type ToastKind,
} from "../hooks/useToast";

const KIND_COLOR: Record<ToastKind, string> = {
  success: "var(--success)",
  error: "var(--danger)",
  info: "var(--primary)",
};

/// App-level toaster (SL-66): renders a stack of transient confirmations above
/// the bottom nav and exposes `showToast` via context. Auto-dismisses after a
/// few seconds; the accent bar is colored by kind (blue/orange/purple).
export default function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);

  const showToast = useCallback(
    (message: string, kind: ToastKind = "success", action?: ToastAction) => {
      const id = nextId.current++;
      setToasts((list) => [...list, { id, message, kind, action }]);
      setTimeout(
        () => {
          setToasts((list) => list.filter((t) => t.id !== id));
        },
        // A toast with a tappable action lingers longer so it can be used.
        action ? 5000 : 2600,
      );
    },
    [],
  );

  return (
    <ToastContext.Provider value={showToast}>
      {children}
      <div
        style={{
          position: "fixed",
          left: 0,
          right: 0,
          bottom: "calc(96px + env(safe-area-inset-bottom))",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          gap: 8,
          pointerEvents: "none",
          zIndex: 100,
          padding: "0 16px",
        }}
      >
        {toasts.map((t) => (
          <div
            key={t.id}
            className="toast-item"
            style={{
              borderLeft: `3px solid ${KIND_COLOR[t.kind]}`,
              display: "flex",
              alignItems: "center",
              gap: 12,
              // The bar itself ignores pointer events; a toast with an action
              // must accept taps on its button.
              pointerEvents: t.action ? "auto" : "none",
            }}
          >
            <span>{t.message}</span>
            {t.action && (
              <button
                onClick={() => {
                  t.action!.onClick();
                  setToasts((list) => list.filter((x) => x.id !== t.id));
                }}
                style={{
                  flexShrink: 0,
                  background: "none",
                  border: "none",
                  padding: "2px 4px",
                  margin: "-2px -2px -2px 0",
                  fontFamily: "inherit",
                  fontSize: "var(--t-sm)",
                  fontWeight: 700,
                  color: KIND_COLOR[t.kind],
                  cursor: "pointer",
                }}
              >
                {t.action.label}
              </button>
            )}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}
