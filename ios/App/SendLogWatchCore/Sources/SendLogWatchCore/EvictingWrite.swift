import Foundation

// MARK: - Issue #495 R3 — the eviction loop's decision logic, as pure code

/// What one eviction attempt achieved, as the loop needs to know it.
public enum EvictionAttemptOutcome: Sendable, Equatable {
    /// An older queued file was removed; the write is worth retrying.
    case evicted
    /// A file was selected but could not be removed. Information, not noise
    /// (#486 re-review R1): "this file cannot be freed" — looping back would
    /// just re-select the same file forever, so the loop must stop.
    case evictionRefused
    /// There is nothing left to evict; the refused write cannot be helped.
    case nothingLeftToEvict
}

public struct EvictingWriteResult: Sendable, Equatable {
    public let persisted: Bool
    /// How many queued files were destroyed along the way. Each one was a
    /// real, unsynced item — the caller must report a nonzero count
    /// (CLAUDE.md #264: a loss is said out loud, never swallowed), on every
    /// exit, success or failure: a file deleted along the way is gone
    /// regardless of how the new entry's own write turned out (#486 R2).
    public let evictedCount: Int

    public init(persisted: Bool, evictedCount: Int) {
        self.persisted = persisted
        self.evictedCount = evictedCount
    }
}

/// The "new recording wins" write loop (#486 review F5, mirroring the web
/// queue's `recordingQueue.ts` policy under CLAUDE.md #264): a refused write
/// retries after dropping the oldest other queued entry, repeatedly, down to
/// the new entry alone. Extracted to a pure function because both real
/// defects the #486 re-review found (a proven infinite loop, and evicted
/// recordings deleted with no notice) lived in exactly this control flow with
/// no tests on it (#495 R3) — here the loop's termination and counting are
/// testable deterministically, on Linux CI, with no filesystem at all.
///
/// Termination is guaranteed by two independent mechanisms, both required
/// (#486 re-review R1 — the first version was `while true` with the removal
/// wrapped in `try?`, and spun for 200,001 iterations when removal failed):
/// (1) `evictOldest` reporting anything but `.evicted` stops the loop, and
/// (2) the loop is additionally bounded by `maxEvictions` (the number of
/// other files present when it started), so it cannot run away even if a
/// future change reintroduces a silent-failure path in the callback.
public enum EvictingWrite {
    public static func run(
        maxEvictions: Int,
        write: () throws -> Void,
        evictOldest: () -> EvictionAttemptOutcome
    ) -> EvictingWriteResult {
        var evictedCount = 0
        // 0...max: one attempt with nothing evicted, plus one after each
        // possible eviction.
        for _ in 0...max(0, maxEvictions) {
            do {
                try write()
                return EvictingWriteResult(persisted: true, evictedCount: evictedCount)
            } catch {
                switch evictOldest() {
                case .evicted:
                    evictedCount += 1
                case .evictionRefused, .nothingLeftToEvict:
                    return EvictingWriteResult(persisted: false, evictedCount: evictedCount)
                }
            }
        }
        return EvictingWriteResult(persisted: false, evictedCount: evictedCount)
    }
}
