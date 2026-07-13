import type { ReactNode } from "react";

interface Props {
  /// Omit to make the sheet non-dismissable by backdrop click (e.g. a
  /// required-choice sheet like the legacy-data import prompt).
  onClose?: () => void;
  children: ReactNode;
}

export default function Sheet({ onClose, children }: Props) {
  return (
    <div
      className="modal-bg"
      onClick={(e) => onClose && e.target === e.currentTarget && onClose()}
    >
      <div className="modal-sheet">
        <div className="modal-handle" />
        {children}
      </div>
    </div>
  );
}
