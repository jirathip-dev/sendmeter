import SendmeterCore
import SwiftUI

/// #1028 D + F: the Force tab's sticky bottom bar (always visible above the
/// tab bar). The ONLY place for device status and Connect/Reconnect (F1);
/// carries the Guided | Free hold switch (F2); the big action follows the
/// mode (`ForceBarPolicy`). Tapping the armed protocol opens the list (D2).
///
/// #1038 I1: the bar also owns the GAUGE SESSION — its recording count and a
/// full-size Finish action, on their own strip above the status line.
struct ForceBottomBar: View {
    let state: ForceBarState
    @Binding var mode: ForceBarMode
    /// Live hold time + current kg while recording (F4 label: "Hold 30.3 s").
    let liveLine: String?
    let onSubject: () -> Void
    let onAction: () -> Void
    /// #1038 I1/I2: end the gauge session and disconnect the Progressor.
    let onFinishSession: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if let session = state.session {
                sessionStrip(session)
            }
            HStack(spacing: 8) {
                statusDot
                Text(state.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SendmeterStyle.textPrimary)
                    // #1028: wrap rather than truncate on an SE
                    // ("Armed · pull to s…" next to a locked switch).
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(0)
                    .accessibilityIdentifier("force-bar-status")
                Spacer(minLength: 6)
                modeSwitch
                    .fixedSize()
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .contain)

            HStack(spacing: 12) {
                subject
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .background(
            SendmeterStyle.surface,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SendmeterStyle.line, lineWidth: 1)
        )
        .shadow(color: .primary.opacity(0.10), radius: 14, x: 0, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("force-bottom-bar")
    }

    // MARK: Gauge session strip (#1038 I1)

    /// The session line: what the session holds on the left, and Finish —
    /// a real, full-size control, never a caption. Blocked (mid-pull, a
    /// guided run, a held pull) it stays visible but disabled, with the
    /// reason as its hint: it must never drop a recording (I3).
    private func sessionStrip(_ session: ForceBarSession) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text(session.countLabel)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(SendmeterStyle.textSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("force-bar-session-count")

            Spacer(minLength: 4)

            Button(action: onFinishSession) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("Finish")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(session.canFinish ? SendmeterStyle.textPrimary : SendmeterStyle.textTertiary)
                .padding(.horizontal, 12)
                .frame(minWidth: 96, minHeight: 44)
                .background(
                    SendmeterStyle.surfaceNested,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(SendmeterStyle.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .hapticButtonStyle(.plain)
            .disabled(!session.canFinish)
            .accessibilityIdentifier("force-bar-finish")
            .accessibilityLabel("Finish session")
            .accessibilityHint(
                session.finishBlockedReason
                    ?? "Saves the session to History and disconnects the Progressor"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            SendmeterStyle.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("force-bar-session")
    }

    // MARK: Status

    private var toneColor: Color {
        switch state.tone {
        case .offline: return SendmeterStyle.paused
        case .working: return SendmeterStyle.caution
        case .ready: return SendmeterStyle.optimal
        case .armed: return SendmeterStyle.caution
        case .live: return SendmeterStyle.alert
        case .attention: return SendmeterStyle.alert
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(toneColor)
            .frame(width: 9, height: 9)
            .overlay(
                Circle()
                    .stroke(toneColor.opacity(0.28), lineWidth: 4)
                    .padding(-3)
            )
            .accessibilityHidden(true)
    }

    // MARK: Mode switch (F2)

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            // Locked, only the chosen mode shows (the other cannot be picked
            // mid-pull anyway); the freed width keeps the status on one line
            // on an SE.
            ForEach(state.modeLocked ? [mode] : ForceBarMode.allCases, id: \.self) { option in
                let selected = option == mode
                Button {
                    guard !selected else { return }
                    Haptics.shared.tap()
                    mode = option
                } label: {
                    HStack(spacing: 4) {
                        if selected && state.modeLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        Text(option.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(segmentText(selected: selected))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(segmentFill(selected: selected), in: Capsule())
                    .overlay {
                        if selected && state.modeLocked {
                            Capsule().strokeBorder(SendmeterStyle.line, lineWidth: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                // Not `.plain`: a disabled plain button dims its whole label
                // (fill included) to ~50 %, which measured 3.46:1 on the SE
                // capture and erased the chip. This style never dims.
                .buttonStyle(ModeSegmentButtonStyle())
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("force-mode-\(option.rawValue)")
            }
        }
        // Locked, the chip IS the control: no selector track around a single
        // option (a track + chip read as an awkward double border).
        .padding(state.modeLocked ? 0 : 3)
        .background(state.modeLocked ? Color.clear : SendmeterStyle.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(state.modeLocked ? Color.clear : SendmeterStyle.line, lineWidth: 1))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .disabled(state.modeLocked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.modeLocked ? "Recording mode, locked during this pull" : "Recording mode")
    }

    // #1028 (P8): a locked switch keeps the chosen mode READABLE. Fading the
    // whole control (opacity 0.55) left white-on-tinted-primary at ~1:1.
    // Locked, the switch collapses to the chosen mode as an outlined neutral
    // chip with a lock glyph (textPrimary on surfaceNested, AA in both
    // themes — tokens.md).
    private func segmentText(selected: Bool) -> Color {
        switch (selected, state.modeLocked) {
        case (true, false): return SendmeterStyle.onPrimary
        case (true, true): return SendmeterStyle.textPrimary
        case (false, false): return SendmeterStyle.textSecondary
        case (false, true): return SendmeterStyle.textTertiary
        }
    }

    private func segmentFill(selected: Bool) -> Color {
        guard selected else { return .clear }
        return state.modeLocked ? SendmeterStyle.surfaceNested : SendmeterStyle.primary
    }

    // MARK: Subject (armed protocol / free pull / live line)

    @ViewBuilder
    private var subject: some View {
        if let liveLine {
            Text(liveLine)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(SendmeterStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier("force-bar-live")
        } else if state.subjectOpensProtocolList {
            Button(action: onSubject) {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Protocol")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(SendmeterStyle.textSecondary)
                        Text(state.subject)
                            .font(.headline)
                            .foregroundStyle(SendmeterStyle.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SendmeterStyle.primaryText)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Protocol, \(state.subject)")
            .accessibilityHint("Opens the protocol list")
            .accessibilityIdentifier("force-bar-protocol")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.subjectCaption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SendmeterStyle.textSecondary)
                Text(state.subject)
                    .font(.headline)
                    .foregroundStyle(SendmeterStyle.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Big action

    private var actionButton: some View {
        Button(action: onAction) {
            Label(state.actionTitle, systemImage: state.actionSystemImage)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(state.actionIsPrimary ? SendmeterStyle.onPrimary : SendmeterStyle.primaryText)
                .padding(.horizontal, 18)
                .frame(minWidth: 132, minHeight: 50)
                .background(
                    state.actionIsPrimary ? SendmeterStyle.primary : SendmeterStyle.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            state.actionIsPrimary ? Color.clear : SendmeterStyle.primarySoft,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .hapticButtonStyle(.plain)
        .disabled(!state.actionEnabled)
        .opacity(state.actionEnabled ? 1 : 0.5)
        .accessibilityIdentifier("force-bar-action")
    }
}

/// #1028: the mode-switch segments draw their own selected/locked states, so
/// the style must not add the system's disabled dimming on top.
private struct ModeSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
