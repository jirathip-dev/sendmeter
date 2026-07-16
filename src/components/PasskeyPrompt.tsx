import { useEffect, useState } from "react";
import { Capacitor } from "@capacitor/core";
import { addPasskey, listPasskeys, passkeysSupported } from "../lib/passkeys";

const KEY = "sendmeter:passkey-prompt";

/// One-time post-login upsell: "add a passkey for faster sign-in". Dismisses
/// itself (persisted) once the user creates one or taps Not now. Web-only for
/// now — native passkeys depend on the Associated Domains bridge and aren't
/// verified yet, so we don't offer a flow that might fail there.
export default function PasskeyPrompt() {
  // Start hidden while we check for an existing passkey — a user who already
  // enrolled one (e.g. on another device) shouldn't be nudged again. Fail open
  // (show) only after confirming they have none.
  const disabled = !passkeysSupported || Capacitor.isNativePlatform();
  const [state, setState] = useState<"checking" | "show" | "hidden">(() =>
    disabled || (typeof localStorage !== "undefined" && localStorage.getItem(KEY) === "done")
      ? "hidden"
      : "checking",
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (state !== "checking") return;
    let alive = true;
    listPasskeys()
      .then((list) => alive && setState(list.length > 0 ? "hidden" : "show"))
      .catch(() => alive && setState("show"));
    return () => {
      alive = false;
    };
  }, [state]);

  if (state !== "show") return null;

  function finish() {
    localStorage.setItem(KEY, "done");
    setState("hidden");
  }

  async function create() {
    setBusy(true);
    setError(null);
    try {
      await addPasskey();
      finish();
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Couldn't add passkey";
      // Cancelled the OS prompt — leave the card so they can retry.
      if (!/cancel|not allowed|aborted/i.test(msg)) setError(msg);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div
      className="card"
      style={{
        marginBottom: 12,
        border: "1px solid var(--card-border)",
        background: "color-mix(in srgb, var(--primary) 8%, var(--canvas))",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 6 }}>
        <span
          aria-hidden="true"
          style={{
            fontSize: 18,
            lineHeight: 1,
            width: 32,
            height: 32,
            borderRadius: 8,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: "color-mix(in srgb, var(--primary) 16%, transparent)",
          }}
        >
          🔑
        </span>
        <div style={{ fontFamily: "Inter, sans-serif", fontWeight: 800, fontSize: 15 }}>
          Faster sign-in with a passkey
        </div>
      </div>
      <div style={{ fontSize: 12, color: "var(--ink-muted)", lineHeight: 1.5, marginBottom: 12 }}>
        Skip passwords and magic links — sign in with Face ID or Touch ID next
        time. It syncs across your Apple devices.
      </div>
      {error && (
        <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 10 }}>{error}</div>
      )}
      <div className="grid-2">
        <button className="btn-ghost" disabled={busy} onClick={finish}>
          Not now
        </button>
        <button className="btn-primary" disabled={busy} onClick={() => void create()}>
          {busy ? "Setting up…" : "Add passkey"}
        </button>
      </div>
    </div>
  );
}
