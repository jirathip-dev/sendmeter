import { useState } from "react";
import { Capacitor } from "@capacitor/core";
import { supabase } from "../lib/supabase";

const IS_NATIVE = Capacitor.isNativePlatform();

export default function LoginScreen() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  // Magic links can't redirect back into the native app shell, so the
  // iPhone app defaults to password sign-in (same password as the watch).
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
      options: { emailRedirectTo: window.location.origin },
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
          ? "Wrong email or password. Set a password via the Watch button on the web app first."
          : err.message,
      );
    }
    // success: onAuthStateChange flips the app to signed-in
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
            SEND LOG
          </div>
          <div className="topbar-sub">Climbing Periodization</div>
        </div>

        <div className="card">
          {sent ? (
            <div style={{ textAlign: "center", padding: "12px 0" }}>
              <div
                style={{
                  fontFamily: "Inter, sans-serif",
                  fontSize: 18,
                  fontWeight: 800,
                  marginBottom: 8,
                }}
              >
                Check your email
              </div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)", marginBottom: 16 }}>
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
                  fontSize: 18,
                  fontWeight: 800,
                  marginBottom: 4,
                }}
              >
                Sign in
              </div>
              <div style={{ fontSize: 12, color: "var(--ink-muted)" }}>
                {mode === "magic"
                  ? "Enter your email and we'll send you a magic link. No password needed."
                  : "Sign in with your email and password."}
              </div>
              <span className="field-label">Email</span>
              <input
                className="field"
                type="email"
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
                    autoComplete="current-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && signInPassword()}
                  />
                </>
              )}
              {error && (
                <div style={{ fontSize: 11, color: "var(--danger)", marginTop: 8 }}>
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
                    fontSize: 11,
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
