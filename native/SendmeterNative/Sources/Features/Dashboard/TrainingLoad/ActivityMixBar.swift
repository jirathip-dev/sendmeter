import SendmeterCore
import SwiftUI

/// The horizontal 28-day activity-mix bar (web `ActivityMixBar`), collapsed to
/// a single VoiceOver element labelled with each activity + share.
///
/// Widths are proportional only (F9): the web deliberately has NO minimum
/// slice — `trainingLoadSheet.test.tsx` asserts a 0.1% share stays `0.1%`
/// without a `min-width` — so a sub-1% sliver renders proportionally, and a
/// floor would make the fixed widths sum past the container, clipping the
/// rightmost activity.
struct ActivityMixBar: View {
    let activities: [ActivityLoad]

    @Environment(\.colorScheme) private var scheme

    private var description: String {
        activities
            .map { "\($0.label) \(TrainingLoad.formatSharePercent($0.percentage))" }
            .joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            HStack(spacing: 0) {
                ForEach(activities, id: \.type) { activity in
                    RoundedRectangle(cornerRadius: 0, style: .continuous)
                        .fill(ChartActivityHue.color(forActivityID: activity.type, scheme: scheme))
                        .frame(width: total * CGFloat(activity.percentage) / 100)
                }
            }
            .frame(width: total, alignment: .leading)
        }
        .frame(height: 10)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity mix: \(description)")
    }
}
