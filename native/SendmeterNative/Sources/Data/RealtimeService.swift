import Foundation
import SendmeterCore
import Supabase

/// Wraps supabase-swift's Realtime (RealtimeV2) for the native app: one
/// per-user `live_workouts` mirror channel (scope item 1) and one per-user
/// watched-tables channel that feeds list reconciliation (scope item 2).
///
/// Every subscription is keyed by the authenticated user id — never a bare
/// `*` channel — and lifecycle (subscribe after sign-in, unsubscribe on
/// sign-out, resubscribe on user change) is driven by AppModel's
/// `handleAuthEvent` seam. Realtime is best-effort: a dropped socket degrades
/// silently to WatchConnectivity + foreground refetch, and the supabase-swift
/// client auto-reconnects and rejoins channels when connectivity returns.
///
/// Concurrency: `subscribe` captures a generation AFTER its own entry
/// teardown (which deliberately does not bump it — see `subscribe`) and
/// re-validates it after every await and before committing channels, so a
/// join that outlived a newer subscribe request or an unsubscribe can never
/// commit — or tear down — a subscription it no longer owns (#626 review).
@MainActor
public final class RealtimeService: ObservableObject {
    @Published public private(set) var connectionStatus: RealtimeClientStatus?
    @Published public private(set) var subscribedUserID: UUID?

    /// Mirror producer (scope item 1): raw `live_workouts` row record.
    public var onLiveWorkoutRow: (([String: Any]) -> Void)?
    /// Reconcile producer (scope item 2): which watched table changed.
    public var onListEvent: ((RealtimeTable) -> Void)?

    private let client: SupabaseClient
    private var channels: [RealtimeChannelV2] = []
    private var subscriptions: [RealtimeSubscription] = []
    private var statusTask: Task<Void, Never>?
    /// Bumped by every subscribe request and every unsubscribe. An in-flight
    /// subscribe compares its captured generation against this before each
    /// commit point; a mismatch means the request is stale and must abandon
    /// its partial work without touching newer state.
    private var generation = 0

    public init(client: SupabaseClient = SupabaseEnvironment.client) {
        self.client = client
    }

    /// Subscribes to this user's channels. Idempotent per user; re-subscribing
    /// for a different user tears the old channels down first. The request is
    /// abandoned (after cleaning up only its own channels) if a newer
    /// subscribe or an unsubscribe happens while the joins are in flight.
    public func subscribe(userID: UUID) async {
        guard subscribedUserID != userID else { return }
        // Teardown FIRST, without bumping the generation: this request's own
        // teardown must not invalidate itself (#626 review — the previous
        // version bumped here AND inside unsubscribe(), so the guard below
        // always failed and realtime never ran). The generation is captured
        // AFTER the teardown, so only a NEWER subscribe or an unsubscribe
        // can invalidate the joins that follow.
        await removeAllChannels()
        generation += 1
        let requestGeneration = generation

        let realtime = client.realtimeV2
        startStatusObservation(realtime)

        let workoutChannel = client.channel("live-workout-\(userID.uuidString.lowercased())")
        let workoutSubscription = workoutChannel.onPostgresChange(
            AnyAction.self,
            schema: "public",
            table: "live_workouts",
            filter: .eq("user_id", value: userID)
        ) { [weak self] action in
            Task { @MainActor in
                guard let record = Self.rowRecord(for: action) else { return }
                self?.onLiveWorkoutRow?(record)
            }
        }

        let dataChannel = client.channel("user-data-\(userID.uuidString.lowercased())")
        var dataSubscriptions: [RealtimeSubscription] = []
        for table in RealtimeTable.allCases {
            let subscription = dataChannel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: table.rawValue,
                filter: .eq("user_id", value: userID)
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onListEvent?(table)
                }
            }
            dataSubscriptions.append(subscription)
        }

        do {
            try await workoutChannel.subscribeWithError()
            guard generation == requestGeneration else {
                await abandon(workoutChannel)
                return
            }
            try await dataChannel.subscribeWithError()
            guard generation == requestGeneration else {
                await abandon(workoutChannel, dataChannel)
                return
            }
            channels = [workoutChannel, dataChannel]
            subscriptions = [workoutSubscription] + dataSubscriptions
            subscribedUserID = userID
        } catch {
            // Never leave a partially-joined channel behind: this request's
            // channels stay untracked until BOTH joins commit, so a full
            // unsubscribe() here would leak the joined workoutChannel (it
            // keeps firing callbacks and survives sign-out). Remove the
            // instances this request created, identity-checked so a newer
            // request's reused instances survive (#626 review).
            await abandon(workoutChannel, dataChannel)
            // #992 round 2: this join failure used to be silent. Realtime is
            // best-effort by design (the pull path covers the data), but a
            // device-only defect where realtime never joins must be nameable
            // in the persisted transcript — emitted through the production
            // logger directly (off the injectable sink; the emission audit
            // ring observes it).
            PersistedFailureLog.emit(
                PersistedFailureLog.line(
                    channel: .syncReplayFailure,
                    operation: "realtime-subscribe",
                    error: error,
                    surfaced: false
                )
            )
        }
    }

    public func unsubscribe() async {
        // Cancels any in-flight subscribe: its next checkpoint sees the
        // bumped generation and abandons its own channels.
        generation += 1
        await removeAllChannels()
    }

    /// Removes the tracked channels without touching the generation — used
    /// by subscribe's own entry teardown, which must not invalidate itself.
    private func removeAllChannels() async {
        for channel in channels {
            await client.removeChannel(channel)
        }
        channels = []
        subscriptions = []
        subscribedUserID = nil
    }

    private func startStatusObservation(_ realtime: RealtimeClientV2) {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            for await status in realtime.statusChange {
                await MainActor.run { self?.connectionStatus = status }
            }
        }
    }

    /// Removes channels this request created, but only the ones the realtime
    /// client still maps to THIS instance — a newer request may have reused
    /// the same topic instance, and tearing that down would kill the healthy
    /// subscription (#626 review).
    private func abandon(_ channelsToRemove: RealtimeChannelV2...) async {
        for channel in channelsToRemove {
            if client.channels.contains(where: { $0 === channel }) {
                await client.removeChannel(channel)
            }
        }
    }

    private nonisolated static func rowRecord(for action: AnyAction) -> [String: Any]? {
        switch action {
        case .insert(let insert): return insert.record.mapValues(\.value)
        case .update(let update): return update.record.mapValues(\.value)
        case .delete: return nil
        }
    }
}
