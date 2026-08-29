import Foundation

/// The minimum time the native splash remains visible for a process launch.
/// A nil start marks a warm presentation, which has no floor.
public struct SplashPresentationFloor: Equatable, Sendable {
    public static let duration: TimeInterval = 1.0

    private let coldStartAt: Date?

    public init(coldStartAt: Date?) {
        self.coldStartAt = coldStartAt
    }

    public func remaining(at now: Date) -> TimeInterval {
        guard let coldStartAt else { return 0 }
        return max(0, Self.duration - now.timeIntervalSince(coldStartAt))
    }

    public func isSatisfied(at now: Date) -> Bool {
        remaining(at: now) <= 0
    }
}
