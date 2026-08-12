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
                ForEach(catalog.suggested) { protocolValue in
                    protocolRow(protocolValue)
                }

                sectionHeader("My protocols")
                if catalog.myProtocols.isEmpty {
                    emptyProtocols
                } else {
                    ForEach(catalog.myProtocols) { protocolValue in
                        protocolRow(protocolValue)
                    }
                }

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
            ForEach(recentTags, id: \.self) { option in
                exerciseRow(option)
            }
        }
    }

    private func exerciseRow(_ option: String) -> some View {
        let selected = option == tag
        return Button {
            tag = option
        } label: {
            WatchCard(accent: selected ? WatchPalette.primary : nil) {
                HStack(spacing: 8) {
                    Text(option)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(WatchPalette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(
                                WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary, accent: WatchDesignTokens.primary)
                            )
                    }
                }
                .frame(minHeight: 44)
            }
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
        return Button {
            catalog.select(protocolValue)
            dismiss()
        } label: {
            WatchCard(accent: selected ? WatchPalette.primary : nil) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                categoryLabel(for: protocolValue)
                                Spacer(minLength: 0)
                                if selected { selectedMark }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                categoryLabel(for: protocolValue)
                                if selected { selectedMark }
                            }
                        }

                        Text(protocolValue.name)
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                            .foregroundStyle(WatchPalette.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)

                        Text(ForceProtocolPresentation.modeDescription(for: protocolValue))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                            .lineLimit(1)

                        Text(ForceProtocolPresentation.detail(for: protocolValue))
                            .font(.caption2)
                            .foregroundStyle(WatchPalette.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)

                        if let availability = ForceProtocolPresentation.watchAvailability(for: protocolValue) {
                            Text(availability)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                                .lineLimit(2)
                                .minimumScaleFactor(0.68)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
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

    private func categoryLabel(for protocolValue: WatchForceProtocol) -> some View {
        Text(ForceProtocolPresentation.category(for: protocolValue))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
    }

    private var selectedMark: some View {
        Label("Selected", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
            .lineLimit(1)
    }

    private func retry() {
        Task { await catalog.refresh() }
    }
}
