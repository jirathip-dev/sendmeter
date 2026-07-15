import { useState } from "react";
import { deleteAccount, deleteHealthMetrics } from "../lib/repo";
import { resyncHealthHistory } from "../lib/healthSync";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { supabase } from "../lib/supabase";
import HelpSheet from "./HelpSheet";
import Sheet from "./Sheet";
import ThemeSection from "./ThemeSection";

interface Props {
  onClose: () => void;
  onSignOut: () => Promise<{ error: Error | null }>;
}

export default function AccountSheet({ onClose, onSignOut }: Props) {
  const bumpRealtime = useRealtimeBump();
  const [resetting, setResetting] = useState(false);
  const [resetEmail, setResetEmail] = useState<string | null>(null);
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

  // Email-based password reset: send a recovery link to the account email.
  // Following it opens RecoveryScreen to set the new password.
  async function sendReset() {
    setResetting(true);
    setError(null);
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const email = user?.email;
    if (!email) {
      setError("No email on this account.");
      setResetting(false);
      return;
    }
    // No redirectTo — Supabase uses the project Site URL (sendmeter.app),
    // which handles the PASSWORD_RECOVERY event.
    const { error: err } = await supabase.auth.resetPasswordForEmail(email);
    setResetting(false);
    if (err) setError(err.message);
    else setResetEmail(email);
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
      // Rebuild the whole recent history from HealthKit (no-op on web; the
      // delete stands regardless and the device backfills on next delivery).
      await resyncHealthHistory();
      // Force the readiness/recovery cards to refetch — the DELETE's own
      // realtime echo doesn't reliably arrive (esp. in the native WebView),
      // which left stale scores on screen after a clear.
      bumpRealtime();
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

        {/* Password — collapsed action; expand to set or change it anytime */}
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
            Password
          </div>
          {resetEmail ? (
            <div style={{ fontSize: 12, color: "var(--success)", lineHeight: 1.5 }}>
              Reset link sent to {resetEmail}. Open it to set a new password.
            </div>
          ) : (
            <div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 10, lineHeight: 1.5 }}>
                Set or reset your password by email — we'll send a secure link.
              </div>
              <button
                className="btn-ghost"
                disabled={resetting}
                onClick={() => void sendReset()}
              >
                {resetting ? "Sending…" : "Send password reset email"}
              </button>
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
