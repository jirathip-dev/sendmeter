import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { deleteAccount, deleteHealthMetrics } from "../lib/repo";
import { resyncHealthHistory } from "../lib/healthSync";
import { authRedirectUrl } from "../lib/authRedirect";
import {
  addPasskey,
  listPasskeys,
  passkeysSupported,
  removePasskey,
  type PasskeyListItem,
} from "../lib/passkeys";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { supabase } from "../lib/supabase";
import HelpSheet from "./HelpSheet";
import Sheet from "./Sheet";
import ThemeSection from "./ThemeSection";

interface Props {
  onClose: () => void;
  onSignOut: () => Promise<{ error: Error | null }>;
}

type TabId = "appearance" | "health" | "account";

const TABS: { id: TabId; label: string; icon: ReactNode }[] = [
  {
    id: "appearance",
    label: "Appearance",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="12" r="9" />
        <path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none" />
      </svg>
    ),
  },
  {
    id: "health",
    label: "Health",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M20.8 6.6a5 5 0 0 0-8.8-2.2A5 5 0 0 0 3.2 6.6c-1 3 1.4 6 8.8 11 7.4-5 9.8-8 8.8-11z" />
      </svg>
    ),
  },
  {
    id: "account",
    label: "Account",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="12" cy="8.2" r="3.4" />
        <path d="M5 20c1.2-3.4 3.8-5 7-5s5.8 1.6 7 5" />
      </svg>
    ),
  },
];

export default function AccountSheet({ onClose, onSignOut }: Props) {
  const bumpRealtime = useRealtimeBump();
  const [tab, setTab] = useState<TabId>("appearance");
  const [resetting, setResetting] = useState(false);
  const [resetEmail, setResetEmail] = useState<string | null>(null);
  const [addingPasskey, setAddingPasskey] = useState(false);
  const [passkeyMsg, setPasskeyMsg] = useState<string | null>(null);
  // null = still checking; array = enrolled passkeys. Drives whether we show
  // "Add a passkey" or the enrolled list (with per-key Remove).
  const [passkeys, setPasskeys] = useState<PasskeyListItem[] | null>(null);
  const [removingId, setRemovingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showDanger, setShowDanger] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [confirmingClear, setConfirmingClear] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [cleared, setCleared] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [showHelp, setShowHelp] = useState(false);

  useEffect(() => {
    if (!passkeysSupported) return;
    let alive = true;
    listPasskeys()
      .then((list) => alive && setPasskeys(list))
      .catch(() => alive && setPasskeys([]));
    return () => {
      alive = false;
    };
  }, []);

  async function handleSignOut() {
    setSigningOut(true);
    await onSignOut();
    // auth gate unmounts this sheet once the session clears; no need to
    // reset signingOut or call onClose.
  }

  async function runAddPasskey() {
    setAddingPasskey(true);
    setError(null);
    try {
      await addPasskey();
      setPasskeyMsg("Passkey added. You can now sign in with it.");
      // Reconcile with the server list (real id/name for a later Remove).
      listPasskeys()
        .then(setPasskeys)
        .catch(() => {});
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Couldn't add passkey";
      if (!/cancel|not allowed|aborted/i.test(msg)) setError(msg);
    } finally {
      setAddingPasskey(false);
    }
  }

  async function runRemovePasskey(id: string) {
    setRemovingId(id);
    setError(null);
    try {
      await removePasskey(id);
      setPasskeys((list) => (list ?? []).filter((p) => p.id !== id));
      setPasskeyMsg(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Couldn't remove passkey");
    } finally {
      setRemovingId(null);
    }
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
    // Redirect back to wherever the reset was started — the native app (custom
    // scheme) or the web origin — so app-initiated resets reopen the app.
    const { error: err } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: authRedirectUrl(),
    });
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

  const eyebrow = (text: string, danger = false) => (
    <div
      style={{
        fontSize: 10,
        color: danger ? "var(--danger)" : "var(--ink-muted)",
        textTransform: "uppercase",
        letterSpacing: "0.1em",
        marginBottom: 10,
      }}
    >
      {text}
    </div>
  );

  return (
    <Sheet onClose={onClose}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: 20,
          fontWeight: 800,
        }}
      >
        Account
      </div>

      {/* Tabs */}
      <div className="acct-tabs">
        {TABS.map((t) => (
          <button
            key={t.id}
            className={`acct-tab${tab === t.id ? " active" : ""}`}
            onClick={() => setTab(t.id)}
          >
            {t.icon}
            {t.label}
          </button>
        ))}
      </div>

      {/* Panel */}
      <div style={{ paddingTop: 12, minHeight: 180 }}>
        {tab === "appearance" && <ThemeSection />}

        {tab === "account" && (
          <div>
            {/* Password */}
            {eyebrow("Password")}
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

            {/* Passkeys */}
            {passkeysSupported && (
              <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
                {eyebrow("Passkey")}
                {passkeyMsg && (
                  <div style={{ fontSize: 12, color: "var(--success)", lineHeight: 1.5, marginBottom: 10 }}>
                    {passkeyMsg}
                  </div>
                )}
                {passkeys === null ? (
                  <div style={{ fontSize: 12, color: "var(--ink-muted)" }}>Checking…</div>
                ) : passkeys.length > 0 ? (
                  <div>
                    {passkeys.map((p) => (
                      <div key={p.id} className="pk-row">
                        <div style={{ minWidth: 0 }}>
                          <div style={{ fontSize: 13, fontWeight: 600 }}>
                            {p.friendly_name || "Passkey"}
                          </div>
                          <div style={{ fontSize: 11, color: "var(--ink-muted)" }}>
                            Added {new Date(p.created_at).toLocaleDateString()}
                          </div>
                        </div>
                        <button
                          className="btn-ghost btn-inline"
                          disabled={removingId === p.id}
                          onClick={() => void runRemovePasskey(p.id)}
                          style={{
                            flexShrink: 0,
                            color: "var(--danger)",
                            borderColor: "rgba(255,69,58,0.35)",
                          }}
                        >
                          {removingId === p.id ? "Removing…" : "Remove"}
                        </button>
                      </div>
                    ))}
                    <button
                      className="btn-ghost"
                      disabled={addingPasskey}
                      onClick={() => void runAddPasskey()}
                      style={{ marginTop: 12 }}
                    >
                      {addingPasskey ? "Adding…" : "Add another passkey"}
                    </button>
                  </div>
                ) : (
                  <div>
                    <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 10, lineHeight: 1.5 }}>
                      Add a passkey to sign in with Face ID / Touch ID — no
                      password or email needed.
                    </div>
                    <button
                      className="btn-ghost"
                      disabled={addingPasskey}
                      onClick={() => void runAddPasskey()}
                    >
                      {addingPasskey ? "Adding…" : "Add a passkey"}
                    </button>
                  </div>
                )}
              </div>
            )}
          </div>
        )}

        {tab === "health" && (
          <div>
            {eyebrow("Health data")}
            {cleared ? (
              <div style={{ fontSize: 12, color: "var(--success)", lineHeight: 1.5 }}>
                Health data cleared. Your device will re-sync fresh metrics from
                Apple Health shortly.
              </div>
            ) : confirmingClear ? (
              <div>
                <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
                  Deletes all stored daily health metrics (HRV, resting heart
                  rate, sleep, readiness). Your device re-reads them fresh from
                  Apple Health afterward.
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
              <div>
                <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 10, lineHeight: 1.5 }}>
                  Clear all stored health metrics and re-sync them fresh from
                  Apple Health.
                </div>
                <button className="btn-ghost" onClick={() => setConfirmingClear(true)}>
                  Clear health data & resync…
                </button>
              </div>
            )}
          </div>
        )}

        {tab === "account" && (
          <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
            {eyebrow("Help")}
            <button className="btn-ghost" onClick={() => setShowHelp(true)}>
              Help & FAQ
            </button>

            <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
              {eyebrow("Session")}
              <button
                className="btn-ghost"
                disabled={signingOut}
                onClick={() => void handleSignOut()}
              >
                {signingOut ? "Signing out…" : "Sign out"}
              </button>
            </div>

            <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
              {eyebrow("Danger zone", true)}
              {!showDanger ? (
                <button
                  className="btn-ghost btn-inline"
                  style={{ color: "var(--ink-muted)", fontSize: 12 }}
                  onClick={() => setShowDanger(true)}
                >
                  Reveal delete option
                </button>
              ) : confirmingDelete ? (
                <div>
                  <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
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
                  style={{ borderColor: "rgba(255,69,58,0.35)", color: "var(--danger)" }}
                  onClick={() => setConfirmingDelete(true)}
                >
                  Delete account…
                </button>
              )}
            </div>
          </div>
        )}

        {error && (
          <div style={{ fontSize: 11, color: "var(--danger)", marginTop: 14 }}>
            {error}
          </div>
        )}
      </div>

      {showHelp && <HelpSheet onClose={() => setShowHelp(false)} />}

      <div style={{ marginTop: 16 }}>
        <button className="btn-ghost" onClick={onClose}>
          Close
        </button>
      </div>
    </Sheet>
  );
}
