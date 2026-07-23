import { Capacitor } from "@capacitor/core";
import type { Session } from "@supabase/supabase-js";
import { SendLogHealth } from "sendlog-health";

const IS_NATIVE = Capacitor.isNativePlatform();

const SYNCED_AT_KEY = "sendmeter:health-synced-at";

/// Epoch ms of the last successful health sync, or null (SL-31). Drives the
/// "Last synced" line on the readiness card so a sync gives visible feedback.
export function healthLastSyncedAt(): number | null {
  try {
    const v = localStorage.getItem(SYNCED_AT_KEY);
    return v ? Number(v) : null;
  } catch {
    return null;
  }
}

/// Which call path triggered the sync — carried on the event `detail` so
/// listeners can react differently: the readiness card always re-reads the
/// timestamp, but a "synced" toast only makes sense for a foreground sync the
/// user is actively looking at. The cold-launch background sync fires on
/// every app open and would be noisy; the resync path already gets its own
/// "Health data cleared · resyncing" toast from AccountSheet.
export type HealthSyncSource = "background" | "foreground" | "resync";

function recordHealthSync(source: HealthSyncSource): void {
  try {
    localStorage.setItem(SYNCED_AT_KEY, String(Date.now()));
    // Nudge any mounted readiness card to re-read the timestamp.
    window.dispatchEvent(
      new CustomEvent("sendmeter:health-synced", { detail: { source } }),
    );
  } catch {
    /* ignore */
  }
}

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
    // #109: cold launch, not a user gesture — "automatic", so the native
    // side's after-noon readiness lock applies (see ReadinessWritePolicy).
    await SendLogHealth.syncNow({ trigger: "automatic" });
    recordHealthSync("background");
  } catch {
    // HealthKit denied / unavailable — readiness just stays empty
  }
}

/// Re-read HealthKit and re-upsert today's metrics now (e.g. app foreground).
/// No-op on web; the device otherwise picks data back up on its next background
/// delivery, so a failure here is not fatal.
export async function syncHealthNow(): Promise<void> {
  if (!IS_NATIVE) return;
  try {
    // #109: fired from useAuth's visibilitychange foreground listener, not
    // a user gesture — "automatic". There's no explicit user-refresh action
    // in the app yet; when one's added it should pass "manual" instead.
    await SendLogHealth.syncNow({ trigger: "automatic" });
    recordHealthSync("foreground");
  } catch {
    // plugin unavailable — safe to ignore
  }
}

/// Rebuild the whole recent health history from HealthKit (not just today) —
/// the native side of "Clear & resync". No-op on web; there the DELETE alone
/// stands and the device backfills on its next background delivery. A failure
/// here is not fatal to the clear (the rows are already deleted).
export async function resyncHealthHistory(): Promise<void> {
  if (!IS_NATIVE) return;
  try {
    await SendLogHealth.clearAndResync();
    recordHealthSync("resync");
  } catch {
    // plugin unavailable — safe to ignore
  }
}
