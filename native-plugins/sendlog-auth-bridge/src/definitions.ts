import type { PluginListenerHandle } from "@capacitor/core";

/// The protocol metadata shared by the WatchConnectivity and Supabase mirror
/// paths (#521). Fields are optional at the TypeScript boundary so a phone can
/// still read a pre-#521 watch during a staggered rollout; every current watch
/// emitter sends all four fields.
export type LiveMirrorEvent = "start" | "telemetry" | "phase" | "count" | "end";

export interface LiveMirrorMetadata {
  /// UUID for one workout/gauge transport run. Never infer ordering from a UUID.
  run_id?: string;
  /// Strictly increasing within `run_id`; gaps are valid when telemetry is
  /// coalesced. A duplicate or lower value is never applied.
  sequence?: number;
  /// Why this snapshot was emitted. `telemetry` may be coalesced; discrete
  /// transitions are delivered immediately.
  event?: LiveMirrorEvent;
  /// Explicit terminal marker. Receivers also infer it from ended/idle status
  /// for mixed-version payloads.
  terminal?: boolean;
  /// The immutable account that owns this run (#529's captured run owner),
  /// stamped once at watch run start and never re-derived from the watch's
  /// current relayed identity at heartbeat time (#530). Receivers must reject
  /// a packet whose owner does not match the phone's currently authenticated
  /// account BEFORE it reaches reducer state — the watch may still be
  /// relaying a run that started under a previous account for a while after
  /// the phone itself has switched, and run id/sequence ordering alone cannot
  /// tell that apart from a legitimate late beat. A Swift `UUID.uuidString`
  /// (UPPERCASE) — normalize before comparing, same as `run_id` (see
  /// `normalizeRunId`/`acceptsPacketOwner` in `liveWorkoutMirror.ts` /
  /// `liveForceMirror.ts`, and `normalizeUserId` in `healthSync.ts`, #535).
  /// Absent on a pre-#530 watch build; see `acceptsPacketOwner`'s doc comment
  /// for the conservative mixed-version rule that governs an unstamped
  /// packet.
  account_user_id?: string;
}

/// Watch→phone live-workout beat, relayed over WatchConnectivity (Bluetooth)
/// for a sub-second in-app mirror. Same snake_case shape as the
/// live_workouts row, with dates as epoch SECONDS.
export interface LiveWorkoutMessage extends LiveMirrorMetadata {
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
  /// Epoch SECONDS of the phone-side native plugin receipt (#614) — stamped
  /// on the forwarded payload so the WebView can measure the watch-capture →
  /// plugin → WebView latency boundaries separately. Absent on a plugin build
  /// that predates the stamp; treat absent as "latency unknown".
  received_at?: number;
}

/// Watch→phone live force-gauge beat (SL-87), ~2 Hz while measuring plus one
/// on every status transition. WC-only — no Supabase fallback (a gauge stream
/// has no business heartbeating the network).
export interface LiveForceMessage extends LiveMirrorMetadata {
  status: "connected" | "measuring" | "idle";
  kg?: number;
  peak_kg?: number;
  elapsed_ms?: number;
  session_count?: number;
  tag?: string;
  side?: string;
  updated_at: number;
  /// Epoch SECONDS of the phone-side native plugin receipt (#614) — same
  /// purpose and absence semantics as `LiveWorkoutMessage.received_at`.
  received_at?: number;
  /// SL-95: a downsampled trailing ~3s window of `[t_ms, kg]` pairs, `t_ms`
  /// relative to this hold's start (same clock as `elapsed_ms`) — only
  /// present (non-empty) while `status === "measuring"`. The phone re-anchors
  /// each point to wall-clock time using `updated_at`/`elapsed_ms` and
  /// accumulates its own rolling buffer (see `useLiveForce.ts`); this field
  /// is one beat's slice, not the full history.
  spark?: [number, number][];
}

/// Watch→phone completed-workout notification (#615): the watch's End path
/// sends this AFTER its save bundle is durably queued on the watch, so the
/// phone can render the completed workout as PENDING immediately instead of
/// waiting for the upload to land. Only safe canonical summary fields +
/// stable ids ride the wire — no raw trace, no health values. Supabase
/// remains authoritative: the phone never inserts a session from this
/// payload — it creates a pending row that realtime/server data reconciles
/// by `session_id`, exactly once.
export interface WorkoutCompletedMessage extends LiveMirrorMetadata {
  session_id: string;
  workout_id: string;
  /// Epoch SECONDS, same clock as the live-workout beat.
  started_at?: number;
  ended_at?: number;
  attempt_count?: number;
  duration_min?: number;
  rpe?: number;
  phase?: string;
  type?: string;
  type_label?: string;
  note?: string;
  rpe_confirmed?: boolean;
  /// Epoch SECONDS of the phone-side native plugin receipt (#614 convention).
  received_at?: number;
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

/// Verdict on the watch's QUARANTINED uploads (#475 F1), computed in Swift
/// (`WatchBuildReport.quarantineStatus`) for the same reason as the other
/// verdicts. Deliberately distinct from `WatchSyncStatus`: a quarantined
/// item is not "pending" or "backed up" — it needs a different fact told
/// about it. This coarse status only says whether ANYTHING is quarantined;
/// `quarantinedStuckSyncCount` below carries the breakdown (#475 F13) —
/// some quarantined items (`.schemaRejection`) truly never sync on their
/// own, others (`.stuckRetrying`) get one more automatic attempt after a
/// backoff, and this type alone can't tell you which.
export type WatchQuarantineStatus =
  | "not-paired"
  | "app-not-installed"
  /// Installed, but no quarantine count has ever arrived — nothing known.
  | "not-reported"
  /// WCSession hasn't activated yet.
  | "unknown"
  /// Reported zero quarantined items.
  | "none"
  /// At least one item is off the ordinary drain path.
  | "stuck";

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

  /// The watch's quarantined-upload state (#475 F1). Absent entirely on a
  /// native shell whose compiled-in plugin predates the field.
  quarantineStatus?: WatchQuarantineStatus;
  /// TOTAL items the watch last reported as quarantined (both
  /// `QuarantineReason` cases combined). Present only once it has actually
  /// reported one — absent is "unknown", not zero.
  quarantinedSyncCount?: number;
  /// Epoch SECONDS of that count's report. No "stale" flag — unlike a
  /// pending count, a quarantined item does not resolve itself under normal
  /// operation (see the Swift `WatchBuildReport.quarantineStatus` doc
  /// comment for the reinstall edge case this doesn't cover), so an old
  /// report can only be a floor on the current count, never an overstatement.
  quarantinedSyncReportedAt?: number;
  /// Subset of `quarantinedSyncCount` whose reason is `.stuckRetrying`
  /// (#475 F13) — items that WILL be automatically re-attempted after a
  /// backoff, as opposed to the `.schemaRejection` remainder
  /// (`quarantinedSyncCount` minus this), which is proven permanent.
  /// **Absent** on a native shell whose compiled-in plugin predates this
  /// field, or a watch build that only ever reports the combined total —
  /// callers must treat that as "breakdown unknown", not zero, and default
  /// to the more cautious "assume permanent" framing (see
  /// `uploadWarningPresentation` in `watchBuild.ts`).
  quarantinedStuckSyncCount?: number;
  /// Epoch SECONDS of that subset's report.
  quarantinedStuckSyncReportedAt?: number;
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

  /// A watch workout completed and is durably queued on the watch (#615).
  /// Native only; never fires on web. The payload carries the stable session
  /// id — register a PENDING session and let server data reconcile it.
  addListener(
    eventName: "workoutCompleted",
    listener: (msg: WorkoutCompletedMessage) => void,
  ): Promise<PluginListenerHandle>;

  /// Drains the plugin's bounded store of `workoutCompleted` notifications —
  /// notifications that arrived while the WebView was suspended are replayed
  /// here (oldest first, cleared on read) so a foregrounded app still renders
  /// them as pending instead of losing the event. Idempotent by session id.
  getPendingWorkoutCompletions(): Promise<{
    completions: WorkoutCompletedMessage[];
  }>;
}
