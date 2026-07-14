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

  /// Read HealthKit now, compute readiness, and upsert today's row. Called on
  /// app foreground and right after a clear. Resolves after the upsert.
  syncNow(): Promise<void>;

  /// Delete the user's health_metrics rows, then immediately re-ingest from
  /// HealthKit (native path for the Account "Clear & resync" action).
  clearAndResync(): Promise<void>;

  /// Register the HKObserverQuery + background delivery so new wearable data
  /// syncs automatically. Idempotent; call once after sign-in at launch.
  startBackgroundSync(): Promise<void>;
}
