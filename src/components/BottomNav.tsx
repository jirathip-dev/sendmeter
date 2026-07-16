import type { ReactNode } from "react";
import { NAV } from "../constants";
import { useRipple } from "../hooks/useRipple";
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
  workout: (
    // A boulder/mountain with a route line — the climb-workout tab.
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 20 10 6l4 7 3-4 4 11z" />
      <path d="M10 13.5 12 17" />
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
  const { ripples, spawnRipple } = useRipple();

  return (
    <button
      className={`nav-item ${active ? "active" : ""}`}
      onPointerDown={spawnRipple}
      onClick={onSelect}
      aria-label={label}
      aria-current={active ? "page" : undefined}
    >
      {ripples}
      <span className="nav-icon">{ICONS[view]}</span>
      <span className="nav-label">{label}</span>
    </button>
  );
}

export default function BottomNav({
  view,
  onChange,
  collapsed = false,
  onExpand,
}: {
  view: ViewId;
  onChange: (v: ViewId) => void;
  /// Scroll-hidden state: shrink to a single circle showing the active tab's
  /// icon; tapping it re-reveals the full chrome.
  collapsed?: boolean;
  onExpand?: () => void;
}) {
  if (collapsed) {
    const active = NAV.find((n) => n.id === view) ?? NAV[0]!;
    return (
      <nav className="bottom-nav collapsed">
        <button
          className="nav-item active"
          onClick={onExpand}
          aria-label={`${active.label} — show navigation`}
        >
          <span className="nav-icon">{ICONS[active.id]}</span>
        </button>
      </nav>
    );
  }

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
