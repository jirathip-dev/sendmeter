import Foundation
import SendLogWatchCore
import SwiftUI

/// Shared with `ForceGaugeView` (which owns the `tag`/`side` state) — moved
/// here because `ForceProtocolChooserView` is now the one compact top-level
/// selector for exercise, side AND protocol (issue #537).
// SL-585 follow-up: the watch offers only Left/Right (the main page's
// toggle); "both"/unspecified are web-only now, kept in this table solely
// so `sideLabel` can still DISPLAY legacy values on old runs/recordings.
let SIDE_OPTIONS: [(value: String, label: String)] = [
    ("", "—"),
    ("left", "Left"),
    ("right", "Right"),
    ("both", "Both"),
]

func sideLabel(_ value: String) -> String {
    SIDE_OPTIONS.first { $0.value == value }?.label ?? value
}

/// Presentation-only helpers for the read-only watch protocol catalog.
/// Storage names such as `reverse_action` stay below this boundary; the watch
/// speaks in the terms a climber sees while setting up a session.
enum ForceProtocolPresentation {
    static func category(for protocolValue: WatchForceProtocol) -> String {
        protocolValue.mode == .hold ? "STATIC" : WatchForceProtocol.Labels.movement
    }

    static func modeDescription(for protocolValue: WatchForceProtocol) -> String {
        protocolValue.mode == .hold ? "Static hold" : WatchForceProtocol.Labels.resistedMovement
    }

    static func detail(for protocolValue: WatchForceProtocol) -> String {
        let reps = protocolValue.reps == 1 ? "rep" : "reps"
        let sets = protocolValue.sets == 1 ? "set" : "sets"
        let repsAndSets = "\(protocolValue.reps) \(reps) × \(protocolValue.sets) \(sets)"

        switch protocolValue.mode {
        case .hold:
            let rest = protocolValue.sets > 1 && protocolValue.restSetsS > 0
                ? " · \(seconds(protocolValue.restSetsS)) rest"
                : ""
            return "\(seconds(protocolValue.holdS)) hold · \(repsAndSets)\(rest)"
        case .reverseAction:
            let rest = protocolValue.sets > 1 && protocolValue.restSetsS > 0
                ? " · \(seconds(protocolValue.restSetsS)) rest"
                : ""
            return "\(seconds(protocolValue.cadenceOutS)) \(WatchForceProtocol.Labels.concentric) · "
                + "\(seconds(protocolValue.cadenceReturnS)) \(WatchForceProtocol.Labels.eccentric) · "
                + "\(repsAndSets)\(rest)"
        }
    }

    /// Setup-card copy stays short enough for a 40mm screen. The chooser keeps
    /// `detail(for:)` as the full protocol summary.
    static func compactDetail(for protocolValue: WatchForceProtocol) -> String {
        let reps = protocolValue.reps == 1 ? "rep" : "reps"
        let sets = protocolValue.sets == 1 ? "set" : "sets"
        let repsAndSets = "\(protocolValue.reps) \(reps) × \(protocolValue.sets) \(sets)"
        switch protocolValue.mode {
        case .hold:
            return "\(seconds(protocolValue.holdS)) hold · \(repsAndSets)"
        case .reverseAction:
            return "\(seconds(protocolValue.cadenceOutS)) \(WatchForceProtocol.Labels.concentric) · "
                + "\(seconds(protocolValue.cadenceReturnS)) \(WatchForceProtocol.Labels.eccentric) · "
                + repsAndSets
        }
    }

    /// `alternate_sides` is a static-only iPhone behavior. The watch keeps the
    /// protocol visible in the read-only catalog, but cannot truthfully run it
    /// because a single watch-side side selection cannot alternate holds.
    static let alternatingSidesUnavailable =
        "Run on iPhone · alternating sides unsupported on watch"

    static func watchAvailability(for protocolValue: WatchForceProtocol) -> String? {
        guard protocolValue.mode == .hold, protocolValue.alternateSides else { return nil }
        return alternatingSidesUnavailable
    }

    static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value.rounded() == value { return "\(Int(value))s" }
        return String(format: "%.1fs", value)
    }
}

/// Full-height read-only exercise/side/protocol chooser — the one compact
/// top-level selector issue #537 asks for (`ForceGaugeView`'s top-right
/// context action opens this). Exercise and side stay pick-only here for the
/// same reason they always have (typing on a watch is miserable, and side
/// has only four real values); Suggested content is always available, even
/// while the user's protocol catalog is loading or unavailable, so the safe
/// Movement Starter default never disappears during a token relay.
struct ForceProtocolChooserView: View {
    @Bindable private var catalog: ForceProtocolCatalog
    @Binding private var tag: String
    let recentTags: [String]
    let tagsLoading: Bool
    let onRetryTags: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    init(
        catalog: ForceProtocolCatalog,
        tag: Binding<String>,
        recentTags: [String],
        tagsLoading: Bool,
        onRetryTags: @escaping () -> Void
    ) {
        _catalog = Bindable(wrappedValue: catalog)
        _tag = tag
        self.recentTags = recentTags
        self.tagsLoading = tagsLoading
        self.onRetryTags = onRetryTags
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // SL-585 follow-up: no Side section any more — the main
                // page's L|R toggle is the one side control on the watch
                // ("both"/unspecified stay web-only by decision; legacy
                // stored values still display and never get rewritten).
                sectionHeader("Exercise")
                exerciseSection

                catalogStatus

                sectionHeader("Suggested")
                WatchChipFlow {
                    ForEach(catalog.suggested) { protocolValue in
                        protocolRow(protocolValue)
                    }
                }

                sectionHeader("My protocols")
                if catalog.myProtocols.isEmpty {
                    emptyProtocols
                } else {
                    WatchChipFlow {
                        ForEach(catalog.myProtocols) { protocolValue in
                            protocolRow(protocolValue)
                        }
                    }
                }

                selectedProtocolSummary

                Text("Exercises and protocols are managed on your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .navigationTitle("Force setup")
        .navigationBarTitleDisplayMode(.inline)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(WatchPalette.canvas)
        .watchCanvas()
        .accessibilityIdentifier("force-protocol-chooser")
    }

    /// Deliberately NOT a `.navigationLink` Picker (#279's reasoning still
    /// applies): tapping selects immediately and stays on this screen, since
    /// exercise, side and protocol are peer selections the user may want to
    /// review together before returning to Force setup.
    @ViewBuilder
    private var exerciseSection: some View {
        if tagsLoading && recentTags.isEmpty {
            WatchLoadingState(title: "Loading exercises…")
        } else if recentTags.isEmpty {
            WatchCard(accent: WatchPalette.warning) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No exercises yet")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.textPrimary)
                    Text("Create an exercise in the iPhone app, then try again.")
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry", action: onRetryTags)
                        .buttonStyle(WatchSecondaryButtonStyle(tint: WatchPalette.foreground(WatchDesignTokens.warning)))
                }
            }
            .accessibilityIdentifier("force-exercise-empty")
        } else {
            // #791 W2: the phone's #750 compact chip picker, on watch — one
            // wrapping row of chips instead of full-height card rows. Hit
            // targets stay at the design minimum; the selected chip is the
            // solid one.
            WatchChipFlow {
                ForEach(recentTags, id: \.self) { option in
                    exerciseChip(option)
                }
            }
        }
    }

    /// One compact exercise chip — the watch analogue of the phone's
    /// #750 selector chip. Selected = solid accent fill, unselected = tinted
    /// surface; the row of chips replaces the old full-width card rows so
    /// the picker fits the small screen without scrolling a tall list.
    private func exerciseChip(_ option: String) -> some View {
        let selected = option == tag
        let accent = WatchPalette.accent(WatchDesignTokens.primary, reducedLuminance: isLuminanceReduced)
        return Button {
            tag = option
        } label: {
            Text(option)
                .font(.system(size: 12, weight: selected ? .heavy : .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    selected ? WatchPalette.textPrimary : WatchPalette.foreground(WatchDesignTokens.primary)
                )
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background {
                    Capsule()
                        .fill(accent.opacity(selected ? 0.42 : 0.12))
                        .overlay {
                            Capsule().stroke(
                                accent.opacity(selected ? 0.9 : 0.32),
                                lineWidth: selected ? 1.2 : 0.8
                            )
                        }
                }
                .frame(minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Selects this exercise")
        .accessibilityIdentifier("force-exercise-\(option)")
    }

    @ViewBuilder
    private var catalogStatus: some View {
        switch catalog.status {
        case .loading:
            WatchLoadingState(
                title: catalog.hasCachedSnapshot ? "Refreshing protocols…" : "Loading protocols…",
                message: catalog.hasCachedSnapshot ? "Saved protocols stay available." : nil
            )
        case .fresh:
            WatchStateChip(state: .ready, title: "Fresh from iPhone", compact: true)
                .accessibilityIdentifier("force-protocol-status-fresh")
        case .cached:
            WatchStateBanner(
                state: .cached,
                title: catalog.syncBannerTitle,
                message: catalog.statusText,
                actionTitle: "Retry",
                action: retry
            )
            .accessibilityIdentifier("force-protocol-status-cached")
        case .empty:
            WatchStateBanner(
                state: .warning,
                title: "No saved protocols yet",
                message: "The Suggested protocol is ready to use.",
                actionTitle: "Retry",
                action: retry
            )
            .accessibilityIdentifier("force-protocol-status-empty")
        case .failed:
            WatchStateBanner(
                state: .danger,
                title: catalog.syncBannerTitle,
                message: catalog.statusText,
                actionTitle: "Retry",
                action: retry
            )
            .accessibilityIdentifier("force-protocol-status-failed")
        }
    }

    private var emptyProtocols: some View {
        WatchCard(accent: WatchPalette.warning) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "tray")
                    .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                    .frame(width: 24, height: 24)
                Text("No protocols saved on the iPhone yet.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(WatchPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("force-protocol-empty")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(.footnote, design: .rounded).weight(.bold))
            .foregroundStyle(WatchPalette.textPrimary)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func protocolRow(_ protocolValue: WatchForceProtocol) -> some View {
        let selected = catalog.selectedId == protocolValue.id
        let accent = WatchPalette.accent(WatchDesignTokens.primary, reducedLuminance: isLuminanceReduced)
        return Button {
            catalog.select(protocolValue)
            dismiss()
        } label: {
            Text(protocolValue.name)
                .font(.system(size: 12, weight: selected ? .heavy : .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    selected ? WatchPalette.textPrimary : WatchPalette.foreground(WatchDesignTokens.primary)
                )
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background {
                    Capsule()
                        .fill(accent.opacity(selected ? 0.42 : 0.12))
                        .overlay {
                            Capsule().stroke(
                                accent.opacity(selected ? 0.9 : 0.32),
                                lineWidth: selected ? 1.2 : 0.8
                            )
                        }
                }
                .frame(minHeight: CGFloat(WatchDesignTokens.minimumHitTarget))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(protocolValue.name), \(ForceProtocolPresentation.category(for: protocolValue))"
        )
        .accessibilityValue(
            [
                selected ? "Selected" : nil,
                ForceProtocolPresentation.detail(for: protocolValue),
                ForceProtocolPresentation.watchAvailability(for: protocolValue)
            ]
            .compactMap { $0 }
            .joined(separator: ". ")
        )
        .accessibilityHint("Selects this protocol and returns to Force setup")
        .accessibilityIdentifier("force-protocol-\(protocolValue.id)")
    }

    /// The compact chip picker loses the detail rows, so the selected
    /// protocol's summary stays visible at hand's reach below the sections.
    @ViewBuilder
    private var selectedProtocolSummary: some View {
        let selected = catalog.suggested.first { $0.id == catalog.selectedId }
            ?? catalog.myProtocols.first { $0.id == catalog.selectedId }
        if let selected {
            let detail = [
                ForceProtocolPresentation.detail(for: selected),
                ForceProtocolPresentation.watchAvailability(for: selected),
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
            WatchCard {
                Text(selected.name)
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .foregroundStyle(WatchPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("force-selected-protocol-detail")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("force-selected-protocol-summary")
        }
    }

    private func retry() {
        Task { await catalog.refresh() }
    }
}

/// Wrapping row of chips for the #791 W2 compact pickers. A chip that does
/// not fit on the current line wraps onto the next instead of overflowing
/// the narrow watch width.
private struct WatchChipFlow<Content: View>: View {
    let spacing: CGFloat
    private let content: () -> Content

    init(spacing: CGFloat = 7, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        WatchFlowLayout(spacing: spacing) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal horizontal flow layout — the watch analogue of the phone's
/// private `FlowLayout` (#710) in ForceView.swift. Both are per-target;
/// sharing would require an app target the watch could import.
private struct WatchFlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = makeRows(proposal: proposal, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for (itemOffset, subviewIndex) in row.items.enumerated() {
                let size = row.sizes[itemOffset]
                subviews[subviewIndex].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func makeRows(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> [FlowRow] {
        let width = proposal.width ?? .infinity
        var rows: [FlowRow] = []
        var current = FlowRow()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if nextWidth > width, !current.items.isEmpty {
                rows.append(current)
                current = FlowRow()
            }
            current.items.append(index)
            current.sizes.append(size)
            current.width = current.items.count == 1
                ? current.sizes[0].width
                : current.width + spacing + size.width
        }
        if !current.items.isEmpty { rows.append(current) }
        for rowIndex in rows.indices {
            rows[rowIndex].height = rows[rowIndex].sizes.map(\.height).max() ?? 0
        }
        return rows
    }

    private struct FlowRow {
        var items: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}
