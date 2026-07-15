import type { ReactNode } from "react";

interface Props {
  /// Omit to make the sheet non-dismissable by backdrop click (e.g. a
  /// required-choice sheet like the legacy-data import prompt).
  onClose?: () => void;
  /// Fix the sheet to full screen height instead of hugging its content
  /// (e.g. the Phases sheet, whose height otherwise jumps as it loads).
  fullHeight?: boolean;
  children: ReactNode;
}

export default function Sheet({ onClose, fullHeight, children }: Props) {
  return (
    <div
      className="modal-bg"
      onClick={(e) => onClose && e.target === e.currentTarget && onClose()}
    >
      <div className={`modal-sheet${fullHeight ? " full" : ""}`}>
        <div className="modal-handle" />
        {children}
      </div>
    </div>
  );
}
