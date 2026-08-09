import Foundation

/// Maintains the two logical pieces carried by the phone's latest
/// WatchConnectivity application context: the signed-in relay (which owns the
/// access token) and the latest readiness result. A readiness result must be
/// merged into that relay, never installed as a replacement context, or the
/// watch would receive a score while losing its session. This small state
/// machine is shared with the phone bridge so the merge and sign-out rules are
/// pure and regression-tested without requiring WatchConnectivity.
public struct ReadinessApplicationContext {
    private(set) public var authPayload: [String: Any]?
    private(set) public var readinessPayload: [String: Any]?
    private(set) public var isSignedOut: Bool

    public init(
        authPayload: [String: Any]? = nil,
        readinessPayload: [String: Any]? = nil,
        isSignedOut: Bool = false
    ) {
        self.authPayload = authPayload
        self.readinessPayload = readinessPayload
        self.isSignedOut = isSignedOut
    }

    /// Seeds a fresh bridge process from the persisted WatchConnectivity
    /// application context. That context may contain a combined signed-in
    /// relay and readiness result from the previous process, so the logical
    /// pieces are split before any new readiness result can be published.
    /// Transport-only relay stamps are deliberately discarded; the next
    /// actual relay adds fresh stamps of its own.
    @discardableResult
    public mutating func reconcile(_ context: [String: Any]) -> [String: Any] {
        let sanitized = Self.withoutTransportStamps(context)
        if sanitized["event"] as? String == "signedOut" {
            clearSignedOut()
            return signedOutPayload
        }

        if sanitized["event"] as? String == "signedIn" {
            isSignedOut = false
            authPayload = Self.authOnly(sanitized)
            let candidate = Self.readinessOnly(sanitized)
            readinessPayload = Self.resultBelongsToAuth(candidate, authPayload: authPayload)
                ? candidate
                : nil
            return mergedPayload
        }

        guard !isSignedOut else { return signedOutPayload }
        if sanitized["kind"] as? String == ReadinessRefreshResult.kind {
            let candidate = Self.readinessOnly(sanitized)
            guard Self.resultBelongsToAuth(candidate, authPayload: authPayload) else {
                return mergedPayload
            }
            readinessPayload = candidate
        }
        return mergedPayload
    }

    /// Applies one logical update and returns the complete application
    /// context that should be stamped and sent. `signedIn` replaces only the
    /// auth portion (preserving readiness for the same user), a readiness
    /// result replaces only the readiness portion, and `signedOut` clears both
    /// portions so no old bearer or score can survive an account transition.
    @discardableResult
    public mutating func update(_ context: [String: Any]) -> [String: Any] {
        let sanitized = Self.withoutTransportStamps(context)
        if sanitized["event"] as? String == "signedOut" {
            clearSignedOut()
            return signedOutPayload
        }

        if sanitized["event"] as? String == "signedIn" {
            let oldUserId = authPayload?["userId"] as? String
            let newUserId = sanitized["userId"] as? String
            if oldUserId != newUserId {
                readinessPayload = nil
            }
            isSignedOut = false
            authPayload = Self.authOnly(sanitized)
            if let candidate = Self.readinessOnly(sanitized) {
                readinessPayload = Self.resultBelongsToAuth(
                    candidate,
                    authPayload: authPayload
                ) ? candidate : nil
            } else if let current = readinessPayload,
                      !Self.resultBelongsToAuth(current, authPayload: authPayload) {
                // A same-user auth relay without a result must not preserve a
                // legacy/unscoped payload left by an older phone build.
                readinessPayload = nil
            }
        } else if sanitized["kind"] as? String == ReadinessRefreshResult.kind {
            guard !isSignedOut else { return signedOutPayload }
            let candidate = Self.readinessOnly(sanitized)
            guard Self.resultBelongsToAuth(candidate, authPayload: authPayload) else {
                return mergedPayload
            }
            readinessPayload = candidate
        }

        return mergedPayload
    }

    private var mergedPayload: [String: Any] {
        guard !isSignedOut else { return signedOutPayload }
        var merged = authPayload ?? [:]
        if let readinessPayload {
            for (key, value) in readinessPayload {
                merged[key] = value
            }
        }
        return merged
    }

    private var signedOutPayload: [String: Any] {
        ["event": "signedOut"]
    }

    private mutating func clearSignedOut() {
        authPayload = nil
        readinessPayload = nil
        isSignedOut = true
    }

    private static let transportStampKeys: Set<String> = ["relayId", "relayedAt"]
    private static let authKeys: Set<String> = [
        "event", "accessToken", "refreshToken", "userId", "expiresAt",
    ]

    private static func withoutTransportStamps(_ context: [String: Any]) -> [String: Any] {
        context.filter { !transportStampKeys.contains($0.key) }
    }

    private static func authOnly(_ context: [String: Any]) -> [String: Any] {
        context.filter {
            !ReadinessRefreshResultKeys.all.contains($0.key)
                && !transportStampKeys.contains($0.key)
        }
    }

    private static func readinessOnly(_ context: [String: Any]) -> [String: Any]? {
        guard context["kind"] as? String == ReadinessRefreshResult.kind else {
            return nil
        }
        return context.filter {
            !authKeys.contains($0.key) && !transportStampKeys.contains($0.key)
        }
    }

    /// A phone result stamped for another account must not enter the durable
    /// merged context, even if a stale completion somehow reaches the bridge
    /// after a direct A → B signedIn relay. An unstamped legacy result is not
    /// durable either: this state machine has no active-request identity, so
    /// only the watch's direct-reply gate may adopt one for an explicit
    /// current-account request.
    private static func resultBelongsToAuth(
        _ result: [String: Any]?,
        authPayload: [String: Any]?
    ) -> Bool {
        guard let result,
              let accountUserId = result["accountUserId"] as? String else { return false }
        guard let resultUserId = UUID(uuidString: accountUserId),
              let authUserId = authPayload?["userId"] as? String,
              let authUserId = UUID(uuidString: authUserId) else {
            return false
        }
        return resultUserId == authUserId
    }

    private enum ReadinessRefreshResultKeys {
        static let all: Set<String> = [
            "kind", "schemaVersion", "requestId", "reason", "sentAt",
            "startedAt", "completedAt", "status", "freshness", "snapshot",
            "accountUserId", "errorCode", "errorMessage",
        ]
    }
}
