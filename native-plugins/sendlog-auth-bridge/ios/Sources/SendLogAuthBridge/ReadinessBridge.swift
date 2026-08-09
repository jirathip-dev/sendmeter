import Foundation
import SendLogWatchCore

/// Narrow, generic plumbing for phone-executed watch requests. The auth
/// bridge owns WatchConnectivity and the health plugin owns execution; this
/// seam keeps the bridge free of HealthKit/Supabase knowledge while allowing
/// a reachable `replyHandler` and the queued application-context fallback to
/// use exactly the same typed result.
public enum SendLogReadinessBridge {
    public typealias RequestHandler = (
        _ request: ReadinessRefreshRequest,
        _ replyHandler: (([String: Any]) -> Void)?
    ) -> Void
    public typealias SessionRequestHandler = () -> Void
    public typealias ResultPublisher = (
        _ result: [String: Any],
        _ immediate: Bool
    ) -> Void

    private static let lock = NSLock()
    private static var requestHandler: RequestHandler?
    private static var sessionRequestHandler: SessionRequestHandler?
    private static var resultPublisher: ResultPublisher?

    public static func registerRequestHandler(_ handler: @escaping RequestHandler) {
        lock.lock()
        requestHandler = handler
        lock.unlock()
    }

    public static func registerSessionRequestHandler(_ handler: @escaping SessionRequestHandler) {
        lock.lock()
        sessionRequestHandler = handler
        lock.unlock()
    }

    public static func registerResultPublisher(_ publisher: @escaping ResultPublisher) {
        lock.lock()
        resultPublisher = publisher
        lock.unlock()
    }

    /// Routes only the readiness kind. Returning false lets the auth bridge
    /// continue handling its existing live-workout/session message kinds.
    @discardableResult
    public static func route(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?
    ) -> Bool {
        guard let request = ReadinessRefreshRequest(message: message) else {
            return false
        }

        lock.lock()
        let handler = requestHandler
        let publisher = resultPublisher
        lock.unlock()

        guard let handler else {
            let now = Date().timeIntervalSince1970
            let result = ReadinessRefreshResult(
                request: request,
                startedAt: now,
                completedAt: now,
                status: .unsupported,
                freshness: .unknown,
                errorCode: "unsupported",
                errorMessage: "This iPhone cannot refresh readiness yet."
            )
            replyHandler?(result.message())
            publisher?(result.message(), replyHandler == nil)
            return true
        }

        handler(request, replyHandler)
        return true
    }

    /// A stale/missing bearer token must be repaired by the phone's existing
    /// WebView session owner. This callback intentionally carries no token and
    /// no refresh token across the native bridge.
    public static func requestFreshSession() {
        lock.lock()
        let handler = sessionRequestHandler
        lock.unlock()
        handler?()
    }

    /// Publishes a typed result to the auth bridge. `immediate` is true only
    /// for a reachable request with a reply handler; the bridge still stores
    /// every result as latest application context for a cold/unreachable
    /// watch.
    public static func publish(_ result: ReadinessRefreshResult, immediate: Bool) {
        lock.lock()
        let publisher = resultPublisher
        lock.unlock()
        publisher?(result.message(), immediate)
    }
}
