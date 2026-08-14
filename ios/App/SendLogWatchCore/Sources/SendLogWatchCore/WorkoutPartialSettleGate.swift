import Foundation

/// #615: the ordering guard between the watch's mid-workout PARTIAL
/// `climb_workouts` flush and the FINAL bundle upload.
///
/// #477 proved the partial must never land AFTER the final row: the partial
/// upsert merge-writes over the same `climb_workouts` id, so a late partial
/// clobbers the final stats with provisional data. The old design made
/// `WorkoutManager.end()` AWAIT the in-flight partial before doing anything
/// else — correct, but it parked the End tap (and with it the durable queue
/// commit and the phone notification) behind a network call that can take up
/// to 60s.
///
/// This gate moves that wait OFF the End path and onto the upload path it
/// actually protects: `stopRecording()` registers the in-flight partial task
/// on the gate (synchronously, before any await), the save bundle is then
/// durably queued and the phone notified immediately, and the queue's upload
/// of ANY workout bundle first `waitForCurrent()`s — the final upload cannot
/// start until the partial has settled, preserving #477's invariant without
/// blocking End on the network.
///
/// Holding is per-workout: `hold` REPLACES the gate, so a new run's stop
/// supersedes an old run's settling partial (its bundle upload may wait on
/// the newer partial — harmless: the newer partial is the only one that
/// could still be in flight, since a new run cannot start until the
/// previous run's teardown allowed it, and `partialFlushSuspended` stops
/// new flushes at End).
public final class WorkoutPartialSettleGate: @unchecked Sendable {
    public static let shared = WorkoutPartialSettleGate()

    private let lock = NSLock()
    private var current: Task<Void, Never>?

    public init() {}

    /// Registers the in-flight partial-flush task (if any) as the current
    /// settle gate. `nil` (no flush in flight) settles immediately. Call
    /// from `stopRecording()` BEFORE the first await, so no drain can start
    /// its final upload ahead of the gate being set.
    public func hold(_ partialFlushTask: Task<Void, Never>?) {
        let settled: Task<Void, Never>
        if let partialFlushTask {
            settled = Task { await partialFlushTask.value }
        } else {
            settled = Task {}
        }
        lock.lock()
        current = settled
        lock.unlock()
    }

    /// Awaits the CURRENT gate — returns immediately when nothing is (or
    /// nothing ever was) in flight. The task was captured when the gate was
    /// held, so a newer `hold` never disturbs a waiter on the older one.
    public func waitForCurrent() async {
        let task: Task<Void, Never>?
        lock.lock()
        task = current
        lock.unlock()
        guard let task else { return }
        await task.value
    }
}
