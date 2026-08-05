import { useCallback, useRef, useState } from "react";
import type { ReactNode } from "react";
import { useTindeq } from "./useTindeq";
import { TindeqContext, type GaugeSession } from "./useTindeqSession";

/// Holds the Tindeq BLE connection AND the active gauge session ABOVE the tab
/// switch, so the Progressor stays connected and the session survives when you
/// leave the fullscreen gauge, pick a protocol, or change tabs (SL-58 #5).
export function TindeqProvider({ children }: { children: ReactNode }) {
  const tindeq = useTindeq();
  const sessionRef = useRef<GaugeSession | null>(null);
  const [session, setSession] = useState<GaugeSession | null>(null);
  const [minimized, setMinimized] = useState(false);

  const ensureSession = useCallback(() => {
    if (sessionRef.current) return sessionRef.current.groupId;
    const s: GaugeSession = { groupId: crypto.randomUUID(), startedAt: Date.now() };
    sessionRef.current = s;
    setSession(s);
    return s.groupId;
  }, []);

  const clearSession = useCallback(() => {
    sessionRef.current = null;
    setSession(null);
  }, []);

  return (
    <TindeqContext.Provider
      value={{ tindeq, session, sessionRef, ensureSession, clearSession, minimized, setMinimized }}
    >
      {children}
    </TindeqContext.Provider>
  );
}
