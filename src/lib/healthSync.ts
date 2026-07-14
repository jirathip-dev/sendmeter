import { Capacitor } from "@capacitor/core";
import type { Session } from "@supabase/supabase-js";
import { SendLogHealth } from "sendlog-health";

const IS_NATIVE = Capacitor.isNativePlatform();

/// Hand the native health plugin the current session so its own Supabase
/// client can read sessions / write health_metrics — including on a
/// background wake, when the WebView's supabase-js session isn't reachable.
/// Called on every auth event, mirroring the watch auth relay. No-op on web.
export function relayHealthSession(session: Session | null): void {
  if (!IS_NATIVE || !session) return;
  void SendLogHealth.setSession({
    accessToken: session.access_token,
    refreshToken: session.refresh_token,
  });
}

/// After sign-in: request HealthKit access, register background delivery, and
/// do one immediate sync. Safe to call on every launch (auth prompt shows
/// once; startBackgroundSync is idempotent). No-op on web.
export async function startHealthBackgroundSync(): Promise<void> {
  if (!IS_NATIVE) return;
  try {
    await SendLogHealth.requestAuthorization();
    await SendLogHealth.startBackgroundSync();
    await SendLogHealth.syncNow();
  } catch {
    // HealthKit denied / unavailable — readiness just stays empty
  }
}

/// Re-read HealthKit and re-upsert today's metrics now (e.g. right after a
/// clear). No-op on web; the device otherwise picks data back up on its next
/// background delivery, so a failure here is not fatal to the clear.
export async function syncHealthNow(): Promise<void> {
  if (!IS_NATIVE) return;
  try {
    await SendLogHealth.syncNow();
  } catch {
    // plugin unavailable — safe to ignore
  }
}
