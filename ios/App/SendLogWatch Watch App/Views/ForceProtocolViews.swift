import Foundation
import SendLogWatchCore
import SwiftUI

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

/// The selected protocol is intentionally one card: it is the visual bridge
/// between exercise/side setup and the primary Start action. Tapping anywhere
/// on it opens the read-only chooser; there are no watch-side edit controls.
/// Uses the shared semantic `primary` accent throughout (SL-538) — no
/// protocol or zone carries its own hue here, so there is no data semantic to
/// preserve; this card is chrome for "the protocol Start will run."
struct ForceSelectedProtocolCard: View {
    let protocolValue: WatchForceProtocol
    let catalog: ForceProtocolCatalog
    let compact: Bool

    init(
        protocolValue: WatchForceProtocol,
        catalog: ForceProtocolCatalog,
        compact: Bool = false
    ) {
        self.protocolValue = protocolValue
        self.catalog = catalog
        self.compact = compact
    }

    private var isSuggested: Bool {
        catalog.suggested.contains(where: { $0.id == protocolValue.id })
    }

    var body: some View {
        NavigationLink {
            ForceProtocolChooserView(catalog: catalog)
        } label: {
            WatchCard(accent: WatchPalette.primary) {
                if compact {
                    compactCardContent
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            WatchEyebrow(text: "Selected protocol")
                            Spacer(minLength: 4)
                            protocolKindPill
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            WatchEyebrow(text: "Selected protocol")
                            protocolKindPill
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: protocolValue.mode == .hold
                            ? "hand.raised.fill"
                            : "figure.strengthtraining.traditional")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                            .frame(width: 24, height: 24)

                        Text(protocolValue.name)
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(WatchPalette.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)

                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WatchPalette.textSecondary)
                            .accessibilityHidden(true)
                    }

                    Text(ForceProtocolPresentation.modeDescription(for: protocolValue))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(ForceProtocolPresentation.detail(for: protocolValue))
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(WatchPalette.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    if let availability = ForceProtocolPresentation.watchAvailability(for: protocolValue) {
                        Text(availability)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            sourcePill
                            Spacer(minLength: 0)
                            Text("Change")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            sourcePill
                            Text("Change protocol")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                        }
                    }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Selected protocol, \(protocolValue.name), "
                + "\(ForceProtocolPresentation.category(for: protocolValue))"
        )
        .accessibilityValue(
            [
                ForceProtocolPresentation.detail(for: protocolValue),
                ForceProtocolPresentation.watchAvailability(for: protocolValue)
            ]
            .compactMap { $0 }
            .joined(separator: ". ")
        )
        .accessibilityHint("Opens the read-only protocol chooser")
        .accessibilityIdentifier("force-selected-protocol")
    }

    private var compactCardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    protocolKindPill
                    Text(protocolValue.name)
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(WatchPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 2)
                    sourcePill
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        protocolKindPill
                        Text(protocolValue.name)
                            .font(.system(.footnote, design: .rounded).weight(.bold))
                            .foregroundStyle(WatchPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    sourcePill
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    compactDetailText
                    Spacer(minLength: 2)
                    changeText
                }
                VStack(alignment: .leading, spacing: 2) {
                    compactDetailText
                    Text("Change protocol")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
                }
            }

            if let availability = ForceProtocolPresentation.watchAvailability(for: protocolValue) {
                Text(availability)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchPalette.foreground(WatchDesignTokens.warning))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
    }

    private var compactDetailText: some View {
        Text(ForceProtocolPresentation.compactDetail(for: protocolValue))
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.62)
    }

    private var changeText: some View {
        Text("Change")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
    }

    private var protocolKindPill: some View {
        Text(ForceProtocolPresentation.category(for: protocolValue))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(WatchPalette.foregroundOnAccentCard(WatchDesignTokens.primary))
            .padding(.horizontal, 7)
            .frame(minHeight: 24)
            .background(Capsule().fill(WatchPalette.primary.opacity(0.16)))
            .overlay(Capsule().stroke(WatchPalette.primary.opacity(0.45), lineWidth: 0.8))
            .accessibilityHidden(true)
    }

    private var sourcePill: some View {
        Label(
            isSuggested ? "Suggested" : "My protocol",
            systemImage: isSuggested ? "sparkles" : "person.crop.circle"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(WatchPalette.textSecondary)
        .lineLimit(1)
    }
}

/// Full-height read-only protocol chooser. Suggested content is always
/// available, even while the user's catalog is loading or unavailable, so the
/// safe Movement Starter default never disappears during a token relay.
struct ForceProtocolChooserView: View {
    @Bindable private var catalog: ForceProtocolCatalog
    @Environment(\.dismiss) private var dismiss

    init(catalog: ForceProtocolCatalog) {
        _catalog = Bindable(wrappedValue: catalog)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
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

                Text("Protocols are managed on your iPhone.")
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
        .navigationTitle("Choose protocol")
        .navigationBarTitleDisplayMode(.inline)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(WatchPalette.canvas)
        .watchCanvas()
        .accessibilityIdentifier("force-protocol-chooser")
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
