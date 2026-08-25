import Foundation

/// The two-step Delete Account flow gate (#759).
///
/// The first step is a warning surface only. Deleting is never reachable
/// until the user deliberately advances to the confirmation step and types
/// the exact phrase. The gate is pure Foundation so SwiftUI cannot drift into
/// a path where a stray tap arms the destructive action.
public enum DeleteAccountFlowStage: Equatable, Sendable {
    case warning
    case confirmation
}

public struct DeleteAccountConfirmationGate: Equatable, Sendable {
    public static let phrase = "DELETE"

    public private(set) var stage: DeleteAccountFlowStage
    public private(set) var entry: String

    public init(
        stage: DeleteAccountFlowStage = .warning,
        entry: String = ""
    ) {
        self.stage = stage
        self.entry = stage == .warning ? "" : entry
    }

    public var canConfirm: Bool {
        stage == .confirmation && entry == Self.phrase
    }

    public mutating func advanceFromWarning() {
        guard stage == .warning else { return }
        stage = .confirmation
    }

    public mutating func backToWarning() {
        stage = .warning
        entry = ""
    }

    public mutating func updateEntry(_ value: String) {
        guard stage == .confirmation else {
            entry = ""
            return
        }
        entry = value
    }
}
