import Foundation
import Observation
import SendLogWatchCore
import enum SendLogWatchCore.ReadinessTransportPath
import WatchConnectivity

/// Readiness zone for display (mirrors the values the iPhone writes to
/// health_metrics.zone). Kept watch-local so the watch never needs to import
/// HealthKit or run the readiness computation.
enum ReadinessZone: String {
    case recover, maintain, push
}

struct ReadinessDisplay {
    let score: Int?
    let zone: ReadinessZone?
    let driver: String
}

enum ReadinessSyncState: Equatable {
    case idle
    case syncing
    case fresh
    case cached
    case offline
    case authRequired
    case failed
    case unsupported
}

/// The watch-triggered readiness coordinator. Requests are sent over
/// WatchConnectivity, but HealthKit reads, readiness computation, and
/// health_metrics writes stay exclusively in the iPhone HealthSyncManager.
/// Cached widget data is shown immediately; a fresh compact result updates the
/// app-group snapshot and complications without a second watch-side fetch.
@Observable
@MainActor
final class ReadinessManager {
    nonisolated(unsafe) static weak var current: ReadinessManager?

    private(set) var snapshot: WidgetSnapshot
    private(set) var result: ReadinessDisplay?
    private(set) var syncState: ReadinessSyncState = .idle
    private(set) var errorMsg: String?
    private(set) var lastResultAt: Date?

    private var coalescer = ReadinessRefreshCoalescer()
    private var activeRequest: ReadinessRefreshRequest?
    private var activeRequestId: String?
    private var queuedFallbackRequestId: String?
    private var lastAppliedCompletedAt: TimeInterval?
    private var timeoutTask: Task<Void, Never>?
    private var lastSentAt: TimeInterval?
    private var ignoredRequestIds = Set<String>()

    init() {
        let cached = ScreenshotFixtures.enabled
            ? ScreenshotFixtures.status
            : WidgetStore.load()
        snapshot = cached
        if cached.readiness != nil || cached.readinessZone != nil {
            result = ReadinessDisplay(
                score: cached.readiness,
                zone: cached.readinessZone.flatMap(ReadinessZone.init(rawValue:)),
                driver: cached.readiness == nil ? "Cached" : "Cached (\(cached.updatedAtDateString))"
            )
        }
        Self.current = self
    }

    /// Called by app launch/foreground/status appear. The coalescer marks the
    /// flight before `sendMessage` or any asynchronous result work begins.
    func request(reason: ReadinessRefreshReason) {
        guard !ScreenshotFixtures.enabled else { return }
        switch coalescer.request(reason: reason) {
        case .start:
            let request = ReadinessRefreshRequest(reason: reason)
            activeRequest = request
            activeRequestId = request.requestId
            syncState = .syncing
            errorMsg = nil
            send(request)
        case .queued:
            // One follow-up is enough for a launch + foreground + status
            // storm; the pure coalescer retains the strongest reason.
            break
        }
    }

    /// Activation/reachability is the transport wake-up point. A request that
    /// was created before WCSession activation, or queued while unreachable,
    /// gets its immediate path as soon as the phone can answer.
    func connectivityChanged() {
        guard let activeRequestId else { return }
        guard let request = currentRequest(id: activeRequestId) else { return }
        send(request, force: true)
    }

    /// Applies a direct reachable reply or a latest application-context result
    /// from the phone. A late result from an older request can never replace a
    /// newer active request, and a sign-out quarantine rejects its old ID.
    func receive(_ message: [String: Any]) {
        guard let result = ReadinessRefreshResult(message: message) else { return }
        receive(result)
    }

    func receive(_ result: ReadinessRefreshResult) {
        guard !ignoredRequestIds.contains(result.requestId),
              ReadinessResultGate.shouldApply(
                  result,
                  activeRequestId: activeRequestId,
                  lastAppliedCompletedAt: lastAppliedCompletedAt
              )
        else { return }

        lastAppliedCompletedAt = max(lastAppliedCompletedAt ?? 0, result.completedAt)
        lastResultAt = Date(timeIntervalSince1970: result.completedAt)
        timeoutTask?.cancel()
        timeoutTask = nil
        queuedFallbackRequestId = nil

        if let incoming = result.snapshot {
            snapshot.readiness = incoming.readiness
            snapshot.readinessZone = incoming.zone
            snapshot.updatedAt = Date().timeIntervalSince1970
            self.result = ReadinessDisplay(
                score: incoming.readiness,
                zone: incoming.zone.flatMap(ReadinessZone.init(rawValue:)),
                driver: result.freshness == .fresh
                    ? "Fresh (\(incoming.date))"
                    : "Cached (\(incoming.date))"
            )
            WidgetStore.save(snapshot)
            Task {
                await WidgetBridge.refreshStatus(readiness: incoming)
                // ACWR is filled by the same single status write after the
                // native readiness result; no second readiness fetch occurs.
                snapshot = WidgetStore.load()
            }
        }

        switch result.status {
        case .success:
            syncState = result.freshness == .fresh ? .fresh : .cached
            errorMsg = nil
        case .authRequired:
            syncState = .authRequired
            errorMsg = result.errorMessage
        case .failed:
            syncState = .failed
            errorMsg = result.errorMessage
        case .cancelled, .unsupported:
            syncState = result.status == .unsupported ? .unsupported : .offline
            errorMsg = result.errorMessage
        }

        activeRequestId = nil
        activeRequest = nil
        if coalescer.isRunning {
            switch coalescer.complete() {
            case .idle:
                break
            case let .rerun(reason):
                // `complete` leaves the coalescer idle so this starts exactly one
                // fresh follow-up, even if many triggers arrived during the pass.
                Task { @MainActor in self.request(reason: reason) }
            }
        }
    }

    /// Sign-out invalidates an in-flight request and quarantines its late
    /// result. The watch keeps no bearer refresh credential and does not ask
    /// the old request to write anything after the account is gone.
    func signOutLocally() {
        if let activeRequestId { ignoredRequestIds.insert(activeRequestId) }
        if let queuedFallbackRequestId { ignoredRequestIds.insert(queuedFallbackRequestId) }
        timeoutTask?.cancel()
        timeoutTask = nil
        activeRequestId = nil
        activeRequest = nil
        queuedFallbackRequestId = nil
        coalescer.cancel()
        syncState = .authRequired
        errorMsg = nil
    }

    var syncLabel: String {
        switch syncState {
        case .idle:
            return snapshot.readiness == nil ? "Waiting for iPhone" : "Cached"
        case .syncing:
            return "Syncing from iPhone…"
        case .fresh:
            return "Fresh from iPhone"
        case .cached:
            return "Cached · afternoon freeze"
        case .offline:
            return snapshot.readiness == nil ? "Offline · no score yet" : "Offline · showing cached"
        case .authRequired:
            return "Open Sendmeter on iPhone to refresh"
        case .failed:
            return snapshot.readiness == nil ? "Refresh failed" : "Refresh failed · showing cached"
        case .unsupported:
            return "iPhone readiness unavailable"
        }
    }

    private func send(_ request: ReadinessRefreshRequest, force: Bool = false) {
        guard let session = supportedSession else {
            scheduleTimeout(for: request)
            return
        }
        let now = Date().timeIntervalSince1970
        if !force, let lastSentAt, now - lastSentAt < 0.25 { return }
        lastSentAt = now
        let stamped = WatchBuild.stamp(request.message())
        switch ReadinessTransportPath.choose(
            activated: session.activationState == .activated,
            reachable: session.isReachable
        ) {
        case .waitForActivation:
            scheduleTimeout(for: request)
        case .queueFallback:
            queueFallback(request)
            scheduleTimeout(for: request)
        case .sendImmediate:
            session.sendMessage(
                stamped,
                replyHandler: { [weak self] reply in
                    Task { @MainActor in self?.receive(reply) }
                },
                errorHandler: { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.queueFallback(request)
                        self.errorMsg = error.localizedDescription
                    }
                }
            )
            scheduleTimeout(for: request)
        }
    }

    private var supportedSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    private func queueFallback(_ request: ReadinessRefreshRequest) {
        guard let session = supportedSession,
              session.activationState == .activated
        else { return }
        guard queuedFallbackRequestId != request.requestId else { return }
        queuedFallbackRequestId = request.requestId
        // WatchBuild carries build + queue depth on every watch→phone message;
        // transferUserInfo is the one coalesced guaranteed-delivery fallback.
        session.transferUserInfo(WatchBuild.stamp(request.message()))
        syncState = .offline
    }

    private func scheduleTimeout(for request: ReadinessRefreshRequest) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.activeRequestId == request.requestId else { return }
                // Keep a guaranteed fallback flight alive until its result
                // arrives; follow-up foreground triggers coalesce behind it.
                if self.queuedFallbackRequestId == request.requestId {
                    self.activeRequestId = nil
                    self.activeRequest = nil
                    // The guaranteed transfer may still deliver a late
                    // result, but this transport flight is terminal. Leaving
                    // the coalescer running here wedges every later trigger
                    // as `.queued` behind a request that can never complete.
                    self.coalescer.cancel()
                    self.syncState = .offline
                } else {
                    self.activeRequestId = nil
                    self.activeRequest = nil
                    self.coalescer.cancel()
                    self.syncState = .offline
                }
            }
        }
    }

    private func currentRequest(id: String) -> ReadinessRefreshRequest? {
        // The request dictionary is intentionally compact and not persisted:
        // a cold process has the latest result in the App Group, while an
        // active request always remains represented by its ID and this value.
        // Reconstructing with the same ID is safe because the phone's request
        // cache makes retries idempotent.
        guard id == activeRequestId, let activeRequest else { return nil }
        return activeRequest
    }
}

private extension WidgetSnapshot {
    var updatedAtDateString: String {
        guard updatedAt > 0 else { return "" }
        return Date(timeIntervalSince1970: updatedAt).localDateString
    }
}
