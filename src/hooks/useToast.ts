import { createContext, useContext } from "react";

export type ToastKind = "success" | "error" | "info";

export interface Toast {
  id: number;
  message: string;
  kind: ToastKind;
}

/// Show a transient toast. `kind` defaults to "success".
export type ShowToast = (message: string, kind?: ToastKind) => void;

export const ToastContext = createContext<ShowToast>(() => {});

/// Fire a toast from anywhere under <ToastProvider>. Safe to call in event
/// handlers / async callbacks (never during render).
export function useToast(): ShowToast {
  return useContext(ToastContext);
}
