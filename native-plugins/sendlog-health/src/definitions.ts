/// Distinguishes an app-driven sync (foreground/cold-launch — the app has no
/// user-refresh gesture yet, so this is what every current call site sends)
/// from an explicit user-initiated one (reserved for a future pull-to-refresh
/// — always authoritative on the native side, bypassing the after-noon
/// readiness lock; see ReadinessWritePolicy in sendlog-health-core). Omitting
/// `trigger` on the native side fails safe as "automatic".
export type HealthSyncTrigger = "automatic" | "manual";

export interface SendLogHealthPlugin {
  /// Prompt for HealthKit read access (HRV, resting HR, sleep, body mass,
  /// respiratory rate). No-op resolve on non-iOS.
  requestAuthorization(): Promise<void>;

  /// Hands the plugin's own Supabase client the current session so it can
  /// read sessions / write health_metrics from native code, including in the
  /// background (the WebView's supabase-js session isn't reachable natively).
  /// Relayed on every auth event, same as the watch auth bridge.
  setSession(options: {
    accessToken: string;
    refreshToken: string;
  }): Promise<void>;

  /// Tells the plugin to forget its stored session (issue #196) — called on
  /// phone sign-out so a later background HealthKit wake can't keep using a
  /// stale/rotated refresh token. Mirrors the watch auth bridge's
  /// `clearSession`.
  clearSession(): Promise<void>;

  /// Read HealthKit now, upsert today's biometrics, and — unless
  /// ReadinessWritePolicy withholds it (an `"automatic"` sync after an
  /// already-scored today's noon) — (re)compute and upsert readiness. Called
  /// on app foreground and cold launch. Resolves after the upsert.
  syncNow(options?: { trigger?: HealthSyncTrigger }): Promise<void>;

  /// Delete the user's health_metrics rows, then immediately re-ingest from
  /// HealthKit (native path for the Account "Clear & resync" action).
  clearAndResync(): Promise<void>;

  /// Register the HKObserverQuery + background delivery so new wearable data
  /// syncs automatically. Idempotent; call once after sign-in at launch.
  startBackgroundSync(): Promise<void>;
}
