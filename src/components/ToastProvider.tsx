import { useCallback, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
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

/// App-level toaster (SL-66): renders a stack of transient confirmations below
/// the top chrome (#142) and exposes `showToast` via context. Auto-dismisses
/// after a few seconds; the accent bar is colored by kind (blue/orange/purple).
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
          // Below the account fab (top: safe-area + 10px, 40px tall), never
          // beside it: an actioned toast takes pointer events, so overlapping
          // the fab would swallow taps on the account button. 58px also lines
          // the stack up with `.content-area.with-chrome`'s top padding.
          top: "calc(env(safe-area-inset-top) + 58px)",
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
            style={
              {
                // Drives the `.toast-item::after` accent bar, which sits inside
                // the iridescent hairline ring rather than replacing it.
                "--toast-accent": KIND_COLOR[t.kind],
                display: "flex",
                alignItems: "center",
                gap: 12,
                // The bar itself ignores pointer events; a toast with an action
                // must accept taps on its button.
                pointerEvents: t.action ? "auto" : "none",
              } as CSSProperties
            }
          >
            <span>{t.message}</span>
            {t.action && (
              <button
                className="toast-action-button"
                data-kind={t.kind}
                onClick={() => {
                  t.action!.onClick();
                  setToasts((list) => list.filter((x) => x.id !== t.id));
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
