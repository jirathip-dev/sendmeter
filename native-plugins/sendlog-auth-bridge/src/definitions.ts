import type { PluginListenerHandle } from "@capacitor/core";

/// Watch→phone live-workout beat, relayed over WatchConnectivity (Bluetooth)
/// for a sub-second in-app mirror. Same snake_case shape as the
/// live_workouts row, with dates as epoch SECONDS.
export interface LiveWorkoutMessage {
  status: "live" | "ended";
  started_at?: number;
  hr?: number;
  attempt_count?: number;
  active_kcal?: number;
  elevation_gain_m?: number;
  climbing?: boolean;
  climbing_since?: number;
  rest_started_at?: number;
  rest_target_s?: number;
  updated_at: number;
}

/// Watch→phone live force-gauge beat (SL-87), ~2 Hz while measuring plus one
/// on every status transition. WC-only — no Supabase fallback (a gauge stream
/// has no business heartbeating the network).
export interface LiveForceMessage {
  status: "connected" | "measuring" | "idle";
  kg?: number;
  peak_kg?: number;
  elapsed_ms?: number;
  session_count?: number;
  tag?: string;
  side?: string;
  updated_at: number;
  /// SL-95: a downsampled trailing ~3s window of `[t_ms, kg]` pairs, `t_ms`
  /// relative to this hold's start (same clock as `elapsed_ms`) — only
  /// present (non-empty) while `status === "measuring"`. The phone re-anchors
  /// each point to wall-clock time using `updated_at`/`elapsed_ms` and
  /// accumulates its own rolling buffer (see `useLiveForce.ts`); this field
  /// is one beat's slice, not the full history.
  spark?: [number, number][];
}

/// Verdict on the paired watch's build vs the phone's (#228). Computed in
/// Swift (`WatchBuildReport.status` in SendLogWatchCore) so the comparison is
/// unit-tested on Linux CI rather than living in a view. The three
/// "no build to show" cases stay distinct on purpose: a watch that has never
/// reported must never read as up to date.
export type WatchBuildStatus =
  /// No watch paired, or a device that can't have one (iPad).
  | "not-paired"
  /// Watch paired, Sendmeter not installed on it.
  | "app-not-installed"
  /// Installed, but it has never sent a message this phone install saw.
  | "not-reported"
  | "match"
  | "watch-behind"
  | "watch-ahead"
  /// Different, but the build numbers aren't orderable.
  | "differs"
  /// WCSession hasn't activated yet, or the phone's own build is unreadable.
  | "unknown";

/// Verdict on the watch's offline upload queues (#21), computed in Swift
/// (`WatchBuildReport.syncStatus`) for the same reason as the build verdict.
/// "empty" and "not-reported" stay distinct: a watch that has never reported a
/// count must not render as a healthy, drained queue.
export type WatchSyncStatus =
  | "not-paired"
  | "app-not-installed"
  /// Installed, but no queue depth has ever arrived — nothing is known.
  | "not-reported"
  /// WCSession hasn't activated yet.
  | "unknown"
  /// Reported zero pending items.
  | "empty"
  /// A few items waiting — normal right after an offline session.
  | "pending"
  /// Enough queued that the watch probably isn't draining at all.
  | "backed-up";

export interface WatchBuildInfo {
  status: WatchBuildStatus;
  supported: boolean;
  activated: boolean;
  paired: boolean;
  appInstalled: boolean;
  /// Present only once the watch has actually reported.
  watchVersion?: string;
  watchBuild?: string;
  /// `"1.4.0 (57)"`.
  watchDisplay?: string;
  /// Epoch SECONDS of the last report.
  reportedAt?: number;
  /// This phone's own `"1.4.0 (57)"`, for rendering the pair together.
  phoneDisplay?: string;

  /// The watch's offline-queue state (#21). Absent entirely on a native shell
  /// whose compiled-in plugin predates the field.
  syncStatus?: WatchSyncStatus;
  /// Items the watch last reported as waiting to upload. Present only once it
  /// has actually reported one — absent is "unknown", not zero.
  pendingSyncCount?: number;
  /// Epoch SECONDS of that count's report.
  pendingSyncReportedAt?: number;
  /// The count is old enough (>24h) that the queue may have drained since.
  pendingSyncStale?: boolean;
}

export interface SendLogAuthBridgePlugin {
  /// Relays the current Supabase **access token** to the paired Watch app via
  /// WatchConnectivity. No-op (resolves immediately) on platforms without
  /// a paired watch (iPad, or no watch paired) — see Plugin.swift.
  ///
  /// There is deliberately no `refreshToken` field (#265). The watch cannot
  /// refresh — only supabase-js on the phone owns rotation — and a copy of a
  /// rotating credential on the wrist is what replayed a twelve-hour-stale
  /// token in production and revoked the whole session family. Removing the
  /// field from the contract is the point: no call site can pass one.
  setSession(options: {
    accessToken: string;
    /// Unix SECONDS. A hint — the watch reads `exp` out of the token itself.
    expiresAt: number;
    /// A hint too; the watch reads `sub` from the token. Carried so a relay is
    /// readable in a log without decoding the JWT.
    userId?: string;
    /// Answer to a watch-initiated pull: also queue the payload with
    /// `transferUserInfo` so it is delivered exactly once even if the
    /// application context is unchanged or undelivered (#266).
    guaranteed?: boolean;
  }): Promise<void>;

  /// Tells the paired Watch app to sign out.
  clearSession(): Promise<void>;

  /// What build the paired watch last reported, and how it compares to this
  /// phone's (#228). Reads what the watch already piggybacked onto its
  /// existing messages — sends the watch nothing.
  getWatchInfo(): Promise<WatchBuildInfo>;

  /// Live-workout beats from the watch (native only; never fires on web).
  addListener(
    eventName: "liveWorkout",
    listener: (msg: LiveWorkoutMessage) => void,
  ): Promise<PluginListenerHandle>;

  /// Live force-gauge beats from the watch (native only; never fires on web).
  addListener(
    eventName: "liveForce",
    listener: (msg: LiveForceMessage) => void,
  ): Promise<PluginListenerHandle>;

  /// The watch asking the phone to relay a fresh session (its relayed token
  /// went stale). Answer by calling `setSession` with the current session.
  /// Native only; never fires on web.
  addListener(
    eventName: "sessionRequested",
    listener: () => void,
  ): Promise<PluginListenerHandle>;

  /// Build, queue depth, pairing, or install state changed. Consumers should
  /// re-read getWatchInfo(); the event deliberately carries no partial state.
  addListener(
    eventName: "watchInfoChanged",
    listener: () => void,
  ): Promise<PluginListenerHandle>;
}
