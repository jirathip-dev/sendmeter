import type { ReactNode } from "react";
import Sheet from "./Sheet";

interface Props {
  title: string;
  body: ReactNode;
  confirmLabel: string;
  cancelLabel?: string;
  /// Confirm button uses the shared danger-button style (var(--danger),
  /// white text) — matches TrashSheet's "Delete forever" and AccountSheet's
  /// "Yes, delete everything". Set false for a non-destructive confirm.
  danger?: boolean;
  /// While true, both buttons disable and the confirm label gets a trailing
  /// ellipsis (e.g. "Delete…") — mirrors TrashSheet/AccountSheet's busy state.
  busy?: boolean;
  onConfirm: () => void;
  onClose: () => void;
}

/// Shared confirmation dialog (issue #143) — built on the existing bottom
/// `Sheet` so every confirm prompt in the app (bottom sheet on mobile,
/// centered dialog >=720px) shares one look. Gates a destructive action
/// behind an explicit tap instead of firing instantly.
export default function ConfirmDialog({
  title,
  body,
  confirmLabel,
  cancelLabel = "Cancel",
  danger = true,
  busy = false,
  onConfirm,
  onClose,
}: Props) {
  return (
    <Sheet onClose={busy ? undefined : onClose}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: "var(--t-xl)",
          fontWeight: 800,
          marginBottom: 6,
        }}
      >
        {title}
      </div>
      <div
        style={{
          fontSize: "var(--t-sm)",
          color: "var(--ink-muted)",
          marginBottom: 16,
          lineHeight: 1.5,
        }}
      >
        {body}
      </div>
      <button
        className={danger ? undefined : "btn-primary"}
        disabled={busy}
        onClick={onConfirm}
        style={
          danger
            ? {
                background: "var(--danger)",
                color: "#ffffff",
                border: "none",
                padding: "13px 20px",
                borderRadius: 8,
                width: "100%",
                fontFamily: "Inter, sans-serif",
                fontSize: "var(--t-base)",
                fontWeight: 600,
                cursor: busy ? "default" : "pointer",
                opacity: busy ? 0.5 : 1,
              }
            : undefined
        }
      >
        {busy ? `${confirmLabel}…` : confirmLabel}
      </button>
      <div style={{ marginTop: 8 }}>
        <button className="btn-ghost" disabled={busy} onClick={onClose}>
          {cancelLabel}
        </button>
      </div>
    </Sheet>
  );
}
