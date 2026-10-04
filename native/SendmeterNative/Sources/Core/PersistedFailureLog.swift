import Foundation
import os

/// #992: one failure line meant to SURVIVE on device.
///
/// The owner's device capture proved the app's own logging did not persist:
/// `.info`/`.debug` messages are not kept in the unified log by default, and
/// the launch and sync/replay paths had no `.notice` line that named the
/// failing step, so a device-only failure could not name its own error (the
/// #964 diagnosis ran on hypotheses because of it). Every raised failure now
/// goes through this one shape:
///
/// * fixed vocabulary only — the operation, the error DOMAIN and CODE, the
///   taxonomy class, and whether the same failure was surfaced to the user;
/// * never a message, payload, token, session id, email or URL (callers pass
///   step labels they wrote themselves — see `AppModel.persistedFailureSink`);
/// * `.notice` — the level that persists by default — so a transcript filtered
///   to persisted levels carries the line.
public struct PersistedFailureLine: Equatable, Sendable {
    /// The log category the line lands under. `launchFailure` keeps #964 round
    /// 2's category verbatim so an existing device-side grep stays continuous.
    public enum Channel: String, Equatable, Sendable {
        case launchFailure = "launch-failure"
        case syncReplayFailure = "sync-replay-failure"

        var messagePrefix: String {
            switch self {
            case .launchFailure: return "launch failure"
            case .syncReplayFailure: return "sync/replay failure"
            }
        }
    }

    /// The os_log level of the line. `.notice` (OS_LOG_TYPE_DEFAULT) is the
    /// level that is persisted and shown by default; a line raised at `.debug`
    /// is invisible to `log show` without `--debug`. `.debug` exists only so a
    /// deliberate downgrade is expressible — and caught by the tests that
    /// assert `.notice`.
    public enum Level: String, Equatable, Sendable {
        case notice
        case debug
    }

    public let channel: Channel
    public let level: Level
    /// The failing operation's name — a fixed label from the code, never user
    /// input.
    public let operation: String
    /// The bridged NSError domain (`NSURLErrorDomain`, `GRDB.DatabaseError`, …).
    public let domain: String
    public let code: Int
    /// Whether the same failure produced a user-visible surface at this step
    /// (the error banner, the Dashboard load-failure state, the Settings
    /// repair notice, a manual-retry outcome). A deliberately suppressed
    /// degradation carries `false` — that is the distinction a device
    /// transcript needs to tell a working degradation from a hidden defect.
    public let surfaced: Bool
    /// The raw `FriendlyErrorClass` name. Kept raw on purpose (the #964 rule):
    /// an `.unknown` here is the signal the taxonomy still lacks a class for
    /// the real failure.
    public let classification: String

    public init(
        channel: Channel,
        level: Level = .notice,
        operation: String,
        domain: String,
        code: Int,
        surfaced: Bool,
        classification: String
    ) {
        self.channel = channel
        self.level = level
        self.operation = operation
        self.domain = domain
        self.code = code
        self.surfaced = surfaced
        self.classification = classification
    }

    /// The exact text the unified log carries — readable in a device
    /// transcript without grepping source.
    public var message: String {
        let operationKey = channel == .launchFailure ? "step" : "op"
        return [
            channel.messagePrefix,
            "\(operationKey)=\(operation)",
            "domain=\(domain)",
            "code=\(code)",
            "class=\(classification)",
            "surfaced=\(surfaced)"
        ].joined(separator: " ")
    }
}

/// #992: the production sink for ``PersistedFailureLine``s and the one place
/// the os_log emission lives.
///
/// `AppModel` routes every raised failure through an injectable sink that
/// defaults to ``emit`` — app-target tests substitute a capture so the emitted
/// fields are asserted as behaviour, never by reading this file's source
/// tokens.
public enum PersistedFailureLog {
    public static let subsystem = "com.jirathip.sendlog.native"

    private static let launchLogger = Logger(
        subsystem: subsystem,
        category: PersistedFailureLine.Channel.launchFailure.rawValue
    )
    private static let syncReplayLogger = Logger(
        subsystem: subsystem,
        category: PersistedFailureLine.Channel.syncReplayFailure.rawValue
    )

    /// Writes one line at its own level. Everything but `.notice` is invisible
    /// to a persisted-only transcript, which is exactly why production raises
    /// failures at `.notice`.
    public static func emit(_ line: PersistedFailureLine) {
        let logger = line.channel == .launchFailure ? launchLogger : syncReplayLogger
        switch line.level {
        case .notice:
            logger.notice("\(line.message, privacy: .public)")
        case .debug:
            logger.debug("\(line.message, privacy: .public)")
        }
    }

    /// Builds the line for one failed operation from the error itself: domain
    /// and code from the bridged `NSError`, the class from the same taxonomy
    /// the user-facing copy uses.
    public static func line(
        channel: PersistedFailureLine.Channel,
        operation: String,
        error: Error,
        surfaced: Bool
    ) -> PersistedFailureLine {
        let nsError = error as NSError
        return PersistedFailureLine(
            channel: channel,
            operation: operation,
            domain: nsError.domain,
            code: nsError.code,
            surfaced: surfaced,
            classification: String(describing: UserFacingError.classification(for: error))
        )
    }
}
