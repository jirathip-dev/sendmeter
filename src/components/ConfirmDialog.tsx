import type { ReactNode } from "react";
import Sheet from "./Sheet";

interface Props {
  title: string;
  body: ReactNode;
  confirmLabel: string;
  cancelLabel?: string;
  /// Confirm button uses the shared contrast-safe `.btn-danger` recipe —
  /// matching TrashSheet's "Delete forever" and AccountSheet's
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
        className={danger ? "btn-danger" : "btn-primary"}
        // #171: the one confirm/destructive step gets the heavier tick, so
        // "delete forever" doesn't feel like the Cancel below it. While busy
        // the button is `disabled`, which the resolver reads as inert — no
        // tick for a tap that does nothing.
        data-haptic="medium"
        disabled={busy}
        onClick={onConfirm}
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
