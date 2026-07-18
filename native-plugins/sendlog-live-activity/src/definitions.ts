import type { PluginListenerHandle } from "@capacitor/core";

/// Action queued by a lock-screen intent (Boulder/Stop) for the JS reducer.
export interface PendingWorkoutAction {
  type: "beginBoulder" | "endBoulder" | "end";
  /// ISO timestamp of the tap — the reducer computes durations from it.
  at: string;
}

/// One protocol segment, compact form (matches lib/protocol.ts fields).
export interface ActivitySegment {
  p: "prepare" | "hold" | "switch" | "rest" | "setRest";
  s?: "left" | "right";
  rep: number;
  set: number;
  startS: number;
  durS: number;
}

export interface SendLogLiveActivityPlugin {
  /// true on iOS 17+ (interactive Live Activities); false elsewhere.
  isSupported(): Promise<{ supported: boolean }>;
  /// Ask for local-notification permission (rest-over alert while locked).
  requestNotificationPermission(): Promise<{ granted: boolean }>;

  startWorkoutActivity(options: {
    startedAtMs: number;
    phase: "climbing" | "resting";
    phaseStartedAtMs: number;
    restTargetS?: number;
    boulderCount: number;
  }): Promise<void>;
  updateWorkoutActivity(options: {
    phase: "climbing" | "resting";
    phaseStartedAtMs: number;
    restTargetS?: number;
    boulderCount: number;
  }): Promise<void>;
  endWorkoutActivity(options?: { immediate?: boolean }): Promise<void>;

  startTindeqActivity(options: {
    title: string;
    targetKg?: number;
    startEpochMs: number;
    segments: ActivitySegment[];
  }): Promise<void>;
  updateTindeqStats(options: { peakKg: number }): Promise<void>;
  endTindeqActivity(): Promise<void>;

  /// Read + clear the intent action queue (replayed into the reducer).
  getPendingActions(): Promise<{ actions: PendingWorkoutAction[] }>;

  /// Fires right after a lock-screen intent ran (WebView alive only) —
  /// drain the queue on this for instant in-app catch-up.
  addListener(
    eventName: "liveActivityAction",
    listener: () => void,
  ): Promise<PluginListenerHandle>;
}
