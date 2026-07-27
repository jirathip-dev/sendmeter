import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { deleteAccount, deleteHealthMetrics } from "../lib/repo";
import { resyncHealthHistory } from "../lib/healthSync";
import { authRedirectUrl } from "../lib/authRedirect";
import {
  getAuthDiagnosticEvents,
  getAuthDiagnosticsStatus,
  type NullSessionReason,
} from "../lib/authDiagnostics";
import type { AuthEventStoreKind } from "../lib/authEventStore";
import { buildTag, loadBuildTag } from "../lib/appVersion";
import {
  loadWatchBuildInfo,
  watchBuildLine,
  watchSyncLine,
  type WatchBuildInfo,
  type WatchBuildTone,
} from "../lib/watchBuild";
import { pendingUploadsLine } from "../lib/pendingUploads";
import { usePendingUploads } from "../hooks/usePendingUploads";
import {
  addPasskey,
  listPasskeys,
  passkeysSupported,
  removePasskey,
  type PasskeyListItem,
} from "../lib/passkeys";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import { supabase } from "../lib/supabase";
import HelpSheet from "./HelpSheet";
import Sheet from "./Sheet";
import ThemeSection from "./ThemeSection";

interface Props {
  onClose: () => void;
  onSignOut: () => Promise<{ error: Error | null }>;
}

type TabId = "appearance" | "health" | "account";

const NULL_SESSION_LABELS: Record<NullSessionReason, string> = {
  "network-error": "Network error",
  revoked: "Session revoked",
  "storage-missing": "No stored session",
  "storage-unavailable": "Storage unavailable",
  "user-signed-out": "Signed out (by you)",
  "storage-wiped": "App storage wiped",
};

/// Where the diagnostics ring is being kept. Worth showing: "nothing
/// recorded" means something very different on a ring that only ever lived in
/// the WebView's localStorage (#202).
const STORE_LABELS: Record<AuthEventStoreKind, string> = {
  preferences: "Preferences (survives a WebView wipe)",
  "local-storage": "Browser storage",
  unavailable: "Not persisted",
};

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

/// One paired-watch diagnostics row: the watch's build (#228) or its
/// offline-queue state (#21). Shared so the pair reads as one block — the
/// actionable state (a build difference, a queue that isn't draining) has to
/// be readable as different from the muted lines at a glance, and the same way
/// in both.
function WatchDiagLine({
  line,
}: {
  line: { text: string; tone: WatchBuildTone; reportedAt?: number };
}) {
  return (
    <div
      style={{
        fontSize: "var(--t-xs)",
        color: line.tone === "warning" ? "var(--warning)" : "var(--ink-muted)",
        fontWeight: line.tone === "warning" ? 600 : undefined,
        lineHeight: 1.6,
      }}
    >
      {line.text}
      {line.reportedAt !== undefined
        ? ` · reported ${new Date(line.reportedAt * 1000).toLocaleString()}`
        : ""}
    </div>
  );
}

export default function AccountSheet({ onClose, onSignOut }: Props) {
  const bumpRealtime = useRealtimeBump();
  const toast = useToast();
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
  // Read once at mount — issue #202's on-device record of null-session
  // events (see authDiagnostics.ts). Read-only, so no need to re-read on an
  // interval; a relaunch remounts this sheet fresh anyway.
  const [authEvents] = useState(() => getAuthDiagnosticEvents());
  const [diagStatus] = useState(() => getAuthDiagnosticsStatus());
  // App version + build (#202): a recorded event is only attributable if the
  // build that produced it can be read off the same screen. Native-only —
  // `loadBuildTag` resolves to null on web.
  const [build, setBuild] = useState<string | null>(() => buildTag());
  useEffect(() => {
    let alive = true;
    void loadBuildTag().then((tag) => {
      if (alive) setBuild(tag);
    });
    return () => {
      alive = false;
    };
  }, []);

  // The paired watch's build (#228). The watch installs from TestFlight on
  // its own schedule, so it can sit builds behind the phone — and a watch on
  // a pre-#208 build still revokes this phone's session family. Null on web,
  // or if the native shell predates the plugin method.
  const [watchInfo, setWatchInfo] = useState<WatchBuildInfo | null>(null);
  useEffect(() => {
    let alive = true;
    void loadWatchBuildInfo().then((info) => {
      if (alive) setWatchInfo(info);
    });
    return () => {
      alive = false;
    };
  }, []);
  const watchLine = watchBuildLine(watchInfo);
  // The same report carries the watch's offline-queue depth (#21) — a workout
  // stuck in its upload queue is otherwise invisible until you pick the watch
  // up.
  const syncLine = watchSyncLine(watchInfo);
  // …and the same story for THIS device (#269): recordings queued locally
  // because the insert failed. Read live — the hook re-reads on foreground and
  // whenever anything queues or drains.
  const pendingLine = pendingUploadsLine(usePendingUploads());

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
      toast("Health data cleared · resyncing");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to clear health data");
    } finally {
      setClearing(false);
    }
  }

  const eyebrow = (text: string, danger = false) => (
    <div
      style={{
        fontSize: "var(--t-2xs)",
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
          fontSize: "var(--t-xl)",
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
              <div style={{ fontSize: "var(--t-sm)", color: "var(--success)", lineHeight: 1.5 }}>
                Reset link sent to {resetEmail}. Open it to set a new password.
              </div>
            ) : (
              <div>
                <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 10, lineHeight: 1.5 }}>
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
                  <div style={{ fontSize: "var(--t-sm)", color: "var(--success)", lineHeight: 1.5, marginBottom: 10 }}>
                    {passkeyMsg}
                  </div>
                )}
                {passkeys === null ? (
                  <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)" }}>Checking…</div>
                ) : passkeys.length > 0 ? (
                  <div>
                    {passkeys.map((p) => (
                      <div key={p.id} className="pk-row">
                        <div style={{ minWidth: 0 }}>
                          <div style={{ fontSize: "var(--t-base)", fontWeight: 600 }}>
                            {p.friendly_name || "Passkey"}
                          </div>
                          <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)" }}>
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
                            borderColor: "rgba(229,116,58,0.35)",
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
                    <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 10, lineHeight: 1.5 }}>
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
              <div style={{ fontSize: "var(--t-sm)", color: "var(--success)", lineHeight: 1.5 }}>
                Health data cleared. Your device will re-sync fresh metrics from
                Apple Health shortly.
              </div>
            ) : confirmingClear ? (
              <div>
                <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
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
                <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 10, lineHeight: 1.5 }}>
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

              <div style={{ marginTop: 14 }}>
                <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 6 }}>
                  Recent sign-in diagnostics
                </div>
                <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.6 }}>
                  {build ? `Sendmeter ${build}` : "Sendmeter (web)"} ·{" "}
                  {STORE_LABELS[diagStatus.store]}
                </div>
                {watchLine && <WatchDiagLine line={watchLine} />}
                {syncLine && <WatchDiagLine line={syncLine} />}
                {/* #269: the phone's own upload queue, next to the watch's —
                    the two devices each hold recordings that haven't reached
                    Supabase yet, and only one of them used to say so. Always
                    rendered, including the empty state: a row that vanishes
                    when there's nothing pending is indistinguishable from a
                    row that's broken. */}
                <WatchDiagLine line={pendingLine} />
                {diagStatus.webviewWiped && (
                  <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", lineHeight: 1.6 }}>
                    App storage was wiped since last launch — the session went
                    with it.
                  </div>
                )}
                {authEvents.length === 0 ? (
                  <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", lineHeight: 1.6 }}>
                    {/* An empty list must say so. A section that renders
                        nothing (as this one did on the c07c071 build) is
                        indistinguishable from a section that isn't there. */}
                    No events recorded.
                  </div>
                ) : (
                  authEvents.slice(0, 5).map((e, i) => (
                    <div
                      key={i}
                      style={{
                        fontSize: "var(--t-xs)",
                        color: "var(--ink-muted)",
                        lineHeight: 1.6,
                        marginTop: 4,
                      }}
                    >
                      {NULL_SESSION_LABELS[e.reason]} · {new Date(e.lastAt).toLocaleString()}
                      {e.count > 1 ? ` · ×${e.count}` : ""}
                      {/* Dedupe survives relaunch, so one row can span days.
                          Showing only lastAt would read as a single moment and
                          hide how long the incident has been running. */}
                      {e.count > 1 && e.firstAt !== e.lastAt
                        ? ` · since ${new Date(e.firstAt).toLocaleString()}`
                        : ""}
                      {/* Origin: "auth-js signed us out" vs "we asked and got
                          null" are different bugs (#202). */}
                      {e.authEvent ? ` · ${e.authEvent}` : e.source ? ` · ${e.source}` : ""}
                      {e.lastGoodAt && (
                        <div style={{ opacity: 0.75 }}>
                          last valid session {new Date(e.lastGoodAt).toLocaleString()}
                          {e.lastGoodExpiresAt
                            ? `, token expiring ${new Date(e.lastGoodExpiresAt).toLocaleString()}`
                            : ""}
                        </div>
                      )}
                      {e.build && e.build !== build ? (
                        <div style={{ opacity: 0.75 }}>on build {e.build}</div>
                      ) : null}
                    </div>
                  ))
                )}
              </div>
            </div>

            <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
              {eyebrow("Danger zone", true)}
              {!showDanger ? (
                <button
                  className="btn-ghost btn-inline"
                  style={{ color: "var(--ink-muted)", fontSize: "var(--t-sm)" }}
                  onClick={() => setShowDanger(true)}
                >
                  Reveal delete option
                </button>
              ) : confirmingDelete ? (
                <div>
                  <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 12, lineHeight: 1.5 }}>
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
                      fontSize: "var(--t-base)",
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
                  style={{ borderColor: "rgba(229,116,58,0.35)", color: "var(--danger)" }}
                  onClick={() => setConfirmingDelete(true)}
                >
                  Delete account…
                </button>
              )}
            </div>
          </div>
        )}

        {error && (
          <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 14 }}>
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
