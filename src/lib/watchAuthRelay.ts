import { Capacitor } from "@capacitor/core";
import type { PluginListenerHandle } from "@capacitor/core";
import type { Session } from "@supabase/supabase-js";
import { SendLogAuthBridge } from "sendlog-auth-bridge";

const IS_NATIVE = Capacitor.isNativePlatform();

/// Relays the current session's **access token** to the paired Watch app so it
/// can sign in without its own login flow. Call on every auth state change
/// that carries a session (SIGNED_IN, TOKEN_REFRESHED, USER_UPDATED) and on
/// every foreground — access tokens are short-lived (1h) and the watch has no
/// way to renew one itself. A null session (SIGNED_OUT) clears it on the watch
/// too. No-op on web/no watch.
///
/// The refresh token is deliberately NOT relayed (#265). supabase-js on this
/// phone is the only holder that owns rotation; a second holder eventually
/// presents a token that has already been rotated, Supabase's reuse detection
/// treats that as a compromise and revokes the entire session family — which
/// is how a healthy session died in production on 2026-07-26, signing the
/// phone out along with the watch.
///
/// `guaranteed` is for answering a watch-initiated pull — see
/// `onWatchSessionRequest`.
export function relaySessionToWatch(
  session: Session | null,
  opts: { guaranteed?: boolean } = {},
): void {
  if (!IS_NATIVE) return;
  if (session) {
    void SendLogAuthBridge.setSession({
      accessToken: session.access_token,
      expiresAt: session.expires_at ?? 0,
      userId: session.user.id,
      ...(opts.guaranteed ? { guaranteed: true } : {}),
    });
  } else {
    void SendLogAuthBridge.clearSession();
  }
}

/// Register a handler for the watch's "relay me a fresh session" request
/// (fired when the watch's relayed access token expired and it's waiting on
/// the phone). The handler should fetch the current session and call
/// `relaySessionToWatch(session, { guaranteed: true })`.
///
/// Returns the `PluginListenerHandle` so callers can detach it. The previous
/// version discarded it, so `useAuth`'s cleanup had nothing to remove and every
/// remount left another listener attached to a stale closure (#266). Resolves
/// to null on web, where there is no listener to add.
export function onWatchSessionRequest(
  handler: () => void,
): Promise<PluginListenerHandle | null> {
  if (!IS_NATIVE) return Promise.resolve(null);
  return SendLogAuthBridge.addListener("sessionRequested", handler);
}
