import SendmeterCore
import SwiftUI

/// Shared tooltip chrome for the native Training Load charts. The tooltip is
/// visual-only; the selected chart element owns the same information through
/// its accessibility label/value so VoiceOver does not announce it twice.
struct TrainingLoadTooltip<Content: View>: View {
    @Environment(\.colorScheme) private var scheme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(ChartToken.tooltip.color(scheme), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(ChartToken.tooltipBorder.color(scheme), lineWidth: 1)
            )
            .shadow(radius: 4, y: 2)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
