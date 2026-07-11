import { useState } from "react";
import { supabase } from "../lib/supabase";

interface Props {
  onClose: () => void;
}

// Sets a password on the current account so the standalone watch app can
// sign in with email + password (free tier can't put OTP codes in emails).
export default function WatchPasswordSheet({ onClose }: Props) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
          Watch access
        </div>
        {done ? (
          <div>
            <div style={{ fontSize: 12, color: "#4ade80", marginBottom: 16 }}>
              Password set. On your watch, sign in with your email and this
              password. Web login keeps using magic links.
            </div>
            <button className="btn-primary" onClick={onClose}>
              Done
            </button>
          </div>
        ) : (
          <div>
            <div style={{ fontSize: 12, color: "#7a8a9a", marginBottom: 4 }}>
              Set a password for signing in on your Apple Watch. You'll only
              type it there once.
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
            {error && (
              <div style={{ fontSize: 11, color: "#f87171", marginTop: 8 }}>
                {error}
              </div>
            )}
            <div style={{ marginTop: 14 }}>
              <button className="btn-primary" disabled={saving} onClick={save}>
                {saving ? "Saving…" : "Set Password"}
              </button>
            </div>
            <div style={{ marginTop: 10 }}>
              <button className="btn-ghost" onClick={onClose}>
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
