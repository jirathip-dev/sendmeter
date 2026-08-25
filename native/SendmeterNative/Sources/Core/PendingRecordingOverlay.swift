import Foundation

/// The in-memory optimistic recording layer is account-scoped even though a
/// `TindeqRecording` itself has no account column. A queue snapshot can outlive
/// an account switch, so every pending value keeps the account that authorized
/// it and every restore/merge proves the current account before using it.
public struct PendingRecordingOverlay: Sendable {
    public struct Entry: Sendable {
        public let accountUserID: UUID
        public let recording: TindeqRecording

        public init(accountUserID: UUID, recording: TindeqRecording) {
            self.accountUserID = accountUserID
            self.recording = recording
        }
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// Add an optimistic row before an upload begins. The account is retained
    /// separately because the metadata model is also used for remote rows.
    public mutating func insert(_ recording: TindeqRecording, accountUserID: UUID) {
        entries[recording.id] = Entry(accountUserID: accountUserID, recording: recording)
    }

    /// Apply entries read from the durable queue after an async boundary. The
    /// captured identity is checked here as well as at the caller's boundary,
    /// so a stale restore cannot publish even if a future caller forgets the
    /// outer guard. Mismatched queue entries are never accepted.
    @discardableResult
    public mutating func applyRestored(
        _ restored: [Entry],
        capturedBy accountFetch: AccountScopedFetch,
        currentUserID: UUID?,
        accountEpoch: UInt64
    ) -> Bool {
        guard accountFetch.canApply(to: currentUserID, accountEpoch: accountEpoch) else {
            return false
        }
        for entry in restored where entry.accountUserID == accountFetch.accountUserID {
            entries[entry.recording.id] = entry
        }
        return true
    }

    public func contains(id: UUID, accountUserID: UUID?) -> Bool {
        guard let accountUserID else { return false }
        return entries[id]?.accountUserID == accountUserID
    }

    public func ids(accountUserID: UUID?) -> Set<UUID> {
        guard let accountUserID else { return [] }
        return Set(
            entries.compactMap { id, entry in
                entry.accountUserID == accountUserID ? id : nil
            }
        )
    }

    public func recordings(accountUserID: UUID?) -> [TindeqRecording] {
        guard let accountUserID else { return [] }
        return entries.values
            .filter { $0.accountUserID == accountUserID }
            .map(\.recording)
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public mutating func removeValue(for id: UUID, accountUserID: UUID) {
        guard entries[id]?.accountUserID == accountUserID else { return }
        entries.removeValue(forKey: id)
    }

    public mutating func removeValues(withIDs ids: Set<UUID>, accountUserID: UUID) {
        for id in ids {
            removeValue(for: id, accountUserID: accountUserID)
        }
    }

    /// Merge only the pending values owned by the current account. Remote
    /// rows win by id, matching the upload reconciliation rule.
    public func merged(remote: [TindeqRecording], accountUserID: UUID?) -> [TindeqRecording] {
        let remoteIDs = Set(remote.map(\.id))
        let pending = entries.values
            .filter { entry in
                entry.accountUserID == accountUserID
                    && !remoteIDs.contains(entry.recording.id)
            }
            .map(\.recording)
        return remote + pending
    }
}
