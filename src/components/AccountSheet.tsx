import { useState } from "react";
import { deleteAccount } from "../lib/repo";
import { supabase } from "../lib/supabase";

interface Props {
  onClose: () => void;
}

export default function AccountSheet({ onClose }: Props) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);

  async function save() {
    if (password.length < 8) {
      setError("Use at least 8 characters.");
      return;
    }
    if (password !== confirm) {
      setError("Passwords don't match.");
      return;
    }
    setSaving(true);
    setError(null);
    const { error: err } = await supabase.auth.updateUser({ password });
    setSaving(false);
    if (err) setError(err.message);
    else setDone(true);
  }

  async function runDelete() {
    setDeleting(true);
    setError(null);
    try {
      await deleteAccount();
      // signed out by deleteAccount → auth gate takes over
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to delete account");
      setDeleting(false);
    }
  }

  return (
    <div
      className="modal-bg"
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="modal-sheet">
        <div className="modal-handle" />
        <div
          style={{
            fontFamily: "'Syne', sans-serif",
            fontSize: 20,
            fontWeight: 800,
            marginBottom: 6,
          }}
        >
          Account
        </div>

        {/* App / watch password */}
        {done ? (
          <div style={{ fontSize: 12, color: "#4ade80", marginBottom: 16 }}>
            Password set. Use it to sign in on your watch or iPhone app. Web
            login keeps using magic links.
          </div>
        ) : (
          <div>
            <div style={{ fontSize: 12, color: "#7a8a9a", marginBottom: 4 }}>
              Set a password for signing in on your Apple Watch or the iPhone
              app.
            </div>
            <span className="field-label">New password</span>
            <input
              className="field"
              type="password"
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
            <span className="field-label">Confirm password</span>
            <input
              className="field"
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && save()}
            />
            <div style={{ marginTop: 14 }}>
              <button className="btn-primary" disabled={saving} onClick={save}>
                {saving ? "Saving…" : "Set Password"}
              </button>
            </div>
          </div>
        )}

        {/* Danger zone */}
        <div
          style={{
            marginTop: 22,
            paddingTop: 14,
            borderTop: "1px solid #1a2030",
          }}
        >
          <div
            style={{
              fontSize: 10,
              color: "#f87171",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 8,
            }}
          >
            Danger zone
          </div>
          {confirmingDelete ? (
            <div>
              <div style={{ fontSize: 12, color: "#7a8a9a", marginBottom: 12 }}>
                This permanently deletes your account and every session,
                recording, workout, and health metric. There is no undo.
              </div>
              <button
                disabled={deleting}
                onClick={() => void runDelete()}
                style={{
                  background: "#f87171",
                  color: "#0a0c10",
                  border: "none",
                  padding: "13px 20px",
                  borderRadius: 8,
                  width: "100%",
                  fontFamily: "'DM Mono', monospace",
                  fontSize: 13,
                  fontWeight: 500,
                  cursor: "pointer",
                }}
              >
                {deleting ? "Deleting…" : "Yes, delete everything"}
              </button>
              <div style={{ marginTop: 8 }}>
                <button
                  className="btn-ghost"
                  disabled={deleting}
                  onClick={() => setConfirmingDelete(false)}
                >
                  Keep my account
                </button>
              </div>
            </div>
          ) : (
            <button
              className="btn-ghost"
              style={{
                borderColor: "rgba(248,113,113,0.35)",
                color: "#f87171",
              }}
              onClick={() => setConfirmingDelete(true)}
            >
              Delete account…
            </button>
          )}
        </div>

        {error && (
          <div style={{ fontSize: 11, color: "#f87171", marginTop: 10 }}>
            {error}
          </div>
        )}

        <div style={{ marginTop: 14 }}>
          <button className="btn-ghost" onClick={onClose}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
