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
}
