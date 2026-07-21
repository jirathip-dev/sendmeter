import { Capacitor } from "@capacitor/core";
import type { Session } from "@supabase/supabase-js";
import { SendLogAuthBridge } from "sendlog-auth-bridge";

const IS_NATIVE = Capacitor.isNativePlatform();

/// Relays the current session to the paired Watch app so it can sign in
/// without its own login flow. Call on every auth state change that carries
/// a session (SIGNED_IN, TOKEN_REFRESHED, USER_UPDATED) — refresh tokens
/// are single-use/rotating, so forwarding only on initial sign-in would
/// leave the watch holding a token that's already been rotated out. A null
/// session (SIGNED_OUT) clears it on the watch too. No-op on web/no watch.
export function relaySessionToWatch(session: Session | null): void {
  if (!IS_NATIVE) return;
  if (session) {
    void SendLogAuthBridge.setSession({
      accessToken: session.access_token,
      refreshToken: session.refresh_token,
      expiresAt: session.expires_at ?? 0,
    });
  } else {
    void SendLogAuthBridge.clearSession();
  }
}

/// Register a handler for the watch's "relay me a fresh session" request
/// (fired when the watch's stored token went stale and it's stuck on its
/// sign-in screen). The handler should fetch the current session and call
/// `relaySessionToWatch`. No-op on web / no watch.
export function onWatchSessionRequest(handler: () => void): void {
  if (!IS_NATIVE) return;
  void SendLogAuthBridge.addListener("sessionRequested", handler);
}
