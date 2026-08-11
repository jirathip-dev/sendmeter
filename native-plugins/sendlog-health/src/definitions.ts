import type { PluginListenerHandle } from "@capacitor/core";

/// Distinguishes an app-driven sync (foreground/cold-launch — the app has no
/// user-refresh gesture yet, so this is what every current call site sends)
/// from an explicit user-initiated one (reserved for a future pull-to-refresh
/// — always authoritative on the native side, bypassing the after-noon
/// readiness lock; see ReadinessWritePolicy in sendlog-health-core). Omitting
/// `trigger` on the native side fails safe as "automatic".
export type HealthSyncTrigger = "automatic" | "manual";

export type ReadinessRefreshStatus =
  | "success"
  | "failed"
  | "auth-required"
  | "cancelled"
  | "unsupported";

export type ReadinessFreshness = "fresh" | "cached" | "offline" | "unknown";

export interface ReadinessSnapshot {
  date: string;
  readiness?: number | null;
  zone?: string | null;
  computedAt?: number | null;
}

export interface ReadinessRefreshResult {
  kind?: "readinessResult";
  schemaVersion?: number;
  requestId: string;
  reason?: "launch" | "foreground" | "status-refresh" | string;
  sentAt?: number;
  startedAt?: number;
  completedAt?: number;
  status: ReadinessRefreshStatus;
  freshness: ReadinessFreshness;
  snapshot?: ReadinessSnapshot | null;
  /// UUID of the account whose phone-side session produced this result
  /// (native `ReadinessRefreshResult.accountUserId`, ios/App/SendLogWatchCore).
  /// Absent only for legacy unstamped native replies.
  accountUserId?: string;
  errorCode?: string;
  errorMessage?: string;
}

export interface SendLogHealthPlugin {
  /// Prompt for HealthKit read access (HRV, resting HR, sleep, body mass,
  /// respiratory rate). No-op resolve on non-iOS.
  requestAuthorization(): Promise<void>;

  /// Hands the plugin's own Supabase client the current **access token** so it
  /// can read sessions / write health_metrics from native code, including in
  /// the background (the WebView's supabase-js session isn't reachable
  /// natively). Relayed on every auth event, same as the watch auth bridge.
  ///
  /// No `refreshToken` field, deliberately (#265): supabase-js on this phone
  /// is the only holder that owns rotation, and a second holder presenting a
  /// rotated token makes Supabase revoke the whole session family. The plugin
  /// never refreshed on purpose, but `auth.setSession` refreshes on its own
  /// whenever the token it is handed has already expired — so the credential
  /// is removed rather than the call forbidden.
  setSession(options: { accessToken: string }): Promise<void>;

  /// Tells the plugin to forget its stored access token — called on phone
  /// sign-out so a later background HealthKit wake can't keep writing as that
  /// user. Mirrors the watch auth bridge's `clearSession`.
  clearSession(): Promise<void>;

  /// Read HealthKit now, upsert today's biometrics, and — unless
  /// ReadinessWritePolicy withholds it (an `"automatic"` sync after an
  /// already-scored today's noon) — (re)compute and upsert readiness. Called
  /// on app foreground and cold launch. Resolves after the upsert.
  syncNow(options?: { trigger?: HealthSyncTrigger }): Promise<void>;

  /// Latest native result, if a background watch request already completed.
  /// Empty/null on web or before the first native result.
  getLatestReadiness(): Promise<ReadinessRefreshResult | null>;

  /// Delete the user's health_metrics rows, then immediately re-ingest from
  /// HealthKit (native path for the Account "Clear & resync" action).
  clearAndResync(): Promise<void>;

  /// Register the HKObserverQuery + background delivery so new wearable data
  /// syncs automatically. Idempotent; call once after sign-in at launch.
  startBackgroundSync(): Promise<void>;

  /// A watch-triggered native refresh completed. The phone UI should re-read
  /// its normal repository-backed readiness/dashboard query; this event does
  /// not carry raw HealthKit samples or credentials.
  addListener(
    eventName: "readinessRefresh",
    listener: (result: ReadinessRefreshResult) => void,
  ): Promise<PluginListenerHandle>;
}
