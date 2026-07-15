import { useRef, useState } from "react";
import type { PointerEvent, ReactNode } from "react";

interface Ripple {
  id: number;
  x: number;
  y: number;
}

/// Iridescent "droplet" tap feedback (shared by the bottom nav and tappable
/// cards): spawn on pointerdown, expands and fades from the touch point.
/// The host element needs position:relative + overflow:hidden.
export function useRipple(): {
  ripples: ReactNode;
  spawnRipple: (e: PointerEvent<HTMLElement>) => void;
} {
  const [list, setList] = useState<Ripple[]>([]);
  const seq = useRef(0);

  function spawnRipple(e: PointerEvent<HTMLElement>) {
    const rect = e.currentTarget.getBoundingClientRect();
    const id = ++seq.current;
    setList((r) => [...r, { id, x: e.clientX - rect.left, y: e.clientY - rect.top }]);
    window.setTimeout(() => {
      setList((r) => r.filter((rip) => rip.id !== id));
    }, 420);
  }

  const ripples = list.map((r) => (
    <span key={r.id} className="tap-ripple" style={{ left: r.x, top: r.y }} />
  ));

  return { ripples, spawnRipple };
}
