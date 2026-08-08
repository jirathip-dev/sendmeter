import type { ActiveTindeqStatus } from "../lib/forceConnection";

export default function ForceConnectionCard({
  status,
  locked,
  onOpenGauge,
  onOpenSetup,
}: {
  status: ActiveTindeqStatus;
  locked: boolean;
  onOpenGauge: () => void;
  onOpenSetup: () => void;
}) {
  const tone = status === "measuring"
    ? "var(--success)"
    : status === "armed"
      ? "var(--warning)"
      : "var(--info)";

  return (
    <div className="force-connection-card" style={{
      width: "100%",
      background: "var(--canvas)",
      border: `1px solid color-mix(in srgb, ${tone} 45%, transparent)`,
      borderRadius: 12,
      padding: "12px 16px",
      display: "flex",
      alignItems: "center",
      gap: 10,
    }}>
      <span aria-hidden="true" style={{
        width: 8,
        height: 8,
        flexShrink: 0,
        borderRadius: "50%",
        background: tone,
        animation: status === "measuring" ? "pulse 1.6s ease-in-out infinite" : undefined,
      }} />
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ fontSize: "var(--t-base)", color: "var(--ink)", overflowWrap: "anywhere" }}>
          Progressor <span style={{ color: "var(--ink-muted)" }}>· {status}</span>
        </div>
        <button
          className="force-setup-link"
          type="button"
          disabled={locked}
          onClick={onOpenSetup}
          aria-label="Open equipment setup guidance"
        >
          How to set up
        </button>
      </div>
      <button
        className="force-open-link"
        type="button"
        onClick={onOpenGauge}
      >
        <span style={{ color: "var(--primary)", fontWeight: 700, fontSize: "var(--t-base)", whiteSpace: "nowrap" }}>
          Open gauge ›
        </span>
      </button>
    </div>
  );
}
