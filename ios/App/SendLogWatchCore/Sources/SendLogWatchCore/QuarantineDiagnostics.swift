import Foundation

// MARK: - Issue #599 — quarantined-upload diagnostics on the watch

/// The header-only projection of a quarantined item's on-disk record, for
/// display (#599). Deliberately carries none of the item's payload — the
/// engine builds these from a probe that stops short of decoding the sample
/// arrays / raw trace (the same rule `quarantinedCount` already follows), so
/// listing a queue's quarantine reads only the header bytes, never the heavy
/// part of every record.
public struct QuarantineDiagnosticItem: Equatable, Sendable {
    /// The item's `queueFileId` — names the on-disk file and identifies the
    /// item without any decoded payload.
    public let id: UUID
    public let reason: QuarantineReason
    public let stage: UploadStage?
    public let httpStatus: Int?
    public let postgrestCode: String?
    /// Truncated for display via `QuarantineDiagnostics.truncatedErrorMessage`.
    public let errorMessage: String?
    public let attemptCount: Int?
    public let quarantinedAt: Date
    /// Honest provenance (#491 F1): true when the stored item is a
    /// `strippedOfHeavyPayload()` copy — either stripped at quarantine time
    /// (workouts shed `raw`) or reclaimed under disk pressure (recordings).
    /// A retry of this item uploads its real summary stats but not the
    /// original buffer, and display must never describe it as a full restore.
    public let payloadDropped: Bool?

    public init(
        id: UUID,
        reason: QuarantineReason,
        stage: UploadStage?,
        httpStatus: Int?,
        postgrestCode: String?,
        errorMessage: String?,
        attemptCount: Int?,
        quarantinedAt: Date,
        payloadDropped: Bool?
    ) {
        self.id = id
        self.reason = reason
        self.stage = stage
        self.httpStatus = httpStatus
        self.postgrestCode = postgrestCode
        self.errorMessage = errorMessage
        self.attemptCount = attemptCount
        self.quarantinedAt = quarantinedAt
        self.payloadDropped = payloadDropped
    }
}

/// One row the diagnostics surface renders. `unreadable` exists because an
/// unreadable/undecodable `.quarantine` file is retained, never deleted
/// (#287) — it must stay VISIBLE as unreadable rather than silently
/// vanishing from the count (the same "retained and reported" policy
/// `quarantinedCount` already applies to it).
public enum QuarantineDiagnosticEntry: Equatable, Sendable {
    case record(QuarantineDiagnosticItem)
    case unreadable(id: UUID)
}

/// Copy selection per `QuarantineReason` (#599) — the two cases need
/// different, non-interchangeable wording, mirroring the split the phone
/// already makes in `uploadWarningPresentation` (src/lib/watchBuild.ts):
/// `.schemaRejection` reads as "could not be uploaded and will not retry",
/// `.stuckRetrying` as "having trouble uploading — retrying automatically".
/// Telling the user the wrong one is worse than not splitting them, so this
/// lives in Core where it is unit-tested on Linux, not as an untested switch
/// in the view.
public enum QuarantineCopy {
    public static func title(for reason: QuarantineReason) -> String {
        switch reason {
        case .schemaRejection:
            return "Could not be uploaded — will not retry"
        case .stuckRetrying:
            return "Having trouble uploading — retrying automatically"
        }
    }

    public static func detail(for reason: QuarantineReason) -> String {
        switch reason {
        case .schemaRejection:
            return "The server permanently rejected this upload. It stays saved on your watch; retrying it won't help."
        case .stuckRetrying:
            return "It gets one automatic retry in a few days. You can also retry it now."
        }
    }

    /// Shown on an item whose stored payload is a stripped copy
    /// (`payloadDropped == true`) — the honest companion to a retry of that
    /// item: it uploads summary numbers, not the original buffer (#600 ask 5).
    public static let payloadDroppedNote =
        "Some detail was dropped at quarantine — a retry uploads its summary, not the original buffer."
}

/// Pure display helpers for the quarantine diagnostics surface (#599).
public enum QuarantineDiagnostics {
    /// PostgREST error messages ride in the `.quarantine` file indefinitely,
    /// and the diagnostics list can show several at once on a small screen —
    /// truncate for display. The phone's own stuck-recording diagnostics cap
    /// at 300 (src/lib/recordingQueue.ts `failureDetail`); a wrist surface
    /// gets the tighter bound.
    public static let errorMessageDisplayLimit = 160

    public static func truncatedErrorMessage(
        _ message: String,
        limit: Int = errorMessageDisplayLimit
    ) -> String {
        guard message.count > limit else { return message }
        return String(message.prefix(max(limit - 1, 0))) + "…"
    }
}

/// The retry decision + copy for #600 — a manual "Retry stuck uploads" action.
/// The decision belongs here (not in the view or the engine) because it is
/// policy: `.stuckRetrying` is a bet and a retry is a legitimate option,
/// `.schemaRejection` is proven permanent and must never be offered as an
/// equal one.
public enum QuarantineRetryPolicy {
    public static func isManuallyRetryable(_ reason: QuarantineReason) -> Bool {
        switch reason {
        case .schemaRejection: return false
        case .stuckRetrying: return true
        }
    }

    public static let retryActionTitle = "Retry stuck uploads"

    public static let retryActionDetail =
        "Moves retryable uploads back to the upload queue and tries them now."

    /// Result copy after a manual retry: `restored` items were moved back to
    /// the pending queue (and usually uploaded right away), `kept` stayed
    /// quarantined (permanent rejections, another account's items, or
    /// unreadable records). nil when nothing was attempted — the caller
    /// shows nothing rather than claiming a retry that never happened.
    public static func resultSummary(restored: Int, kept: Int) -> String? {
        guard restored > 0 || kept > 0 else { return nil }
        var parts: [String] = []
        if restored > 0 {
            parts.append("\(restored) upload\(restored == 1 ? "" : "s") moved back to the queue")
        }
        if kept > 0 {
            parts.append("\(kept) left in quarantine")
        }
        return parts.joined(separator: " · ")
    }
}
