import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { deleteAccount, deleteHealthMetrics } from "../lib/repo";
import { resyncHealthHistory } from "../lib/healthSync";
import { resolveHealthClearResult, type HealthClearOutcome } from "../lib/healthClearOutcome";
import HealthClearedStatus from "./HealthClearedStatus";
import { authRedirectUrl } from "../lib/authRedirect";
import {
  getAuthDiagnosticEvents,
  getAuthDiagnosticsStatus,
  type NullSessionReason,
} from "../lib/authDiagnostics";
import type { AuthEventStoreKind } from "../lib/authEventStore";
import { buildTag, loadBuildTag } from "../lib/appVersion";
import {
  watchStatusPresentation,
  type WatchStatusPresentation,
} from "../lib/watchBuild";
import { useWatchInfo } from "../hooks/useWatchInfo";
import type { QueueRemainderChoice, SignOut, SignOutPhase } from "../lib/signOut";
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
import SignOutPendingSheet from "./SignOutPendingSheet";
import ThemeSection from "./ThemeSection";

interface Props {
  onClose: () => void;
  onSignOut: SignOut;
}

// #494 (N5): "Clear health data & resync"'s success copy differs by
// platform — native's device-resync claim is only true where a device
// actually runs one.
const IS_NATIVE = Capacitor.isNativePlatform();

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

function AppleWatchStatusCard({ status }: { status: WatchStatusPresentation }) {
  const color =
    status.tone === "positive"
      ? "var(--success)"
      : status.tone === "warning"
        ? "var(--warning)"
        : "var(--ink-faint)";
  return (
    <div className="watch-status-card">
      <div className="watch-status-heading">
        <span
          className="watch-status-dot"
          style={{ background: color, color }}
          aria-hidden="true"
        />
        <div style={{ fontSize: "var(--t-base)", fontWeight: 700, color: "var(--ink)" }}>
          {status.title}
        </div>
      </div>
      <div className="watch-status-detail" style={{ color: status.tone === "warning" ? color : undefined }}>
        {status.detail}
      </div>
      {(status.watchDisplay || status.phoneDisplay) && (
        <div className="watch-status-meta">
          {status.watchDisplay ? `Watch ${status.watchDisplay}` : ""}
          {status.watchDisplay && status.phoneDisplay ? " · " : ""}
          {status.phoneDisplay ? `iPhone ${status.phoneDisplay}` : ""}
        </div>
      )}
      {status.reportedAt !== undefined && (
        <div className="watch-status-meta">
          Last reported {new Date(status.reportedAt * 1000).toLocaleString()}
        </div>
      )}
    </div>
  );
}

export default function AccountSheet({ onClose, onSignOut }: Props) {
  const bumpRealtime = useRealtimeBump();
  const toast = useToast();
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
  // #487 (F4) / #494 (N4, F2): null = "Clear & resync" hasn't run yet (drives
  // the same UI branch `cleared` used to). Once set, it's one of three
  // outcomes, not a boolean: "resynced" (green — the rebuild actually
  // succeeded), "nothingToClear" (neutral — no history existed to rebuild;
  // must not promise a resync or tell the user to retry a remedy that can't
  // fix a denied HealthKit permission, which also has zero rows), "failed"
  // (amber — real data existed and the rebuild came back empty). See
  // healthClearOutcome.ts for why this needs three states, not `!resynced`.
  const [clearOutcome, setClearOutcome] = useState<HealthClearOutcome | null>(null);
  const [signingOut, setSigningOut] = useState(false);
  // #273: the sign-out drains the offline recording queue first, which on a
  // bad connection is the slow part — say which is happening rather than
  // showing "Signing out…" for the length of a network timeout.
  const [signOutPhase, setSignOutPhase] = useState<SignOutPhase | null>(null);
  // Non-null while the user is being asked about recordings that wouldn't
  // upload. `resolve` is the suspended `onRemainder` promise below.
  const [remainder, setRemainder] = useState<{
    count: number;
    resolve: (choice: QueueRemainderChoice) => void;
  } | null>(null);
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

  const watchStatus = watchStatusPresentation(useWatchInfo());

  // Signed-in identity for the Account & Security group. getSession reads the
  // locally stored session — no network round-trip on every sheet open.
  const [email, setEmail] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    void supabase.auth.getSession().then(({ data: { session } }) => {
      if (alive && session?.user.email) setEmail(session.user.email);
    });
    return () => {
      alive = false;
    };
  }, []);

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
    const outcome = await onSignOut({
      onPhase: setSignOutPhase,
      // #273: only ever called when the drain left something behind, so this
      // resolver sits idle on every ordinary sign-out. The promise is what
      // keeps the whole sequence one call — the queue must not be discarded
      // before the answer, nor the sign-out issued after it is forgotten.
      onRemainder: (count) =>
        new Promise<QueueRemainderChoice>((resolve) => {
          setRemainder({ count, resolve });
        }),
    });
    // On a real sign-out the auth gate unmounts this sheet once the session
    // clears — nothing below runs. It only comes back when the user backed
    // out at the prompt, and then the sheet has to look untouched again.
    setRemainder(null);
    if (!outcome.signedOut) {
      setSigningOut(false);
      setSignOutPhase(null);
    }
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
      const deletedCount = await deleteHealthMetrics();
      // The delete above is a HARD delete (#487, F4) — from this point on
      // the rows are gone no matter what happens next, so nothing below may
      // throw its way into the catch block and report the clear itself as
      // failed. Rebuild the whole recent history from HealthKit (no-op on
      // web; the delete stands regardless and the device backfills on next
      // delivery) — but read whether that resync actually succeeded, so the
      // toast/banner can say so honestly instead of always claiming
      // "resyncing".
      const { ok: resynced } = await resyncHealthHistory();
      // Force the readiness/recovery cards to refetch — the DELETE's own
      // realtime echo doesn't reliably arrive (esp. in the native WebView),
      // which left stale scores on screen after a clear.
      bumpRealtime();
      setConfirmingClear(false);
      // #494 (N4) / review finding F2: `resolveHealthClearResult` is the
      // one place that turns these two raw results into what the user
      // sees — do nothing here but forward its output, so the decision is
      // exercised by the same call this component makes in
      // healthClearOutcome.test.ts, not re-derived inline.
      const { outcome, toast: toastText } = resolveHealthClearResult(deletedCount, resynced);
      setClearOutcome(outcome);
      toast(toastText);
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

  // Group headings for the single scrollable Settings surface (#577) — one
  // visual level above the uppercase subsection eyebrows.
  const groupTitle = (text: string) => (
    <div
      style={{
        fontSize: "var(--t-base)",
        fontWeight: 700,
        color: "var(--ink)",
        marginBottom: 12,
      }}
    >
      {text}
    </div>
  );

  return (
    <Sheet title="Settings" onClose={onClose}>
      <div style={{ paddingTop: 12 }}>
        {/* General */}
        {groupTitle("General")}
        <ThemeSection />

        {/* Health & Devices */}
        <div style={{ marginTop: 28, paddingTop: 18, borderTop: "1px solid var(--hairline)" }}>
          {groupTitle("Health & Devices")}
          <div>
            {eyebrow("Health data")}
            {clearOutcome ? (
              <HealthClearedStatus outcome={clearOutcome} native={IS_NATIVE} />
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

            {watchStatus && (
              <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
                {eyebrow("Apple Watch")}
                <AppleWatchStatusCard status={watchStatus} />
              </div>
            )}
          </div>
        </div>

        {/* Account & Security */}
        <div style={{ marginTop: 28, paddingTop: 18, borderTop: "1px solid var(--hairline)" }}>
          {groupTitle("Account & Security")}
          <div>
            {email && (
              <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 14, lineHeight: 1.5 }}>
                Signed in as {email}
              </div>
            )}

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
                          className="btn-danger btn-inline"
                          disabled={removingId === p.id}
                          onClick={() => void runRemovePasskey(p.id)}
                          style={{ flexShrink: 0 }}
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

            <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
              {eyebrow("Session")}
              <button
                className="btn-ghost"
                disabled={signingOut}
                onClick={() => void handleSignOut()}
              >
                {!signingOut
                  ? "Sign out"
                  : signOutPhase === "draining"
                    ? "Uploading recordings…"
                    : "Signing out…"}
              </button>
            </div>

            <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
              {eyebrow("Danger zone", true)}
              {!showDanger ? (
                  <button
                    className="btn-ghost btn-inline"
                    style={{ fontSize: "var(--t-sm)" }}
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
                    className="btn-danger"
                    disabled={deleting}
                    onClick={() => void runDelete()}
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
                  className="btn-danger btn-inline"
                  onClick={() => setConfirmingDelete(true)}
                >
                  Delete account…
                </button>
              )}
            </div>
          </div>
        </div>

        {/* About & Support */}
        <div style={{ marginTop: 28, paddingTop: 18, borderTop: "1px solid var(--hairline)" }}>
          {groupTitle("About & Support")}
          <div>
            {eyebrow("Help")}
            <button className="btn-ghost" onClick={() => setShowHelp(true)}>
              Help & FAQ
            </button>

            <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
              {eyebrow("Version")}
              <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)" }}>
                {build ? `Sendmeter ${build}` : "Sendmeter (web)"}
              </div>
            </div>

            <div style={{ marginTop: 22, paddingTop: 16, borderTop: "1px solid var(--hairline)" }}>
              {eyebrow("Troubleshooting")}
              <details className="troubleshooting-details">
                <summary>Sign-in diagnostics</summary>
                <div className="troubleshooting-body">
                  <div>
                    {build ? `Sendmeter ${build}` : "Sendmeter (web)"} ·{" "}
                    {STORE_LABELS[diagStatus.store]}
                  </div>
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
              </details>
            </div>
          </div>
        </div>

        {error && (
          <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 14 }}>
            {error}
          </div>
        )}
      </div>

      {showHelp && <HelpSheet onClose={() => setShowHelp(false)} />}

      {remainder && (
        <SignOutPendingSheet
          count={remainder.count}
          onChoose={remainder.resolve}
        />
      )}

    </Sheet>
  );
}
