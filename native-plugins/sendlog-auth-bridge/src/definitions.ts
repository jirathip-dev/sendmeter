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

export interface SendLogAuthBridgePlugin {
  /// Relays the current Supabase session to the paired Watch app via
  /// WatchConnectivity. No-op (resolves immediately) on platforms without
  /// a paired watch (iPad, or no watch paired) — see Plugin.swift.
  setSession(options: {
    accessToken: string;
    refreshToken: string;
    expiresAt: number;
  }): Promise<void>;

  /// Tells the paired Watch app to sign out.
  clearSession(): Promise<void>;

  /// Live-workout beats from the watch (native only; never fires on web).
  addListener(
    eventName: "liveWorkout",
    listener: (msg: LiveWorkoutMessage) => void,
  ): Promise<PluginListenerHandle>;
}
