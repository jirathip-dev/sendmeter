import { useState } from "react";
import { supabase } from "../lib/supabase";

export default function LoginScreen() {
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function sendLink() {
    if (!email.trim()) return;
    setSending(true);
    setError(null);
    const { error: err } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: window.location.origin },
    });
    setSending(false);
    if (err) {
      setError(err.message);
    } else {
      setSent(true);
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
            SEND LOG
          </div>
          <div className="topbar-sub">Climbing Periodization</div>
        </div>

        <div className="card">
          {sent ? (
            <div style={{ textAlign: "center", padding: "12px 0" }}>
              <div
                style={{
                  fontFamily: "'Syne', sans-serif",
                  fontSize: 18,
                  fontWeight: 800,
                  marginBottom: 8,
                }}
              >
                Check your email
              </div>
              <div style={{ fontSize: 12, color: "#7a8a9a", marginBottom: 16 }}>
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
                  fontFamily: "'Syne', sans-serif",
                  fontSize: 18,
                  fontWeight: 800,
                  marginBottom: 4,
                }}
              >
                Sign in
              </div>
              <div style={{ fontSize: 12, color: "#7a8a9a" }}>
                Enter your email and we'll send you a magic link. No password
                needed.
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
                onKeyDown={(e) => e.key === "Enter" && sendLink()}
              />
              {error && (
                <div style={{ fontSize: 11, color: "#f87171", marginTop: 8 }}>
                  {error}
                </div>
              )}
              <div style={{ marginTop: 14 }}>
                <button
                  className="btn-primary"
                  disabled={sending}
                  onClick={sendLink}
                >
                  {sending ? "Sending…" : "Send Magic Link"}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
