/// State machine for a queue drain that coalesces concurrent requests without
/// losing them. The owner sets the running state before its first `await`.
public struct CoalescingDrain: Equatable, Sendable {
    public enum Request: Equatable, Sendable { case start, queued }
    public enum PassCompletion: Equatable, Sendable { case rerun, idle }

    private var running = false
    private var requestedAgain = false

    public init() {}

    public mutating func request() -> Request {
        if running {
            requestedAgain = true
            return .queued
        }
        running = true
        return .start
    }

    public mutating func completePass() -> PassCompletion {
        precondition(running, "cannot complete a drain that is not running")
        if requestedAgain {
            requestedAgain = false
            return .rerun
        }
        running = false
        return .idle
    }
}
