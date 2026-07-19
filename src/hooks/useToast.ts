import { createContext, useContext } from "react";

export type ToastKind = "success" | "error" | "info";

/// Optional tappable action on a toast (e.g. "Edit" after an auto-save).
export interface ToastAction {
  label: string;
  onClick: () => void;
}

export interface Toast {
  id: number;
  message: string;
  kind: ToastKind;
  action?: ToastAction;
}

/// Show a transient toast. `kind` defaults to "success"; pass `action` for a
/// tappable button (e.g. Edit after a silent save).
export type ShowToast = (
  message: string,
  kind?: ToastKind,
  action?: ToastAction,
) => void;

export const ToastContext = createContext<ShowToast>(() => {});

/// Fire a toast from anywhere under <ToastProvider>. Safe to call in event
/// handlers / async callbacks (never during render).
export function useToast(): ShowToast {
  return useContext(ToastContext);
}
