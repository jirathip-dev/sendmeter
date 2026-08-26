import SendmeterCore
import SwiftUI

/// Shared presentation treatment for regular bottom sheets (#789).
///
/// Apply this to the sheet content, not to a `fullScreenCover`: the latter is
/// reserved for active routine/manual/guided execution surfaces and keeps its
/// existing fullscreen and interactive-dismiss behavior. The lifecycle gate
/// is local to each presentation host so nested sheets do not share state,
/// while the haptics dispatcher keeps the standard cue deduped across close
/// buttons, replacement, swipe dismissal, and programmatic dismissal.
private struct SendmeterSheetPresentationModifier: ViewModifier {
    private let presentationID: String?
    @State private var lifecycle = SheetPresentationLifecycle()

    init(presentationID: String? = nil) {
        self.presentationID = presentationID
    }

    func body(content: Content) -> some View {
        content
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(CGFloat(SheetPresentationPolicy.cornerRadius))
            .onAppear {
                emit(lifecycle.appeared(id: presentationID))
            }
            .onChange(of: presentationID) { _ in
                emit(lifecycle.appeared(id: presentationID))
            }
            .onDisappear {
                emit(lifecycle.disappeared(id: presentationID))
            }
    }

    private func emit(_ event: SheetPresentationEvent) {
        switch event {
        case .presented:
            Haptics.shared.sheetPresented()
        case .replaced:
            // Replacing an item-backed sheet is one close followed by one
            // open. Updating the lifecycle identity before these calls means
            // a stale old-item disappearance cannot add another close tick.
            Haptics.shared.sheetDismissed()
            Haptics.shared.sheetPresented()
        case .dismissed:
            Haptics.shared.sheetDismissed()
        case .none:
            break
        }
    }
}

public extension View {
    /// Applies the app-wide grabber, radius, and sheet haptic lifecycle.
    func sendmeterSheetPresentation() -> some View {
        modifier(SendmeterSheetPresentationModifier())
    }

    /// Item-backed sheets pass their identity so replacement cannot be
    /// mistaken for a second appearance or a dismissal of the new item.
    func sendmeterSheetPresentation(id: String) -> some View {
        modifier(SendmeterSheetPresentationModifier(presentationID: id))
    }
}
