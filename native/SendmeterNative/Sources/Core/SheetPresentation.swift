import Foundation

/// The lifecycle events that a SwiftUI sheet host can produce. SwiftUI may
/// call `onAppear` more than once while a presentation is alive, and an
/// item-backed sheet can replace its content without dismissing the host.
/// Keeping those cases in a small value type makes the haptic contract
/// testable without importing SwiftUI or UIKit.
public enum SheetPresentationEvent: Equatable, Sendable {
    case none
    case presented
    case replaced
    case dismissed
}

/// Deduplicates sheet mount/unmount callbacks, including item replacement.
/// The identity is intentionally optional: boolean-backed sheets only need
/// appearance/disappearance dedupe, while item-backed sheets pass their item
/// identity so a stale disappearance from the old item cannot close the new
/// presentation.
public struct SheetPresentationLifecycle: Equatable, Sendable {
    public private(set) var isPresented = false
    private var presentationID: String?

    public init() {}

    @discardableResult
    public mutating func appeared(id: String? = nil) -> SheetPresentationEvent {
        guard isPresented else {
            isPresented = true
            presentationID = id
            return .presented
        }

        guard presentationID != id else { return .none }
        presentationID = id
        return .replaced
    }

    @discardableResult
    public mutating func disappeared(id: String? = nil) -> SheetPresentationEvent {
        guard isPresented, presentationID == id else { return .none }
        isPresented = false
        presentationID = nil
        return .dismissed
    }
}

/// The shared native sheet treatment. Keep this value in Core so the App
/// modifier and its source-level presentation contract agree on one number.
public enum SheetPresentationPolicy {
    public static let cornerRadius: Double = 18
}
