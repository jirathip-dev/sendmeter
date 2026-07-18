import { createContext, useContext } from "react";
import type { useTindeq } from "./useTindeq";

/// One live Progressor session: the group every recording taken during it
/// shares, minted lazily on the first save (SL-58 — no manual "Start
/// Session").
export interface GaugeSession {
  groupId: string;
  startedAt: number;
}

export interface TindeqContextValue {
  tindeq: ReturnType<typeof useTindeq>;
  /// The active gauge session, or null before the first recording.
  session: GaugeSession | null;
  /// Return the active session's group id, minting it on first call. Written
  /// through a ref so two near-simultaneous saves (first rep + autosave) get
  /// the SAME group id instead of racing to create two.
  ensureSession: () => string;
  /// End the session (after logging or discarding it).
  clearSession: () => void;
  /// Fullscreen-gauge minimized state — lifted here so it (like the
  /// connection) survives leaving the Force tab and coming back.
  minimized: boolean;
  setMinimized: (v: boolean) => void;
}

export const TindeqContext = createContext<TindeqContextValue | null>(null);

export function useTindeqSession(): TindeqContextValue {
  const ctx = useContext(TindeqContext);
  if (!ctx) throw new Error("useTindeqSession must be used within TindeqProvider");
  return ctx;
}
