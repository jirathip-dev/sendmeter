import Foundation

// MARK: - Issue #520 — watch-triggered, iPhone-executed readiness refresh

/// Why the watch asked the iPhone to refresh. All three paths are automatic
/// HealthKit syncs: in particular, a watch-open/foreground request must keep
/// the iPhone's afternoon readiness freeze rather than becoming a manual
/// overwrite. The string values are the wire contract, so adding a new reason
/// does not require an older phone to understand it.
public enum ReadinessRefreshReason: String, Codable, Equatable, Sendable {
    case launch
    case foreground
    case statusRefresh = "status-refresh"
}

/// How the iPhone handled one request. A result is deliberately explicit about
/// auth/cancellation/failure so the watch can keep cached values visible while
/// still telling the wearer what action is possible.
public enum ReadinessRefreshStatus: String, Codable, Equatable, Sendable {
    case success
    case failed
    case authRequired = "auth-required"
    case cancelled
    case unsupported
}

/// Freshness of the score represented by a successful sync. `.cached` means
/// HealthKit/biometrics were read successfully but the automatic noon policy
/// intentionally kept the already-computed score; it is not an error.
public enum ReadinessFreshness: String, Codable, Equatable, Sendable {
    case fresh
    case cached
    case offline
    case unknown
}

/// Transport choice is kept pure so activation/reachability races can be
/// tested without WatchConnectivity. The watch still owns the actual send;
/// this policy only chooses whether to wait, answer immediately, or enqueue
/// the one coalesced guaranteed-delivery fallback.
public enum ReadinessTransportPath: Equatable, Sendable {
    case waitForActivation
    case sendImmediate
    case queueFallback

    public static func choose(activated: Bool, reachable: Bool) -> Self {
        guard activated else { return .waitForActivation }
        return reachable ? .sendImmediate : .queueFallback
    }
}

/// A native Supabase request may fail because the access token has expired.
/// The phone may ask the WebView owner for one fresh access-token relay, but a
/// single readiness pass must never retry indefinitely or carry a refresh
/// token into native code.
public enum ReadinessRefreshRetryPolicy {
    public static func shouldRelayAuth(
        errorDescription: String,
        alreadyRetried: Bool
    ) -> Bool {
        guard !alreadyRetried else { return false }
        let text = errorDescription.uppercased()
        return text.contains("PGRST301")
            || text.contains("PGRST302")
            || text.contains("401")
            || text.contains("JWT")
    }
}

/// The compact, privacy-preserving readiness payload sent back to the watch.
/// Health values are required here because this is the product result, but no
/// raw HealthKit samples or credentials ever cross the bridge.
public struct ReadinessSnapshot: Codable, Equatable, Sendable {
    public let date: String
    public let readiness: Int?
    public let zone: String?
    /// Unix seconds. Nil when a frozen score came from a row whose timestamp
    /// was intentionally not decoded by the native plugin.
    public let computedAt: TimeInterval?

    public init(
        date: String,
        readiness: Int?,
        zone: String?,
        computedAt: TimeInterval? = nil
    ) {
        self.date = date
        self.readiness = readiness
        self.zone = zone
        self.computedAt = computedAt
    }
}

/// A typed request carried in a WatchConnectivity dictionary. Decoding is
/// intentionally version-tolerant: unknown future fields are ignored, an
/// absent schema version is treated as v1, and an unknown future reason falls
/// back to `statusRefresh` (still automatic) rather than dropping the request.
public struct ReadinessRefreshRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let kind = "readinessRefresh"

    public let schemaVersion: Int
    public let requestId: String
    public let reason: ReadinessRefreshReason
    /// Unix seconds at the watch send point.
    public let sentAt: TimeInterval

    public init(
        requestId: String = UUID().uuidString,
        reason: ReadinessRefreshReason,
        sentAt: TimeInterval = Date().timeIntervalSince1970,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.requestId = requestId
        self.reason = reason
        self.sentAt = sentAt
    }

    /// Decode only the fields this version owns. WatchConnectivity commonly
    /// widens integer values to NSNumber/Double, so numeric parsing accepts
    /// both forms. Empty IDs are rejected because idempotency depends on them.
    public init?(message: [String: Any]) {
        guard message["kind"] as? String == Self.kind,
              let requestId = message["requestId"] as? String,
              !requestId.isEmpty
        else { return nil }

        let version = Self.intValue(message["schemaVersion"]) ?? 1
        guard version >= 1 else { return nil }
        let rawReason = message["reason"] as? String
        let reason = rawReason.flatMap(ReadinessRefreshReason.init(rawValue:))
            ?? .statusRefresh
        let sentAt = Self.doubleValue(message["sentAt"]) ?? Date().timeIntervalSince1970

        self.init(
            requestId: requestId,
            reason: reason,
            sentAt: sentAt,
            schemaVersion: version
        )
    }

    public func message() -> [String: Any] {
        [
            "kind": Self.kind,
            "schemaVersion": schemaVersion,
            "requestId": requestId,
            "reason": reason.rawValue,
            "sentAt": sentAt,
        ]
    }

    fileprivate static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double { return Int(value) }
        return nil
    }

    fileprivate static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

/// The typed result returned through `replyHandler`, and also sent as the
/// latest-state application context for queued/cold-watch recovery.
public struct ReadinessRefreshResult: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let kind = "readinessResult"

    public let schemaVersion: Int
    public let requestId: String
    public let reason: ReadinessRefreshReason
    public let sentAt: TimeInterval
    public let startedAt: TimeInterval
    public let completedAt: TimeInterval
    public let status: ReadinessRefreshStatus
    public let freshness: ReadinessFreshness
    public let snapshot: ReadinessSnapshot?
    /// Stable, actionable category (for example `auth-required`), never a
    /// token, raw HealthKit value, or server response body.
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        request: ReadinessRefreshRequest,
        startedAt: TimeInterval,
        completedAt: TimeInterval = Date().timeIntervalSince1970,
        status: ReadinessRefreshStatus,
        freshness: ReadinessFreshness,
        snapshot: ReadinessSnapshot? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.requestId = request.requestId
        self.reason = request.reason
        self.sentAt = request.sentAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.freshness = freshness
        self.snapshot = snapshot
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    public var succeeded: Bool { status == .success }

    public func message() -> [String: Any] {
        var out: [String: Any] = [
            "kind": Self.kind,
            "schemaVersion": schemaVersion,
            "requestId": requestId,
            "reason": reason.rawValue,
            "sentAt": sentAt,
            "startedAt": startedAt,
            "completedAt": completedAt,
            "status": status.rawValue,
            "freshness": freshness.rawValue,
        ]
        if let snapshot {
            var snapshotMessage: [String: Any] = ["date": snapshot.date]
            if let readiness = snapshot.readiness {
                snapshotMessage["readiness"] = readiness
            }
            if let zone = snapshot.zone {
                snapshotMessage["zone"] = zone
            }
            if let computedAt = snapshot.computedAt {
                snapshotMessage["computedAt"] = computedAt
            }
            out["snapshot"] = snapshotMessage
        }
        if let errorCode { out["errorCode"] = errorCode }
        if let errorMessage { out["errorMessage"] = errorMessage }
        return out
    }

    public init?(message: [String: Any]) {
        guard message["kind"] as? String == Self.kind,
              let requestId = message["requestId"] as? String,
              !requestId.isEmpty,
              let rawStatus = message["status"] as? String,
              let status = ReadinessRefreshStatus(rawValue: rawStatus)
        else { return nil }

        let version = ReadinessRefreshRequest.intValue(message["schemaVersion"]) ?? 1
        guard version >= 1 else { return nil }
        let reason = (message["reason"] as? String)
            .flatMap(ReadinessRefreshReason.init(rawValue:)) ?? .statusRefresh
        let sentAt = ReadinessRefreshRequest.doubleValue(message["sentAt"]) ?? 0
        let startedAt = ReadinessRefreshRequest.doubleValue(message["startedAt"])
            ?? sentAt
        let completedAt = ReadinessRefreshRequest.doubleValue(message["completedAt"])
            ?? startedAt
        let freshness = (message["freshness"] as? String)
            .flatMap(ReadinessFreshness.init(rawValue:)) ?? .unknown

        var snapshot: ReadinessSnapshot?
        if let raw = message["snapshot"] as? [String: Any],
           let date = raw["date"] as? String {
            let score = ReadinessRefreshRequest.intValue(raw["readiness"])
            let zone = (raw["zone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let computedAt = ReadinessRefreshRequest.doubleValue(raw["computedAt"])
            snapshot = ReadinessSnapshot(
                date: date,
                readiness: score,
                zone: zone,
                computedAt: computedAt
            )
        } else {
            snapshot = nil
        }

        self.schemaVersion = max(1, version)
        self.requestId = requestId
        self.reason = reason
        self.sentAt = sentAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.freshness = freshness
        self.snapshot = snapshot
        self.errorCode = message["errorCode"] as? String
        self.errorMessage = message["errorMessage"] as? String
    }
}

/// A pure gate for applying results on the watch. A reply for an older
/// request must not replace a newer in-flight request. When no request is
/// active, a queued result is accepted only if it is newer than the last
/// applied completion; this strict comparison makes duplicate replies
/// harmless.
public enum ReadinessResultGate {
    public static func shouldApply(
        _ result: ReadinessRefreshResult,
        activeRequestId: String?,
        lastAppliedCompletedAt: TimeInterval?
    ) -> Bool {
        if let activeRequestId, activeRequestId != result.requestId { return false }
        if let lastAppliedCompletedAt, result.completedAt <= lastAppliedCompletedAt {
            return false
        }
        return true
    }
}

/// Pure single-flight trigger state used by native refresh coordinators. The
/// owner sets `running` before its first await; any trigger during the pass is
/// represented by at most one follow-up. Manual wins over automatic if a
/// future explicit user refresh overlaps an automatic pass.
public struct ReadinessRefreshCoalescer: Equatable, Sendable {
    public enum Request: Equatable, Sendable {
        case start
        case queued
    }

    public enum Completion: Equatable, Sendable {
        case idle
        case rerun(ReadinessRefreshReason)
    }

    private var running = false
    private var queuedReason: ReadinessRefreshReason?
    private var followUpConsumed = false

    /// Lets an owner apply a result received while the watch was cold without
    /// attempting to complete a flight that never started in this process.
    public var isRunning: Bool { running }

    public init() {}

    public mutating func request(reason: ReadinessRefreshReason) -> Request {
        guard running else {
            running = true
            followUpConsumed = false
            return .start
        }
        // Preserve the strongest reason seen during the active pass. This is
        // important when a launch/foreground storm is followed by an explicit
        // status refresh: only one follow-up is needed, but it must retain the
        // more useful reason for diagnostics and policy decisions.
        if let queuedReason {
            self.queuedReason = Self.stronger(queuedReason, reason)
        } else {
            queuedReason = reason
        }
        return .queued
    }

    public mutating func complete() -> Completion {
        precondition(running, "cannot complete an idle readiness refresh")
        guard let queuedReason, !followUpConsumed else {
            running = false
            self.queuedReason = nil
            return .idle
        }
        self.queuedReason = nil
        // Keep the single-flight owner running while it executes the already
        // authorized follow-up. Calling request(reason:) here would only
        // queue another reason, so owners must continue directly instead.
        followUpConsumed = true
        return .rerun(queuedReason)
    }

    /// Abort a timed-out/cancelled transport. A late result is still allowed
    /// through the result gate when it is newer than the last applied result,
    /// but it cannot resurrect a coalesced follow-up from the cancelled pass.
    public mutating func cancel() {
        running = false
        queuedReason = nil
        followUpConsumed = false
    }

    private static func stronger(
        _ lhs: ReadinessRefreshReason,
        _ rhs: ReadinessRefreshReason
    ) -> ReadinessRefreshReason {
        func priority(_ reason: ReadinessRefreshReason) -> Int {
            switch reason {
            case .launch: return 0
            case .foreground: return 1
            case .statusRefresh: return 2
            }
        }
        return priority(rhs) > priority(lhs) ? rhs : lhs
    }
}
