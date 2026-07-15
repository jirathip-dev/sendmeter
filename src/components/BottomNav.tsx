import { useRef, useState } from "react";
import type { ReactNode, PointerEvent } from "react";
import { NAV } from "../constants";
import type { ViewId } from "../types";

// Clean line icons keyed by view — replaces the old glyphs (⬡ ◉ ≡).
const ICONS: Record<ViewId, ReactNode> = {
  dashboard: (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 10.5 12 3l9 7.5" />
      <path d="M5 9.5V20a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9.5" />
      <path d="M9.5 21v-6h5v6" />
    </svg>
  ),
  tindeq: (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 15a8 8 0 0 1 16 0" />
      <path d="M12 15l4.5-3.5" />
      <circle cx="12" cy="15" r="1.3" fill="currentColor" stroke="none" />
    </svg>
  ),
  history: (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </svg>
  ),
};

interface Ripple {
  id: number;
  x: number;
  y: number;
}

function NavButton({
  view,
  label,
  active,
  onSelect,
}: {
  view: ViewId;
  label: string;
  active: boolean;
  onSelect: () => void;
}) {
  const [ripples, setRipples] = useState<Ripple[]>([]);
  const seq = useRef(0);

  // Spawn an iridescent "droplet" from the touch point that expands and fades.
  function spawn(e: PointerEvent<HTMLButtonElement>) {
    const rect = e.currentTarget.getBoundingClientRect();
    const id = ++seq.current;
    setRipples((r) => [...r, { id, x: e.clientX - rect.left, y: e.clientY - rect.top }]);
    window.setTimeout(() => {
      setRipples((r) => r.filter((rip) => rip.id !== id));
    }, 650);
  }

  return (
    <button
      className={`nav-item ${active ? "active" : ""}`}
      onPointerDown={spawn}
      onClick={onSelect}
      aria-label={label}
      aria-current={active ? "page" : undefined}
    >
      {ripples.map((r) => (
        <span key={r.id} className="nav-ripple" style={{ left: r.x, top: r.y }} />
      ))}
      <span className="nav-icon">{ICONS[view]}</span>
      <span className="nav-label">{label}</span>
    </button>
  );
}

export default function BottomNav({
  view,
  onChange,
}: {
  view: ViewId;
  onChange: (v: ViewId) => void;
}) {
  return (
    <nav className="bottom-nav">
      {NAV.map((n) => (
        <NavButton
          key={n.id}
          view={n.id}
          label={n.label}
          active={view === n.id}
          onSelect={() => onChange(n.id)}
        />
      ))}
    </nav>
  );
}
