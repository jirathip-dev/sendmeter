import type { QueueRemainderChoice } from "../lib/signOut";
import Sheet from "./Sheet";

interface Props {
  /// Recordings that could not be uploaded before signing out (#273). Always
  /// ≥1 — this sheet is never shown for an empty queue, which is the whole
  /// reason it isn't an unconditional "are you sure?".
  count: number;
  onChoose: (choice: QueueRemainderChoice) => void;
}

/// The remainder prompt from #273's sign-out policy (written down in the
/// policy block in `recordingQueue.ts`). Not a ConfirmDialog: there are three
/// real answers here, and which is destructive is not the usual way round —
/// KEEPING the data is the safe choice, so it leads, and dismissing the sheet
/// means "don't sign out yet" rather than picking either.
export default function SignOutPendingSheet({ count, onChoose }: Props) {
  const items = `${count} recording${count === 1 ? "" : "s"}`;
  return (
    <Sheet onClose={() => onChoose("cancel")}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: "var(--t-xl)",
          fontWeight: 800,
          marginBottom: 6,
        }}
      >
        {items} not uploaded
      </div>
      <div
        style={{
          fontSize: "var(--t-sm)",
          color: "var(--ink-muted)",
          marginBottom: 16,
          lineHeight: 1.5,
        }}
      >
        {count === 1 ? "It's" : "They're"} still waiting to reach the server —
        usually that means no connection. Keep {count === 1 ? "it" : "them"} and{" "}
        {count === 1 ? "it uploads" : "they upload"} the next time you sign in
        to this account on this device. Delete and {count === 1 ? "it's" : "they're"}{" "}
        gone for good.
      </div>
      <button className="btn-primary" onClick={() => onChoose("keep")}>
        Sign out, keep on this device
      </button>
      <div style={{ marginTop: 8 }}>
        <button
          className="btn-ghost"
          // #171: the destructive step gets the heavier tick so it doesn't feel
          // like the plain choice above it.
          data-haptic="medium"
          onClick={() => onChoose("discard")}
          style={{ borderColor: "rgba(229,116,58,0.35)", color: "var(--danger)" }}
        >
          Delete {count === 1 ? "it" : "them"} and sign out
        </button>
      </div>
      <div style={{ marginTop: 8 }}>
        <button className="btn-ghost" onClick={() => onChoose("cancel")}>
          Stay signed in
        </button>
      </div>
    </Sheet>
  );
}
