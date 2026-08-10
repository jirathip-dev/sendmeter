import { Capacitor } from "@capacitor/core";
import type { Session } from "@supabase/supabase-js";
import { SendLogHealth } from "sendlog-health";
import type { ReadinessRefreshResult } from "sendlog-health";
import { fetchTodayHealthSignature } from "./repo/health";
import { healthSignaturesEqual } from "./healthSignature";
import { captureHandledOperationalFailure } from "./monitoring";

export { healthSignaturesEqual } from "./healthSignature";

const IS_NATIVE = Capacitor.isNativePlatform();

const SYNCED_AT_KEY = "sendmeter:health-synced-at";

/// The authenticated user the health-sync marker is currently scoped to.
/// Set synchronously (before any listener/bootstrap work) by
/// `relayHealthSession`, which is the same module-level-ref pattern
/// CLAUDE.md's stale-closure rule requires elsewhere in this file: an async
/// callback reads this live value at resolution time rather than a value it
/// closed over before its await, so an account switch mid-flight is visible
/// to it (#535).
let activeHealthUserId: string | null = null;

/// The most recent native readiness `requestId` this module has already
/// recorded a sync for. Guards against reporting the SAME native result
/// twice as a fresh change — e.g. the live listener push and the one-shot
/// catch-up read (`ensureReadinessCatchUpRead`) both observing the same
/// already-completed request. Deliberately module-scoped (not
/// once-per-launch) so it stays correct if a future caller replays more
/// than once in one process (#552).
let lastProcessedReadinessRequestId: string | null = null;

function syncedAtStorageKey(userId: string | null): string | null {
  return userId ? `${SYNCED_AT_KEY}:${userId}` : null;
}

/// Epoch ms of the last successful health sync, or null (SL-31). Drives the
/// "Last synced" line on the readiness card so a sync gives visible feedback.
/// Scoped to the currently active account (#535) — a marker written for a
/// previous account is never read back for a different one.
export function healthLastSyncedAt(): number | null {
  const key = syncedAtStorageKey(activeHealthUserId);
  if (!key) return null;
  try {
    const v = localStorage.getItem(key);
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
///
/// `at` defaults to "now", correct for every JS-initiated call site
/// (background/foreground/resync — the sync genuinely just happened here).
/// The watch-replay path (#535) passes the native `completedAt` explicitly
/// instead, since a cached result replayed on relaunch may have completed
/// hours earlier.
function recordHealthSync(source: HealthSyncSource, changed = false, at: number = Date.now()): void {
  const key = syncedAtStorageKey(activeHealthUserId);
  if (!key) return;
  try {
    localStorage.setItem(key, String(at));
    // Nudge any mounted readiness card to re-read the timestamp.
    window.dispatchEvent(
      new CustomEvent("sendmeter:health-synced", { detail: { source, changed } }),
    );
  } catch {
    /* ignore */
  }
}

/// Applies one native `ReadinessRefreshResult` — from either the live
/// listener push or a replayed `getLatestReadiness()` — as a health sync,
/// guarding against exactly the failure modes #535 was filed for:
///
/// - Account ownership: `result.accountUserId` (native
///   `ReadinessRefreshResult.accountUserId`, stamped on every current
///   result) is trusted over the dispatch-time `requestedForUserId`
///   snapshot when present, because the snapshot alone is a tautology on
///   the synchronous listener-push path (compared against
///   `activeHealthUserId` with no intervening await — a value against
///   itself) and does not cover the real contamination window: a relay to
///   account B can flip `activeHealthUserId` to B synchronously while
///   `setSession(B)` is still crossing the bridge, so a result native
///   completes and delivers while still bound to A arrives labelled with
///   A's own `accountUserId`, not B's. Only a legacy unstamped result (no
///   `accountUserId`) falls back to the snapshot-vs-current comparison —
///   still correct there, since that is the only signal available.
/// - Durable monotonic fence: `result.completedAt` (native epoch seconds)
///   is compared against the PERSISTED marker for that account
///   (`healthLastSyncedAt()`), not just an in-memory "already processed"
///   set. `lastProcessedReadinessRequestId` alone dies with the WebView, so
///   without this a cold-launch catch-up replay of the exact same cached
///   result would still look like a fresh change on every app open (the
///   cost `changed` exists to avoid — native's own `latestReadinessResult()`
///   reads without consuming). The same comparison also stops the marker
///   moving BACKWARDS: a genuinely fresh foreground sync (`Date.now()`)
///   must never be regressed to an older cached replay's earlier
///   `completedAt` (mirrors `ReadinessResultGate.shouldApply`'s completion
///   fence in `ios/App/SendLogWatchCore/.../ReadinessRefresh.swift`).
/// - `result.requestId` is additionally deduped against the last request
///   this module has processed IN THIS PROCESS, so two same-tick deliveries
///   of the identical request (e.g. the live push and the catch-up read
///   both observing it) don't do a redundant persisted-marker read/write.
function processReadinessResult(
  result: ReadinessRefreshResult | null | undefined,
  requestedForUserId: string | null,
): void {
  if (!result || result.status !== "success") return;
  if (!requestedForUserId) return;
  if (result.accountUserId) {
    if (result.accountUserId !== activeHealthUserId) return;
  } else if (activeHealthUserId !== requestedForUserId) {
    return;
  }
  if (result.requestId && result.requestId === lastProcessedReadinessRequestId) return;
  const completedAtMs =
    typeof result.completedAt === "number" ? result.completedAt * 1000 : Date.now();
  const priorSyncedAt = healthLastSyncedAt();
  if (priorSyncedAt !== null && completedAtMs <= priorSyncedAt) return;
  if (result.requestId) lastProcessedReadinessRequestId = result.requestId;
  recordHealthSync("watch", true, completedAtMs);
}

let readinessListenerRegistration: Promise<void> | null = null;
let readinessListenerFailureStreak = 0;
/// True once `addListener` has actually resolved with a usable handle —
/// distinct from `readinessListenerRegistration` being set, which also
/// covers a still-pending attempt. Used by `relayHealthSession` (#535 F4) to
/// know it's safe to re-fire the catch-up read for a newly-signed-in account
/// without risking firing it ahead of/during a registration that might still
/// fail (the exact ordering #534's review protected).
let readinessListenerInstalled = false;
let readinessCatchUpRequested = false;

/// Native watch requests execute entirely in the iPhone plugin. This listener
/// is only the phone-UI notification/re-read hook; it does not perform HealthKit
/// work and never carries credentials or raw samples.
///
/// #534: the dedupe guard used to be an optimistic boolean set before
/// `addListener` resolved — a rejected first attempt (transient bridge
/// failure, staggered native/web version) left it `true` forever, silently
/// disabling readiness notifications for the rest of the process. The guard
/// is now the registration promise itself, assigned synchronously before any
/// microtask runs, so concurrent callers coalesce onto the one in-flight
/// attempt (CLAUDE.md's #1 defect class — a dedupe guard must be set before
/// the first await). On failure the guard is cleared so the next
/// auth/foreground call retries; on success it stays set forever so a repeat
/// call is a no-op and never installs a second listener.
///
/// Honest limits of what this can detect (#534 review round 1 F1; tracked
/// for a real fix as #552): once a native counterpart genuinely exists,
/// Capacitor's iOS bridge gives `addListener()` no ack/nack from it — its
/// generated wrapper (`@capacitor/ios`'s `addListenerNative`) resolves as
/// soon as the outbound postMessage call returns locally (`postToNative`
/// swallows its own delivery errors), so a message that never reaches, or is
/// never processed by, a genuinely running native plugin still resolves here
/// with a normal-looking handle. That failure mode is invisible to this
/// promise and cannot be retried from the JS side alone.
///
/// What CAN be detected: a plugin with no native counterpart AT ALL (an iOS
/// build that dropped the native shell) makes `addListener()` reject
/// cleanly — Capacitor falls back to its plain, non-listener wrapper when
/// there's no PluginHeader to bind an event call against, and a synchronous
/// "not implemented" throw inside that wrapper's `.then` becomes a real
/// rejection, not a hang. `isPluginAvailable` below is a cheap pre-check for
/// that SAME permanent condition — it doesn't prevent an unsettled promise
/// (there isn't one to prevent; a header-less plugin already rejects on its
/// own), it just skips an attempt already known to be futile, reporting it
/// through the same failure path a genuine rejection would take. A handle
/// that resolves without a callable `remove` is treated the same as a
/// rejection too, as a defensive backstop.
///
/// Exported for direct unit testing only — the sole production caller is
/// `relayHealthSession` below.
export function ensureReadinessListener(): void {
  if (!IS_NATIVE || readinessListenerRegistration) return;
  if (!Capacitor.isPluginAvailable("SendLogHealth")) {
    reportReadinessListenerFailure(
      new Error('"SendLogHealth" is not available on this native build'),
    );
    return;
  }
  readinessListenerRegistration = SendLogHealth.addListener(
    "readinessRefresh",
    (result: ReadinessRefreshResult) => processReadinessResult(result, activeHealthUserId),
  )
    .then((handle) => {
      if (!handle || typeof handle.remove !== "function") {
        throw new Error("readiness listener registration returned no handle");
      }
      readinessListenerFailureStreak = 0;
      readinessListenerInstalled = true;
      ensureReadinessCatchUpRead();
    })
    .catch((error: unknown) => {
      readinessListenerRegistration = null;
      reportReadinessListenerFailure(error);
    });
}

/// `captureHandledOperationalFailure`'s own contract (monitoring.ts) is to
/// report only after recovery has finished and the operation is still
/// failed — a single failed attempt here might just be a transient blip that
/// self-heals on the very next foreground (#534 review round 2 F4), so this
/// only reports once a SECOND CONSECUTIVE attempt has also failed (the
/// operation's `dedupeForLaunch: true` then keeps it to one Sentry event for
/// the rest of the launch). A later successful registration resets the
/// streak, so a fresh run of failures after a success can still be reported.
function reportReadinessListenerFailure(error: unknown): void {
  readinessListenerFailureStreak += 1;
  if (readinessListenerFailureStreak >= 2) {
    captureHandledOperationalFailure("health.readiness-listener", error);
  }
}

/// A one-shot-PER-ACCOUNT local-latest-result read, covering a watch-
/// triggered result that completed before the WebView mounted the listener
/// above. Two callers: the listener's OWN successful-install branch (#534
/// review round 2 F3) — never a failed attempt, since a failed first attempt
/// used to spend this launch's one catch-up read on an outage the listener
/// never actually recovered from, so a watch refresh completing during that
/// outage would then never surface even once a later foreground installed
/// the listener successfully — and `relayHealthSession` re-firing it for a
/// LATER account once the listener is already durably installed (#535 F4),
/// since installation itself only ever happens once per process and would
/// otherwise never give a second account its own catch-up this launch.
/// Residual, left for #552: if registration never succeeds this launch, the
/// catch-up read never fires for that first account either — there is
/// currently no independent "ask once even without a live listener" path.
function ensureReadinessCatchUpRead(): void {
  if (readinessCatchUpRequested) return;
  readinessCatchUpRequested = true;
  const requestedForUserId = activeHealthUserId;
  void SendLogHealth.getLatestReadiness()
    .then((result) => processReadinessResult(result, requestedForUserId))
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
  // Scope the sync marker + replay dedupe to whichever account is now
  // authenticated — set synchronously, before any listener/bootstrap work,
  // so nothing below can read a stale account (#535). Tracked regardless of
  // platform: on web this only affects `healthLastSyncedAt()`'s bookkeeping,
  // since sync itself never runs there.
  const userId = session?.user.id ?? null;
  const accountChanged = userId !== activeHealthUserId;
  if (accountChanged) {
    lastProcessedReadinessRequestId = null;
    // The one-shot catch-up guard is per-launch AND per-account: without
    // this reset, an account signed into after the FIRST account's catch-up
    // already fired this launch would never get one of its own (#535 F4).
    readinessCatchUpRequested = false;
  }
  activeHealthUserId = userId;
  if (!IS_NATIVE) return;
  ensureReadinessListener();
  // `ensureReadinessListener()` only fires the catch-up read from its OWN
  // success branch, which does not run again once a registration from an
  // earlier account has already resolved — so a later account change needs
  // its own explicit fire here. Gated on `readinessListenerInstalled`
  // (rather than firing unconditionally) so this never races ahead of a
  // still-pending/still-failing first registration attempt.
  if (accountChanged && userId && readinessListenerInstalled) {
    ensureReadinessCatchUpRead();
  }
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
