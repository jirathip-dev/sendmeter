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

    public init(client: SupabaseClient = SupabaseEnvironment.client) {
        self.client = client
    }

    /// Subscribes to this user's channels. Idempotent per user; re-subscribing
    /// for a different user tears the old channels down first.
    public func subscribe(userID: UUID) async {
        guard subscribedUserID != userID else { return }
        await unsubscribe()

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
            try await dataChannel.subscribeWithError()
            channels = [workoutChannel, dataChannel]
            subscriptions = [workoutSubscription] + dataSubscriptions
            subscribedUserID = userID
        } catch {
            // Realtime is best-effort by design: WC + pull-to-refresh are the
            // durable paths, and a failed join must not surface to the user.
            await unsubscribe()
        }
    }

    public func unsubscribe() async {
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

    private nonisolated static func rowRecord(for action: AnyAction) -> [String: Any]? {
        switch action {
        case .insert(let insert): return insert.record.mapValues(\.value)
        case .update(let update): return update.record.mapValues(\.value)
        case .delete: return nil
        }
    }
}
