import { useState } from "react";
import { deleteAccount, deleteHealthMetrics } from "../lib/repo";
import { syncHealthNow } from "../lib/healthSync";
import { supabase } from "../lib/supabase";
import HelpSheet from "./HelpSheet";
import Sheet from "./Sheet";
import ThemeSection from "./ThemeSection";

interface Props {
  onClose: () => void;
  onSignOut: () => Promise<{ error: Error | null }>;
}

export default function AccountSheet({ onClose, onSignOut }: Props) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [confirmingClear, setConfirmingClear] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [cleared, setCleared] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [showHelp, setShowHelp] = useState(false);

  async function handleSignOut() {
    setSigningOut(true);
    await onSignOut();
    // auth gate unmounts this sheet once the session clears; no need to
    // reset signingOut or call onClose.
  }

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

  async function runClearHealth() {
    setClearing(true);
    setError(null);
    try {
      await deleteHealthMetrics();
      // Ask the device to re-ingest correct data right away (no-op on web /
      // until the native health plugin ships; the delete stands regardless).
      await syncHealthNow();
      setConfirmingClear(false);
      setCleared(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to clear health data");
    } finally {
      setClearing(false);
    }
  }

  return (
    <Sheet onClose={onClose}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: 20,
          fontWeight: 800,
          marginBottom: 6,
        }}
      >
        Account
      </div>

        <ThemeSection />

        {/* App / watch password */}
        <div
          style={{
            marginTop: 22,
            paddingTop: 14,
            borderTop: "1px solid var(--hairline)",
          }}
        >
          {done ? (
            <div style={{ fontSize: 12, color: "var(--success)" }}>
              Password set. Use it to sign in on the iPhone app. Web login
              keeps using magic links. The Watch app now signs in
              automatically from your iPhone — this password is only a
              fallback for it.
            </div>
          ) : (
            <div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)" }}>
                Set a password for signing in on the iPhone app. The Watch
                app signs in automatically from your iPhone once you're
                signed in here — this password is only a fallback for it.
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
                <button
                  className="btn-primary"
                  disabled={saving}
                  onClick={save}
                >
                  {saving ? "Saving…" : "Set Password"}
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Help & FAQ */}
        <div
          style={{
            marginTop: 22,
            paddingTop: 14,
            borderTop: "1px solid var(--hairline)",
          }}
        >
          <button className="btn-ghost" onClick={() => setShowHelp(true)}>
            Help & FAQ
          </button>
        </div>

        {/* Sign out */}
        <div
          style={{
            marginTop: 22,
            paddingTop: 14,
            borderTop: "1px solid var(--hairline)",
          }}
        >
          <button
            className="btn-ghost"
            disabled={signingOut}
            onClick={() => void handleSignOut()}
          >
            {signingOut ? "Signing out…" : "Sign out"}
          </button>
        </div>

        {showHelp && <HelpSheet onClose={() => setShowHelp(false)} />}

        {/* Health data — clear & resync (destructive but recoverable, so
            kept out of the account-deletion danger zone below) */}
        <div
          style={{
            marginTop: 22,
            paddingTop: 14,
            borderTop: "1px solid var(--hairline)",
          }}
        >
          <div
            style={{
              fontSize: 10,
              color: "var(--ink-muted)",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 8,
            }}
          >
            Health data
          </div>
          {cleared ? (
            <div style={{ fontSize: 12, color: "var(--success)" }}>
              Health data cleared. Your device will re-sync fresh metrics from
              Apple Health shortly.
            </div>
          ) : confirmingClear ? (
            <div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12 }}>
                Deletes all stored daily health metrics (HRV, resting heart
                rate, sleep, readiness). Your device re-reads them from Apple
                Health afterward — use this if the wrong person's data got
                recorded to your account.
              </div>
              <button
                className="btn-primary"
                disabled={clearing}
                onClick={() => void runClearHealth()}
              >
                {clearing ? "Clearing…" : "Clear & resync"}
              </button>
              <div style={{ marginTop: 8 }}>
                <button
                  className="btn-ghost"
                  disabled={clearing}
                  onClick={() => setConfirmingClear(false)}
                >
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <button
              className="btn-ghost"
              onClick={() => setConfirmingClear(true)}
            >
              Clear health data & resync…
            </button>
          )}
        </div>

        {/* Danger zone */}
        <div
          style={{
            marginTop: 22,
            paddingTop: 14,
            borderTop: "1px solid var(--hairline)",
          }}
        >
          <div
            style={{
              fontSize: 10,
              color: "var(--danger)",
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              marginBottom: 8,
            }}
          >
            Danger zone
          </div>
          {confirmingDelete ? (
            <div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12 }}>
                This permanently deletes your account and every session,
                recording, workout, and health metric. There is no undo.
              </div>
              <button
                disabled={deleting}
                onClick={() => void runDelete()}
                style={{
                  background: "var(--danger)",
                  color: "#ffffff",
                  border: "none",
                  padding: "13px 20px",
                  borderRadius: 8,
                  width: "100%",
                  fontFamily: "Inter, sans-serif",
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
                borderColor: "rgba(255,69,58,0.35)",
                color: "var(--danger)",
              }}
              onClick={() => setConfirmingDelete(true)}
            >
              Delete account…
            </button>
          )}
        </div>

        {error && (
          <div style={{ fontSize: 11, color: "var(--danger)", marginTop: 10 }}>
            {error}
          </div>
        )}

      <div style={{ marginTop: 14 }}>
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      </div>
    </Sheet>
  );
}
