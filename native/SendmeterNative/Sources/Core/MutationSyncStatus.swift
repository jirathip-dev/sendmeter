import Foundation

// MARK: - Mutation status presentation (#920)

/// #920: what one "Retry Now" pass did, measured against the account's own
/// durable answers. It exists so the next status render can tell "there is
/// still work this button can move" from "the residue survived a retry and
/// this app version has no path for it".
///
/// The counts are read from the queue and the local cache — the two
/// acknowledgement channels — never from the optimistic in-memory state.
public struct MutationRetryOutcome: Equatable, Sendable {
    public let accountUserID: UUID
    public let queuedBefore: Int
    public let queuedAfter: Int
    public let unsyncedBefore: Int
    public let unsyncedAfter: Int
    /// `nil` when the queue's quarantine list could not be read during the
    /// pass; an unread list is never reported as zero (#269).
    public let quarantinedAfter: Int?

    public init(
        accountUserID: UUID,
        queuedBefore: Int,
        queuedAfter: Int,
        unsyncedBefore: Int,
        unsyncedAfter: Int,
        quarantinedAfter: Int?
    ) {
        self.accountUserID = accountUserID
        self.queuedBefore = queuedBefore
        self.queuedAfter = queuedAfter
        self.unsyncedBefore = unsyncedBefore
        self.unsyncedAfter = unsyncedAfter
        self.quarantinedAfter = quarantinedAfter
    }

    /// Queue entries this pass removed (uploaded or newly quarantined).
    public var clearedQueueCount: Int { max(0, queuedBefore - queuedAfter) }

    /// The cache-only rows the pass left behind with nothing left in the
    /// queue — i.e. the residue the retry provably could not hand to the
    /// server. Non-zero only when the queue itself is empty, so a transient
    /// queue failure never disables the retry affordance.
    public var unresolvedResidueCount: Int {
        queuedAfter == 0 ? max(0, unsyncedAfter) : 0
    }

    public var changedAnything: Bool {
        clearedQueueCount > 0 || unsyncedAfter < unsyncedBefore
    }
}

/// #920: the four states the sync surface must distinguish. There is
/// deliberately no `synced` default: `notLoaded` is what an uninitialized
/// zero count is.
public enum MutationSyncState: Equatable, Sendable {
    /// The account's durable queue/quarantine answer has not been read yet
    /// this session. Zero counts here mean "unknown", not "nothing pending".
    case notLoaded
    /// Every local change is confirmed by the server.
    case synced
    /// Saved on this device and still waiting to upload (queue work and/or
    /// unconfirmed local rows).
    case awaitingUpload
    /// The server rejected work, or a residue survived a retry with no
    /// upload path left. Needs a human decision.
    case needsAttention
}

/// #920: why the visible retry control cannot do anything. Presenting an
/// enabled control for work it does not retry is the defect this closes.
public enum MutationRetryBlockReason: Equatable, Sendable {
    /// Nothing queued and nothing unsynced: there is no retry to offer.
    case nothingPending
    /// A residue survived a retry pass and the queue is empty — retrying
    /// again would be the silent no-op the issue names.
    case noUploadPath
}

public enum MutationRetryAvailability: Equatable, Sendable {
    /// No retry control belongs on screen.
    case hidden
    /// There is work this retry actually reaches.
    case ready
    /// A pass for this account is already in flight; a second tap coalesces.
    case inFlight
    /// There is a visible control, but it must be disabled with the reason.
    case unavailable(MutationRetryBlockReason)
}

/// The observable inputs the status is derived from. Each one is produced by
/// an acknowledged read (the queue's own answer, the cache's pending-row
/// count, the quarantine list) — never by a local guess.
public struct MutationSyncStatusInputs: Equatable, Sendable {
    public var hasLoadedPendingWrites: Bool
    public var queuedCount: Int
    public var unsyncedCacheCount: Int
    public var quarantinedCount: Int?
    public var isRetrying: Bool
    public var lastRetryOutcome: MutationRetryOutcome?

    public init(
        hasLoadedPendingWrites: Bool = false,
        queuedCount: Int = 0,
        unsyncedCacheCount: Int = 0,
        quarantinedCount: Int? = nil,
        isRetrying: Bool = false,
        lastRetryOutcome: MutationRetryOutcome? = nil
    ) {
        self.hasLoadedPendingWrites = hasLoadedPendingWrites
        self.queuedCount = queuedCount
        self.unsyncedCacheCount = unsyncedCacheCount
        self.quarantinedCount = quarantinedCount
        self.isRetrying = isRetrying
        self.lastRetryOutcome = lastRetryOutcome
    }
}

/// #920: the one derivation of "is my work actually uploaded", shared by
/// Settings and the affected save surfaces instead of each surface counting
/// its own way.
public struct MutationSyncStatus: Equatable, Sendable {
    public let state: MutationSyncState
    public let queuedCount: Int
    public let unsyncedCount: Int
    public let quarantinedCount: Int?
    public let retry: MutationRetryAvailability
    /// Cache-only rows that a retry pass already proved cannot be uploaded by
    /// this app version.
    public let unresolvedResidueCount: Int

    public var pendingCount: Int { queuedCount + unsyncedCount }

    public static func resolve(_ inputs: MutationSyncStatusInputs) -> MutationSyncStatus {
        // `quarantinedCount == nil` means the queue's quarantine list has not
        // been read: the honest state is "not loaded", never "Synced".
        guard inputs.hasLoadedPendingWrites, let quarantined = inputs.quarantinedCount else {
            return MutationSyncStatus(
                state: .notLoaded,
                queuedCount: inputs.queuedCount,
                unsyncedCount: inputs.unsyncedCacheCount,
                quarantinedCount: nil,
                retry: .hidden,
                unresolvedResidueCount: 0
            )
        }
        let residue = inputs.lastRetryOutcome?.unresolvedResidueCount ?? 0
        let state: MutationSyncState
        if quarantined > 0 || residue > 0 {
            state = .needsAttention
        } else if inputs.queuedCount + inputs.unsyncedCacheCount > 0 {
            state = .awaitingUpload
        } else {
            state = .synced
        }
        let retry: MutationRetryAvailability
        if inputs.isRetrying {
            retry = .inFlight
        } else if inputs.queuedCount > 0 {
            retry = .ready
        } else if inputs.unsyncedCacheCount > 0 {
            // The queue is empty. A residue is retryable while its adoption
            // has not been attempted this session; once a pass has run and the
            // row is still unconfirmed with nothing queued, another tap is the
            // silent no-op #920 exists to remove.
            retry = residue > 0 ? .unavailable(.noUploadPath) : .ready
        } else if quarantined > 0 {
            // Rejected uploads have their own row-level Retry/Discard; never
            // fold them into the queue retry.
            retry = .hidden
        } else {
            retry = .unavailable(.nothingPending)
        }
        return MutationSyncStatus(
            state: state,
            queuedCount: inputs.queuedCount,
            unsyncedCount: inputs.unsyncedCacheCount,
            quarantinedCount: quarantined,
            retry: retry,
            unresolvedResidueCount: residue
        )
    }

    // MARK: User-facing copy

    /// The status pill. `notLoaded` never renders as "Synced".
    public var statusLabel: String {
        switch state {
        case .notLoaded:
            return "Checking…"
        case .synced:
            return "Synced"
        case .awaitingUpload:
            return "\(pendingCount) waiting to upload"
        case .needsAttention:
            if let quarantinedCount, quarantinedCount > 0 {
                return "\(quarantinedCount) rejected"
            }
            return "\(unresolvedResidueCount) stayed on this iPhone"
        }
    }

    public var explanation: String {
        switch state {
        case .notLoaded:
            return "Checking this iPhone's pending changes and uploads."
        case .synced:
            return "Every change on this iPhone has been confirmed by the server."
        case .awaitingUpload:
            return awaitingUploadExplanation
        case .needsAttention:
            return needsAttentionExplanation
        }
    }

    private var awaitingUploadExplanation: String {
        let queuedPhrase = "\(queuedCount) queued upload\(queuedCount == 1 ? "" : "s")"
        let residuePhrase = "\(unsyncedCount) local change\(unsyncedCount == 1 ? "" : "s") saved on this iPhone"
        if queuedCount > 0, unsyncedCount > 0 {
            return "\(residuePhrase), plus \(queuedPhrase) kept here. Nothing has been dropped; uploads retry automatically."
        }
        if queuedCount > 0 {
            return "\(queuedPhrase.capitalizedFirst) kept on this iPhone and retrying automatically."
        }
        return "\(residuePhrase.capitalizedFirst) and not uploaded yet. Use Retry Now to upload it."
    }

    private var needsAttentionExplanation: String {
        if let quarantinedCount, quarantinedCount > 0 {
            return "The server rejected \(quarantinedCount) change\(quarantinedCount == 1 ? "" : "s"). They are kept on this device and never retried on their own — retry or discard them below."
        }
        return "\(unresolvedResidueCount) local change\(unresolvedResidueCount == 1 ? "" : "s") could not be uploaded and stayed on this iPhone. The server's answer never confirmed them."
    }

    /// Shown beside a disabled Retry control so the disabled state is
    /// explained instead of silently doing nothing.
    public var retryUnavailableExplanation: String? {
        guard case let .unavailable(reason) = retry else { return nil }
        switch reason {
        case .nothingPending:
            return "Nothing is waiting to upload."
        case .noUploadPath:
            return "Retrying cannot move these changes: this app version has no upload path for them, so they stay on this iPhone until they are re-saved."
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
