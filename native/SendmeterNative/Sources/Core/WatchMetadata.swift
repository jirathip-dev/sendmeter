import Foundation

/// The build + offline-queue telemetry the watch stamps onto every watch→phone
/// message (#228, #21, #475). The wire keys mirror `WatchBuildReport` in
/// `ios/App/SendLogWatchCore` — KEEP-IN-SYNC: the watch stamps these exact
/// strings, and the native client must read the same ones the shipped phone
/// plugin strips before forwarding.
public struct WatchMetadata: Equatable, Sendable {
    /// Queue reports are account-owned even though they travel beside the
    /// device build identity. KEEP-IN-SYNC with `WatchBuildReport`.
    public static let accountUserIdKey = "account_user_id"
    public static let versionKey = "watch_app_version"
    public static let buildKey = "watch_app_build"
    public static let pendingSyncKey = "watch_pending_sync"
    public static let unscopedSyncKey = "watch_unscoped_sync"
    public static let quarantinedSyncKey = "watch_quarantined_sync"
    public static let quarantinedStuckSyncKey = "watch_quarantined_stuck_sync"

    public let accountUserID: UUID?
    public let version: String?
    public let build: String?
    public let pendingSync: Int?
    public let unscopedSync: Int?
    public let quarantinedSync: Int?
    public let quarantinedStuckSync: Int?

    public init(
        accountUserID: UUID?,
        version: String?,
        build: String?,
        pendingSync: Int?,
        unscopedSync: Int? = nil,
        quarantinedSync: Int?,
        quarantinedStuckSync: Int?
    ) {
        self.accountUserID = accountUserID
        self.version = version
        self.build = build
        self.pendingSync = pendingSync
        self.unscopedSync = unscopedSync
        self.quarantinedSync = quarantinedSync
        self.quarantinedStuckSync = quarantinedStuckSync
    }

    /// Reads the report fields out of a raw watch→phone message. Missing keys
    /// parse as nil — "never reported" stays distinguishable from zero.
    public static func parse(_ message: [String: Any]) -> WatchMetadata {
        WatchMetadata(
            accountUserID: uuid(message[accountUserIdKey]),
            version: message[versionKey] as? String,
            build: message[buildKey] as? String,
            pendingSync: nonNegativeCount(pendingSyncKey, in: message),
            unscopedSync: nonNegativeCount(unscopedSyncKey, in: message),
            quarantinedSync: nonNegativeCount(quarantinedSyncKey, in: message),
            quarantinedStuckSync: nonNegativeCount(quarantinedStuckSyncKey, in: message)
        )
    }

    /// Reads a non-negative count, widening `Double` (WatchConnectivity
    /// round-trips numbers as whatever `NSNumber` fits them) and refusing a
    /// negative value the same way `WatchBuildReport.stamped` refuses to
    /// write one.
    private static func nonNegativeCount(_ key: String, in message: [String: Any]) -> Int? {
        let raw: Int?
        if let i = message[key] as? Int {
            raw = i
        } else if let n = message[key] as? Double {
            raw = Int(n)
        } else {
            raw = nil
        }
        guard let raw, raw >= 0 else { return nil }
        return raw
    }

    private static func uuid(_ value: Any?) -> UUID? {
        if let value = value as? UUID { return value }
        if let value = value as? String { return UUID(uuidString: value) }
        return nil
    }
}
