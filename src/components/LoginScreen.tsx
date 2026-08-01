import { useState } from "react";
import { Capacitor } from "@capacitor/core";
import { supabase } from "../lib/supabase";
import { authRedirectUrl } from "../lib/authRedirect";
import { signInWithApple } from "../lib/appleAuth";
import { passkeysSupported, signInWithPasskey } from "../lib/passkeys";

const IS_NATIVE = Capacitor.isNativePlatform();

export default function LoginScreen() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  // The iPhone app defaults to password sign-in, but magic links now reopen
  // the app via its custom scheme (deepLinks.ts), so either works.
  const [mode, setMode] = useState<"magic" | "password">(
    IS_NATIVE ? "password" : "magic",
  );
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function sendLink() {
    if (!email.trim()) return;
    setBusy(true);
    setError(null);
    const { error: err } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: authRedirectUrl() },
    });
    setBusy(false);
    if (err) {
      setError(err.message);
    } else {
      setSent(true);
    }
  }

  async function signInPassword() {
    if (!email.trim() || !password) return;
    setBusy(true);
    setError(null);
    const { error: err } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    });
    setBusy(false);
    if (err) {
      setError(
        err.message.toLowerCase().includes("invalid login credentials")
          ? "Wrong email or password. You can also sign in with a magic link, Apple, or a passkey."
          : err.message,
      );
    }
    // success: onAuthStateChange flips the app to signed-in
  }

  async function signInApple() {
    setBusy(true);
    setError(null);
    try {
      await signInWithApple();
      // native: signInWithIdToken sets the session → onAuthStateChange routes.
      // web: redirects to Apple and back.
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Apple sign-in failed";
      // User-cancelled the native sheet — not an error worth showing.
      if (!/cancel/i.test(msg)) setError(msg);
    } finally {
      setBusy(false);
    }
  }

  async function passkeySignIn() {
    setBusy(true);
    setError(null);
    try {
      await signInWithPasskey();
      // session set → onAuthStateChange routes to the app
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Passkey sign-in failed";
      if (!/cancel|not allowed|aborted/i.test(msg)) setError(msg);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="app-shell">
      <div
        className="content-area"
        style={{
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
        }}
      >
        <div style={{ marginBottom: 24, textAlign: "center" }}>
          <div
            className="topbar-title"
            style={{ fontSize: 28, marginBottom: 4 }}
          >
            SENDMETER
          </div>
          <div className="topbar-sub">Climbing Periodization</div>
        </div>

        <div className="card">
          {sent ? (
            <div style={{ textAlign: "center", padding: "12px 0" }}>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontSize: "var(--t-lg)",
                  fontWeight: 800,
                  marginBottom: 8,
                }}
              >
                Check your email
              </div>
              <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)", marginBottom: 16 }}>
                We sent a sign-in link to {email.trim()}. Open it on this
                device to continue.
              </div>
              <button className="btn-ghost" onClick={() => setSent(false)}>
                Use a different email
              </button>
            </div>
          ) : (
            <div>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontSize: "var(--t-lg)",
                  fontWeight: 800,
                  marginBottom: 4,
                }}
              >
                Sign in
              </div>
              <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-muted)" }}>
                {mode === "magic"
                  ? "Enter your email and we'll send you a magic link. No password needed."
                  : "Sign in with your email and password."}
              </div>
              <span className="field-label">Email</span>
              <input
                className="field"
                type="email"
                aria-label="Email"
                inputMode="email"
                autoComplete="email"
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                onKeyDown={(e) =>
                  e.key === "Enter" && mode === "magic" && sendLink()
                }
              />
              {mode === "password" && (
                <>
                  <span className="field-label">Password</span>
                  <input
                    className="field"
                    type="password"
                    aria-label="Password"
                    autoComplete="current-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && signInPassword()}
                  />
                </>
              )}
              {error && (
                <div style={{ fontSize: "var(--t-xs)", color: "var(--danger)", marginTop: 8 }}>
                  {error}
                </div>
              )}
              <div style={{ marginTop: 14 }}>
                {mode === "magic" ? (
                  <button
                    className="btn-primary"
                    disabled={busy}
                    onClick={sendLink}
                  >
                    {busy ? "Sending…" : "Send Magic Link"}
                  </button>
                ) : (
                  <button
                    className="btn-primary"
                    disabled={busy}
                    onClick={signInPassword}
                  >
                    {busy ? "Signing in…" : "Sign In"}
                  </button>
                )}
              </div>
              {/* Divider + Continue with Apple */}
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 10,
                  margin: "16px 0 12px",
                  color: "var(--ink-faint)",
                  fontSize: "var(--t-2xs)",
                }}
              >
                <span style={{ flex: 1, height: 1, background: "var(--hairline)" }} />
                OR
                <span style={{ flex: 1, height: 1, background: "var(--hairline)" }} />
              </div>
              <button
                onClick={signInApple}
                disabled={busy}
                style={{
                  width: "100%",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 8,
                  background: "var(--ink)",
                  color: "var(--bg)",
                  border: "none",
                  borderRadius: 8,
                  padding: "13px 20px",
                  fontFamily: "Inter, sans-serif",
                  fontSize: "var(--t-base)",
                  fontWeight: 600,
                  cursor: "pointer",
                  WebkitTapHighlightColor: "transparent",
                }}
              >
                <svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                  <path d="M17.05 12.04c-.02-2.02 1.65-2.99 1.72-3.04-.94-1.37-2.4-1.56-2.92-1.58-1.24-.13-2.42.73-3.05.73-.63 0-1.6-.71-2.63-.69-1.35.02-2.6.79-3.3 2-1.4 2.44-.36 6.05 1.01 8.03.67.97 1.47 2.06 2.52 2.02 1.01-.04 1.39-.65 2.62-.65 1.22 0 1.57.65 2.63.63 1.09-.02 1.78-.99 2.45-1.96.77-1.12 1.09-2.21 1.11-2.27-.02-.01-2.13-.82-2.16-3.25zM15.03 6.06c.56-.68.94-1.62.83-2.56-.81.03-1.79.54-2.37 1.21-.52.6-.98 1.56-.86 2.48.9.07 1.83-.46 2.4-1.13z"/>
                </svg>
                {busy ? "…" : "Continue with Apple"}
              </button>
              {passkeysSupported && (
                <button
                  className="btn-ghost"
                  style={{ marginTop: 10 }}
                  disabled={busy}
                  onClick={passkeySignIn}
                >
                  Sign in with a passkey
                </button>
              )}
              <div style={{ marginTop: 12, textAlign: "center" }}>
                <button
                  onClick={() => {
                    setMode(mode === "magic" ? "password" : "magic");
                    setError(null);
                  }}
                  style={{
                    background: "none",
                    border: "none",
                    color: "var(--ink-muted)",
                    fontSize: "var(--t-xs)",
                    cursor: "pointer",
                    fontFamily: "Inter, sans-serif",
                    textDecoration: "underline",
                  }}
                >
                  {mode === "magic"
                    ? "Sign in with password instead"
                    : "Sign in with magic link instead"}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
