import { useState } from "react";
import { supabase } from "../lib/supabase";

/// Shown after the user follows a password-reset email link (PASSWORD_RECOVERY).
/// They have a temporary session; setting a new password here finalizes the
/// reset and drops them into the app.
export default function RecoveryScreen({ onDone }: { onDone: () => void }) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    if (password.length < 8) return setError("Use at least 8 characters.");
    if (password !== confirm) return setError("Passwords don't match.");
    setSaving(true);
    setError(null);
    const { error: err } = await supabase.auth.updateUser({ password });
    setSaving(false);
    if (err) setError(err.message);
    else onDone();
  }

  return (
    <div className="app-shell">
      <div className="content-area" style={{ display: "flex", alignItems: "center" }}>
        <div style={{ width: "100%", maxWidth: 400, margin: "0 auto" }}>
          <div className="topbar-title" style={{ fontSize: 24, textAlign: "center" }}>
            SENDMETER
          </div>
          <div className="topbar-sub" style={{ textAlign: "center", marginBottom: 24 }}>
            Climbing Periodization
          </div>
          <div className="card">
            <div style={{ fontFamily: "Inter, sans-serif", fontSize: "var(--t-lg)", fontWeight: 800 }}>
              Set a new password
            </div>
            <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginTop: 4 }}>
              Choose a new password for your account (at least 8 characters).
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
              <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 10 }}>
                {error}
              </div>
            )}
            <div style={{ marginTop: 16 }}>
              <button className="btn-primary" disabled={saving} onClick={save}>
                {saving ? "Saving…" : "Set password & continue"}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
