import { Capacitor } from "@capacitor/core";
import type { Session } from "@supabase/supabase-js";
import { SendLogHealth } from "sendlog-health";
import type { ReadinessRefreshResult } from "sendlog-health";
import { fetchTodayHealthSignature } from "./repo/health";
import { healthSignaturesEqual } from "./healthSignature";

export { healthSignaturesEqual } from "./healthSignature";

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
/// "Health data cleared · resyncing" toast from AccountSheet. Source alone is
/// no longer sufficient to gate the foreground toast, though — see `changed`
/// below (#146).
export type HealthSyncSource = "background" | "foreground" | "resync" | "watch";

/// Records that a sync attempt happened (drives the "Last synced Xm ago" line
/// on ReadinessCard, unconditionally — that's correct/wanted feedback for
/// every sync attempt, changed or not) and notifies listeners. `changed`
/// reflects whether today's health_metrics row's content actually differed
/// before vs. after this sync — the native plugin always re-upserts the
/// biometric columns "locked or not" (see HealthSyncManager), so "the plugin
/// call resolved" does NOT imply "new data landed"; only App.tsx's foreground
/// toast reads `changed` (source === "foreground" && changed), but it's
/// carried for every source so the event shape doesn't vary by call site.
function recordHealthSync(source: HealthSyncSource, changed = false): void {
  try {
    localStorage.setItem(SYNCED_AT_KEY, String(Date.now()));
    // Nudge any mounted readiness card to re-read the timestamp.
    window.dispatchEvent(
      new CustomEvent("sendmeter:health-synced", { detail: { source, changed } }),
    );
  } catch {
    /* ignore */
  }
}

let readinessListenerStarted = false;

/// Native watch requests execute entirely in the iPhone plugin. This listener
/// is only the phone-UI notification/re-read hook; it does not perform HealthKit
/// work and never carries credentials or raw samples. The local latest-result
/// read covers a result that completed before the WebView mounted its listener.
function ensureReadinessListener(): void {
  if (!IS_NATIVE || readinessListenerStarted) return;
  readinessListenerStarted = true;
  void SendLogHealth.addListener(
    "readinessRefresh",
    (result: ReadinessRefreshResult) => {
      if (result.status === "success") recordHealthSync("watch", true);
    },
  );
  void SendLogHealth.getLatestReadiness()
    .then((result) => {
      if (result?.status === "success") recordHealthSync("watch", true);
    })
    .catch(() => {
      // A pre-#520 native shell simply has no method/result yet.
    });
}

/// Hand the native health plugin the current access token so its own Supabase
/// client can read sessions / write health_metrics — including on a
/// background wake, when the WebView's supabase-js session isn't reachable.
/// Called on every auth event and every foreground, mirroring the watch auth
/// relay. A null session (sign-out) clears the plugin's stored token too, so
/// a later background wake can't keep writing as that user. No-op on web.
///
/// The refresh token is deliberately not relayed (#265) — see
/// `watchAuthRelay.ts` and the plugin's `definitions.ts`. Only supabase-js
/// here owns rotation.
export function relayHealthSession(session: Session | null): void {
  if (!IS_NATIVE) return;
  ensureReadinessListener();
  if (session) {
    void SendLogHealth.setSession({ accessToken: session.access_token });
  } else {
    void SendLogHealth.clearSession();
  }
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
///
/// #146: the native plugin always re-upserts the biometric columns on every
/// call ("locked or not"), so a successful `syncNow()` does not by itself
/// mean anything new landed — compare today's row content before/after to
/// decide whether the foreground "Health data synced" toast is warranted.
export async function syncHealthNow(): Promise<void> {
  if (!IS_NATIVE) return;
  try {
    const before = await fetchTodayHealthSignature().catch(() => undefined);
    // #109: fired from useAuth's visibilitychange foreground listener, not
    // a user gesture — "automatic". There's no explicit user-refresh action
    // in the app yet; when one's added it should pass "manual" instead.
    await SendLogHealth.syncNow({ trigger: "automatic" });
    const after = await fetchTodayHealthSignature().catch(() => undefined);
    recordHealthSync("foreground", !healthSignaturesEqual(before, after));
  } catch {
    // plugin unavailable — safe to ignore
  }
}

/// Rebuild the whole recent health history from HealthKit (not just today) —
/// the native side of "Clear & resync". No-op on web (returns `ok: true`);
/// there the DELETE alone stands and the device backfills on its next
/// background delivery — that's a deliberate no-op, not a failure. A failure
/// here is not fatal to the clear: `deleteHealthMetrics` is a HARD delete
/// (#487, F4), so the rows are already gone by the time this runs regardless
/// of what it returns. What must NOT happen is reporting success when the
/// resync itself failed — the caller (AccountSheet's "Clear & resync") used
/// to swallow this silently and tell the user "cleared · resyncing" either
/// way, which is exactly the CLAUDE.md #264 pattern (an outcome reported as
/// success when it isn't) applied to the one irreversible action in the app.
/// Callers must use `ok` to show an honest "resync failed" state rather than
/// claiming the rebuild is in progress.
///
/// #494 (N4): a failure's `message` is carried back rather than discarded —
/// e.g. the native `HealthResyncFoundNoDataError` ("Resync found no Health
/// data to rebuild from — Health access may be denied, or your history is
/// genuinely empty for this window") used to be thrown away here, leaving
/// the caller no way to tell a genuinely-empty HealthKit history apart from
/// a real failure. `message` alone still can't make that distinction
/// reliably (the native comment explains why: `authorizationStatus` can't
/// tell denied from empty either) — see `healthClearFailed` in
/// `lib/healthClearOutcome.ts` for the discriminator the caller actually
/// uses (rows deleted vs. rows rebuilt). This field is for surfacing the
/// real reason when it IS a genuine failure, not for classifying it.
export async function resyncHealthHistory(): Promise<{ ok: boolean; message?: string }> {
  if (!IS_NATIVE) return { ok: true };
  try {
    await SendLogHealth.clearAndResync();
    recordHealthSync("resync");
    return { ok: true };
  } catch (e) {
    // plugin call failed (unavailable, HealthKit error, dead session, …) —
    // not fatal to the already-completed delete, but the caller must say so.
    return { ok: false, message: e instanceof Error ? e.message : undefined };
  }
}
