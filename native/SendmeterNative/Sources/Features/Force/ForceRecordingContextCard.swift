import SendmeterCore
import SwiftUI

// MARK: - Recording context redesign (#903/#902, locked Variant A round 3)

/// The redesigned recording-context card — the #903 "Configure → Operate"
/// surface:
///
/// - One collapsed decision row (movement & side) opens the COMBINED
///   full-screen movement + side picker.
/// - Protocol source is one `Suggested | Saved` segmented switch; exactly one
///   list is visible at a time (Saved rows use the locked
///   `Saved · <category>` subtitle pattern).
/// - Tapping a protocol arms it immediately. The armed protocol becomes the
///   card hero: protocol name + timing + the bound target + intensity
///   load-module + pull-to-start readiness.
/// - One selection system: filled = selected, outline = available, dimmed but
///   legible = disabled; category/identity colors appear only as small dots.
/// - The load module's upper region is the numeric live readout, the lower
///   region the single interactive intensity slider (60–110%, step 5); moving
///   the slider recomputes band, hold, source note, percentage and thumb.
struct ForceRecordingContextCard: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var tag: String
    @Binding var side: TindeqSide
    /// #720: the active exercise's side-applicability policy — the picker and
    /// card only offer the sides the policy allows.
    let sideMode: ExerciseSideMode
    /// #750: explicit disabled state during any live run window.
    let locked: Bool
    /// The single-armed selection (.free / suggested / movement / saved).
    let selectedTarget: ForceProtocolSelection
    let onSelectTarget: (ForceProtocolSelection) -> Void
    /// The armed preset (zone/maintenance/movement/saved) whose timing the
    /// hero renders; nil when nothing is armed.
    let selectedPreset: TindeqPreset?
    let presets: [TindeqPreset]
    /// Pickable movement names — distinct recording tags minus hidden.
    let knownTags: [String]
    /// The maintenance zones whose guided protocol has a usable CF/PR now.
    let maintenanceAvailable: Set<RecordedZone>
    /// The tag-level curve signal used to gate the suggested zone chips
    /// (Power/Strength need maxF, Endurance needs CF, Pow End needs the hill
    /// F60) — the honest no-reference gate.
    let curveInput: ZoneCurveInput?
    /// PR fallback reference for maintenance gates (unchanged #710 rule).
    let personalRecord: Double?
    /// The RESOLVED per-side target band (the plan), when available.
    let targetBand: ForceTargetBand?
    /// The zone-quality target computed live from the tag-level references —
    /// the immediate module numbers while the per-side plan is resolving.
    let zoneTarget: ZoneQualityTarget?
    /// Non-nil only while a suggested zone protocol is armed: the SL-97
    /// intensity dial (60–110, step 5, persisted by the parent).
    let intensityPercent: Binding<Int>?
    /// Recording-device row state (design S1/S3/S5 footer).
    let deviceConnected: Bool
    let deviceStatusText: String
    /// Movement & side summary value, e.g. "FDP · Side Left".
    let movementSummary: String
    /// Opens the combined movement + side picker.
    let onOpenPicker: () -> Void

    /// Armed-state local presentation: the hero shows unless the user asked
    /// for the protocol list ("Change"); arming again returns to the hero.
    @State private var showProtocolList = false

    private var isFree: Bool { selectedTarget == .free }

    private var armedSuggestion: SuggestedProtocol? { selectedTarget.suggested }

    private var activeExercise: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var armableZoneQualities: Set<ZoneQuality> {
        var result: Set<ZoneQuality> = []
        let maxForceUsable = (curveInput?.maxForce).map { $0.isFinite && $0 > 0 } ?? false
        let cfUsable = (curveInput?.cf).map { $0.isFinite && $0 > 0 } ?? false
        if maxForceUsable {
            result.insert(.power)
            result.insert(.strength)
        }
        if cfUsable {
            result.insert(.endurance)
        }
        if curveInput?.f60Kilograms != nil {
            result.insert(.powerEndurance)
        }
        return result
    }

    private var showsArmedHero: Bool {
        !isFree && !showProtocolList
    }

    private var referenceUnusable: Bool {
        let maxForceUsable = (curveInput?.maxForce).map { $0.isFinite && $0 > 0 } ?? false
        let cfUsable = (curveInput?.cf).map { $0.isFinite && $0 > 0 } ?? false
        return !maxForceUsable && !cfUsable && curveInput?.f60Kilograms == nil
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 0) {
                recordingHead
                summaryRow
                if showsArmedHero {
                    protocolHero
                } else {
                    protocolSection
                }
                deviceRow
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Recording head

    private var recordingHead: some View {
        HStack(spacing: 8) {
            RecordingContextEyebrow(title: "Recording context", systemImage: "tag")
            Spacer(minLength: 8)
            Text(isFree ? "Nothing armed" : "Armed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecordingContextPalette.metadata(scheme))
                .accessibilityAddTraits(isFree ? [] : [.isSelected])
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(minHeight: 40)
    }

    // MARK: Movement & side decision row

    private var summaryRow: some View {
        Button(action: onOpenPicker) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Movement & side")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    Text(movementSummary)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("Change")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .hapticButtonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel("Movement and side: \(movementSummary)")
        .accessibilityHint("Opens the movement and side picker")
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
    }

    private var hairline: some View {
        Rectangle()
            .fill(RecordingContextPalette.line(scheme))
            .frame(height: 1)
    }

    // MARK: Protocol configure section (S1 / S5)

    private var protocolSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Protocol")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("Identity dot · tap to arm")
                    .font(.caption)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .frame(minHeight: 26)

            ProtocolSourceSwitch(selected: $protocolSource)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .disabled(locked)

            switch protocolSource {
            case .suggested:
                suggestedGrid
                    .padding(.horizontal, 12)
                if isFree, referenceUnusable {
                    emptyTargetNote
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 9)
                }
            case .saved:
                savedList
                    .padding(.horizontal, 12)
                Text("Your presets · selecting one arms it immediately")
                    .font(.caption)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .padding(.bottom, 10)
    }

    @State private var protocolSource: ProtocolSource = .suggested

    enum ProtocolSource: String, CaseIterable, Identifiable {
        case suggested
        case saved
        var id: String { rawValue }
        var label: String {
            switch self {
            case .suggested: return "Suggested"
            case .saved: return "Saved"
            }
        }
    }

    /// Two-column suggestion grid (design S1): dot + title + subtitle rows;
    /// the last odd row (Resisted movement) spans the full width.
    private var suggestedGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(SuggestedProtocol.allCases, id: \.identity) { suggestion in
                suggestionRow(suggestion)
                    .gridCellColumns(suggestion == .movement ? 2 : 1)
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested protocols")
    }

    private func suggestionRow(_ suggestion: SuggestedProtocol) -> some View {
        let quality = suggestion.zoneQuality
        let available = isSuggestionAvailable(suggestion)
        let isSelected = armedSuggestion == suggestion
        return Button {
            Haptics.shared.tap()
            showProtocolList = false
            onSelectTarget(suggestion.selection)
        } label: {
            HStack(spacing: 8) {
                RecordingContextPalette.identityDot(
                    for: quality,
                    selected: isSelected,
                    scheme: scheme
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(available ? .primary : RecordingContextPalette.disabledLabel(scheme))
                        .lineLimit(1)
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(
                            available
                                ? RecordingContextPalette.metadata(scheme)
                                : RecordingContextPalette.disabledLabel(scheme)
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .hapticButtonStyle(.plain)
        .disabled(!available || locked)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selectedBackground(isSelected: isSelected, available: available))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? RecordingContextPalette.primary(scheme)
                        : RecordingContextPalette.line(scheme),
                    lineWidth: 1
                )
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAddTraits(available ? [] : [.isButton])
        .accessibilityLabel(suggestion.title)
        .accessibilityValue(isSelected ? "Armed" : (available ? "Available" : "Unavailable"))
    }

    private func selectedBackground(isSelected: Bool, available: Bool) -> Color {
        if isSelected {
            return RecordingContextPalette.primary(scheme).opacity(0.16)
        }
        return available ? .clear : RecordingContextPalette.disabledBackground(scheme)
    }

    private func isSuggestionAvailable(_ suggestion: SuggestedProtocol) -> Bool {
        switch suggestion {
        case .zone(let quality):
            return armableZoneQualities.contains(quality)
        case .maintenance(let zone):
            return maintenanceAvailable.contains(zone)
        case .movement:
            return true
        }
    }

    private var emptyTargetNote: some View {
        HStack(spacing: 9) {
            Image(systemName: "scope")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RecordingContextPalette.metadata(scheme))
            VStack(alignment: .leading, spacing: 2) {
                Text("No reference curve")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Free hold records without a target band")
                    .font(.caption)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(
            RecordingContextPalette.nested(scheme),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    RecordingContextPalette.line(scheme),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .accessibilityElement(children: .combine)
    }

    /// One-column saved list (design S5): each row's subtitle uses the locked
    /// `Saved · <category>` pattern with its category identity dot.
    private var savedList: some View {
        VStack(spacing: 7) {
            ForEach(presets) { preset in
                savedRow(preset)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved protocols")
    }

    private func savedRow(_ preset: TindeqPreset) -> some View {
        let category = SavedPresetCategory(preset)
        let isSelected = selectedTarget == .savedPreset(preset.id)
        return Button {
            Haptics.shared.tap()
            showProtocolList = false
            onSelectTarget(.savedPreset(preset.id))
        } label: {
            HStack(spacing: 8) {
                RecordingContextPalette.identityDot(
                    for: category.zoneQuality,
                    selected: isSelected,
                    scheme: scheme
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Saved · \(category.label)")
                        .font(.caption)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .hapticButtonStyle(.plain)
        .disabled(locked)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    isSelected
                        ? RecordingContextPalette.primary(scheme).opacity(0.16)
                        : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? RecordingContextPalette.primary(scheme)
                        : RecordingContextPalette.line(scheme),
                    lineWidth: 1
                )
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(preset.name)
        .accessibilityValue(isSelected ? "Armed" : "Available")
    }

    // MARK: Armed protocol hero (S3 / S4)

    private var protocolHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RecordingContextEyebrow(title: "Armed protocol", systemImage: "waveform.path.ecg")
                Spacer(minLength: 8)
                // #899: every guided protocol is pull-gated, so the armed
                // hero always carries the hands-free identity.
                HStack(spacing: 6) {
                    Circle()
                        .fill(RecordingContextPalette.handsFreeGold)
                        .frame(width: 6, height: 6)
                    Text("Hands-free")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                }
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .overlay(
                    Capsule()
                        .strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
            }

            if let preset = selectedPreset {
                HStack(spacing: 10) {
                    RecordingContextPalette.identityDot(
                        for: armedIdentityQuality,
                        selected: true,
                        scheme: scheme,
                        diameter: 10
                    )
                    Text(preset.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if preset.protocolMode == .reverseAction {
                        Text("MOVEMENT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 24)
                            .overlay(
                                Capsule()
                                    .strokeBorder(RecordingContextPalette.primaryBorder(scheme), lineWidth: 1)
                            )
                            .accessibilityLabel("Movement protocol")
                    }
                    Spacer(minLength: 8)
                    Button {
                        Haptics.shared.tap()
                        showProtocolList = true
                    } label: {
                        Text("Change")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                            .padding(.horizontal, 11)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .hapticButtonStyle(.plain)
                    .disabled(locked)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RecordingContextPalette.primaryBorder(scheme), lineWidth: 1)
                    )
                    .accessibilityLabel("Change protocol")
                    .accessibilityHint("Shows the suggested and saved protocol list")
                }
                .padding(.top, 4)
                .padding(.bottom, 5)

                timingRow(preset)

                loadModule(preset)

                if preset.protocolMode == .reverseAction {
                    movementGuide
                }

                readinessRow
            }
        }
        .padding(12)
        .background(
            RecordingContextPalette.heroSurface(scheme),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    /// The identity quality the armed hero's dot carries: the suggested
    /// zone's quality, a saved preset's derived category quality, or nil for
    /// the neutral maintenance/movement dots.
    private var armedIdentityQuality: ZoneQuality? {
        switch selectedTarget {
        case .suggestedZone(let quality):
            return quality
        case .savedPreset:
            return selectedPreset.flatMap { SavedPresetCategory($0).zoneQuality }
        case .suggestedMaintenance, .movement, .free:
            return nil
        }
    }

    /// S3/S4 timing row: `5s hold · 6 reps · 150s rest · 1 set` (adjusted
    /// holds read `~7s hold` — the exact value is fractional).
    private func timingRow(_ preset: TindeqPreset) -> some View {
        let segments = armedTimingSegments(preset)
        return HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Rectangle()
                        .fill(RecordingContextPalette.line(scheme))
                        .frame(width: 1, height: 12)
                        .padding(.horizontal, 6)
                }
                Text(segment.text)
                    .font(segment.isLead ? .caption.weight(.semibold) : .caption)
                    .foregroundStyle(
                        segment.isLead ? Color.primary : RecordingContextPalette.metadata(scheme)
                    )
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 9)
        .accessibilityElement(children: .combine)
    }

    private struct TimingSegment {
        let text: String
        let isLead: Bool
    }

    private func armedTimingSegments(_ preset: TindeqPreset) -> [TimingSegment] {
        let adjustedHold = adjustedHoldDisplayText(preset)
        var segments = [TimingSegment(text: adjustedHold, isLead: true)]
        let repsWord = preset.repetitions == 1 ? "rep" : "reps"
        segments.append(TimingSegment(text: "\(preset.repetitions) \(repsWord)", isLead: false))
        if preset.protocolMode == .hold, preset.restBetweenRepetitionsSeconds > 0 {
            segments.append(
                TimingSegment(text: "\(preset.restBetweenRepetitionsSeconds)s rest", isLead: false)
            )
        }
        segments.append(
            TimingSegment(
                text: "\(preset.sets) set" + (preset.sets == 1 ? "" : "s"),
                isLead: false
            )
        )
        return segments
    }

    /// "5s hold" at 100%; "~7s hold" once the intensity moved the hold (the
    /// exact value is fractional — design S3/S4). Non-zone protocols keep
    /// their `holdScheduleSummary` untouched.
    private func adjustedHoldDisplayText(_ preset: TindeqPreset) -> String {
        if let zoneTarget, zoneTarget.isAdjusted {
            return "~\(preset.holdSeconds)s hold"
        }
        return preset.holdScheduleSummary
    }

    // MARK: Bound target + intensity load module (S3/S4)

    /// The live numbers the module renders: the resolved per-side plan band
    /// wins once available; until then the tag-level zone target supplies the
    /// same band math so the readout is never blank while resolving.
    private var displayBand: (low: Double, high: Double)? {
        if let targetBand {
            return (targetBand.lowKilograms, targetBand.highKilograms)
        }
        if let zoneTarget {
            return (zoneTarget.lowKilograms, zoneTarget.highKilograms)
        }
        return nil
    }

    private var showIntensityDial: Bool {
        if case .suggestedZone = selectedTarget {
            return true
        }
        return false
    }

    @ViewBuilder
    private func loadModule(_ preset: TindeqPreset) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                RecordingContextEyebrow(title: "Target band", systemImage: "scope")
                Spacer(minLength: 8)
                Text("Live readout")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RecordingContextPalette.nestedRaised(scheme),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 4)

            if let band = displayBand {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(RecordingContextFormat.kg(band.low))–\(RecordingContextFormat.kg(band.high))")
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .accessibilityLabel(
                            "Target band \(RecordingContextFormat.kg(band.low)) to \(RecordingContextFormat.kg(band.high)) kilograms"
                        )
                    Text("kg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)

                if let zoneTarget {
                    Text(zoneTarget.basis)
                        .font(.caption2)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                        .accessibilityLabel(zoneTarget.basis)
                }

                if zoneTarget != nil {
                    HStack(spacing: 5) {
                        Text("↳")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                        Text(moduleSourceNote)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 15)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                } else {
                    Color.clear
                        .frame(height: 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No target configured for this protocol")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if preset.zoneQuality != nil {
                        Text("No reference curve for this exercise yet")
                            .font(.caption)
                            .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    } else {
                        Text("This protocol records without a target band")
                            .font(.caption)
                            .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            if showIntensityDial, let intensityPercent {
                intensityDial(intensityPercent)
            }
        }
        .background(
            RecordingContextPalette.moduleBackground(scheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Target band and intensity bound control")
    }

    /// The design's short source note: "From maxF 22.0 kg" at 100%,
    /// "Adjusted from 5s @100%" once the intensity moved the schedule.
    private var moduleSourceNote: String {
        zoneTarget?.sourceNote ?? "From your force curve"
    }

    private func intensityDial(_ intensityPercent: Binding<Int>) -> some View {
        let intensity = Binding(
            get: { Double(intensityPercent.wrappedValue) },
            set: { intensityPercent.wrappedValue = Int($0.rounded()) }
        )
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Text("Intensity")
                        .font(.caption)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    Text("\(intensityPercent.wrappedValue)%")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 8)
                Text("60–110 · 5% steps")
                    .font(.caption2)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Slider(value: intensity, in: 60...110, step: 5)
                .tint(RecordingContextPalette.primary(scheme))
                .disabled(locked)
                .accessibilityLabel("Intensity")
                .accessibilityValue("\(intensityPercent.wrappedValue) percent")

            HStack {
                Text("60%")
                Spacer()
                Text("100%")
                Spacer()
                Text("110%")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(RecordingContextPalette.metadata(scheme))
            .padding(.horizontal, 2)
            .padding(.bottom, 7)
        }
        .background(RecordingContextPalette.nested(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Intensity \(intensityPercent.wrappedValue) percent")
    }

    // MARK: Movement setup guide (#711 copy kept with the armed state)

    private var movementGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Movement setup", systemImage: "arrow.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
            Text("Mark both movement endpoints and keep the path clear of pinch or impact hazards.")
            Text("Move smoothly through your chosen range. Jerking to chase a target can create misleading force peaks.")
            Text("Keep the movement area clear and use an appropriate tether or clear impact area for compliant or spring setups.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RecordingContextPalette.primary(scheme).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Readiness row (#899: guided + hands-free only — no tap-to-start)

    private var readinessRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.draw")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
            VStack(alignment: .leading, spacing: 2) {
                Text("Pull to start · release to stop")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                Text("Armed now · no confirmation step")
                    .font(.caption)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(
            RecordingContextPalette.primary(scheme).opacity(0.11),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: Device row (S1/S3/S5 footer)

    private var deviceRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                .frame(width: 32, height: 32)
                .background(
                    RecordingContextPalette.primary(scheme).opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recording device")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                Text("Tindeq Progressor")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Circle()
                    .fill(
                        deviceConnected
                            ? RecordingContextPalette.statusBlue
                            : RecordingContextPalette.paused(scheme)
                    )
                    .frame(width: 6, height: 6)
                Text(deviceStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording device status: \(deviceStatusText)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .overlay(alignment: .top) { hairline }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Suggested protocol presentation helpers

private extension SuggestedProtocol {
    var selection: ForceProtocolSelection {
        switch self {
        case .zone(let quality): return .suggestedZone(quality)
        case .maintenance(let zone): return .suggestedMaintenance(zone)
        case .movement: return .movement
        }
    }

    var zoneQuality: ZoneQuality? {
        if case .zone(let quality) = self { return quality }
        return nil
    }

    /// Design S1 row titles.
    var title: String {
        switch self {
        case .zone(let quality): return quality.label
        case .maintenance(let zone): return zone == .warmup ? "Warmup" : "Prehab"
        case .movement: return MovementTerminology.resistedMovement
        }
    }

    /// Design S1 row subtitles (locked copy — the underlying protocols live
    /// in `ZoneMix.zoneProtocols` / `ZoneMix.maintenancePreset`).
    var subtitle: String {
        switch self {
        case .zone(let quality):
            switch quality {
            case .power: return "5s hold · 6 reps"
            case .strength: return "10s · 5 reps"
            case .powerEndurance: return "7s · 6 reps · 4 sets"
            case .endurance: return "30s · 1 rep · 8 sets"
            }
        case .maintenance(let zone):
            return zone == .warmup ? "20/15/10/10s" : "90/60/30/30s"
        case .movement:
            return "Custom load"
        }
    }

    /// Stable grid identity (the enum is Equatable-only in Core).
    var identity: String {
        switch self {
        case .zone(let quality): return "zone-\(quality.rawValue)"
        case .maintenance(let zone): return "maintenance-\(zone.rawValue)"
        case .movement: return "movement"
        }
    }

    static var allCases: [SuggestedProtocol] {
        [
            .zone(.power),
            .zone(.strength),
            .zone(.powerEndurance),
            .zone(.endurance),
            .maintenance(.warmup),
            .maintenance(.prehab),
            .movement
        ]
    }
}

// MARK: - Saved preset category (S5 locked `Saved · <category>` pattern)

/// The category a saved preset lists under. The locked fixture pattern maps:
/// Reverse Action → `Saved · Custom`; a name-declared quality wins for the
/// user's own presets ("Grip Gain Power" → Power); a target-bearing static
/// protocol classifies by its recording zone; an untargeted static preset is
/// `Saved · Static`.
private struct SavedPresetCategory {
    let label: String
    let zoneQuality: ZoneQuality?

    init(_ preset: TindeqPreset) {
        if preset.protocolMode == .reverseAction {
            label = "Custom"
            zoneQuality = nil
            return
        }
        let name = preset.name.lowercased()
        if name.contains("power endurance") || name.contains("pow end") {
            label = "Pow End"
            zoneQuality = .powerEndurance
            return
        }
        if name.contains("endurance") {
            label = "Endurance"
            zoneQuality = .endurance
            return
        }
        if name.contains("strength") {
            label = "Strength"
            zoneQuality = .strength
            return
        }
        if name.contains("power") {
            label = "Power"
            zoneQuality = .power
            return
        }
        if name.contains("warmup") || name.contains("warm-up") {
            label = "Warmup"
            zoneQuality = nil
            return
        }
        if name.contains("prehab") {
            label = "Prehab"
            zoneQuality = nil
            return
        }
        let hasTarget = preset.targetKilograms != nil
            || preset.targetPercentage != nil
            || preset.targetFromCurve
        if hasTarget, let quality = ZoneMix.classifyZone(durationSeconds: Double(preset.holdSeconds(forSet: 1))) {
            label = quality.label
            zoneQuality = quality
            return
        }
        label = "Static"
        zoneQuality = nil
    }
}

// MARK: - Palette + small components

/// The #903 locked design tokens (dark/light adaptive) for the recording
/// context surface. Colors follow the approved README values: status blue
/// appears ONLY on the Progressor/Connected dot, Endurance identity is teal,
/// Pow End a non-blue mauve, Power/Strength keep danger/caution identity.
private enum RecordingContextPalette {
    static let statusBlue = Color(hex: "#2E96F0")
    static let enduranceTeal = Color(hex: "#3CBFA3")
    /// `color-mix(primary 68%, danger)` — the approved non-blue Pow End mauve.
    static let powEndMauve = Color(hex: "#87669A")
    static let handsFreeGold = Color(hex: "#DDB13A")

    static func primary(_ scheme: ColorScheme) -> Color {
        Color(hex: "#5B5FC7")
    }

    static func primaryMixed(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#A9ADE3") : Color(hex: "#4A4EAC")
    }

    static func primaryBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#6F74CF") : Color(hex: "#C3C5EC")
    }

    static func metadata(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#C7C7CE") : Color(hex: "#52525C")
    }

    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#35353C") : Color(hex: "#D8D8DE")
    }

    static func nested(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#242428") : Color(hex: "#F7F7FA")
    }

    static func nestedRaised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#2D2D32") : Color(hex: "#ECECF2")
    }

    static func moduleBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#1A1A1D") : Color(hex: "#FBFBFD")
    }

    static func heroSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#242428") : Color(hex: "#F7F7FA")
    }

    static func paused(_ scheme: ColorScheme) -> Color {
        Color(hex: "#565D6D")
    }

    static func disabledLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#A0A0AA") : Color(hex: "#61616B")
    }

    static func disabledBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#29292E") : Color(hex: "#E8E8ED")
    }

    /// Identity dot: danger Power, caution Strength, mauve Pow End, teal
    /// Endurance, paused neutral otherwise. Selected rows keep the identity
    /// dot (selection lives in the row fill/border, never in the dot color).
    static func identityDot(
        for quality: ZoneQuality?,
        selected: Bool,
        scheme: ColorScheme,
        diameter: CGFloat = 8
    ) -> some View {
        let color: Color
        switch quality {
        case .power: color = Color(hex: "#E5743A")
        case .strength: color = Color(hex: "#DDB13A")
        case .powerEndurance: color = powEndMauve
        case .endurance: color = enduranceTeal
        case nil: color = paused(scheme)
        }
        return Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(0.35), radius: 0, x: 0, y: 0)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 3)
                    .padding(-2.5)
            )
            .accessibilityHidden(true)
    }
}

/// Uppercase eyebrow label with a leading SF symbol (caption2 scale).
private struct RecordingContextEyebrow: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(RecordingContextPalette.metadata(scheme))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// The `Suggested | Saved` protocol source switch — exactly one list is
/// visible at a time (locked decision 3).
private struct ProtocolSourceSwitch: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var selected: ForceRecordingContextCard.ProtocolSource

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ForceRecordingContextCard.ProtocolSource.allCases) { source in
                Button {
                    Haptics.shared.tap()
                    selected = source
                } label: {
                    Text(source.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            selected == source ? Color.primary : RecordingContextPalette.metadata(scheme)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .hapticButtonStyle(.plain)
                .background(
                    selected == source
                        ? RecordingContextPalette.paused(scheme)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityAddTraits(selected == source ? [.isSelected] : [])
                .accessibilityValue(selected == source ? "Selected" : "Not selected")
            }
        }
        .padding(3)
        .frame(minHeight: 44)
        .background(
            RecordingContextPalette.nestedRaised(scheme),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protocol source")
    }
}

/// One-decimal kg formatting shared by the module readout.
private enum RecordingContextFormat {
    static func kg(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Combined movement + side picker (S2 / S6)

/// The full-screen combined picker the collapsed "Movement & side" decision
/// row opens (locked #903 decision 2 / punch 1): ALL movements in one list,
/// each with its #543 side-policy badge; the side panel sits in document flow
/// 8px below the movement list and offers only the sides the selected
/// movement's policy allows. Own 44px Close control, no app tab bar.
struct ForceMovementSidePicker: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var tag: String
    @Binding var side: TindeqSide
    let knownTags: [String]
    /// #720: the side-applicability policy per movement (single source of
    /// truth `ExerciseSidePolicy`).
    let modeProvider: (String) -> ExerciseSideMode
    let onClose: () -> Void

    @State private var addingMovement = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var movements: [String] {
        knownTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var activeExercise: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeMode: ExerciseSideMode {
        modeProvider(activeExercise)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            pickerLabelRow
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    movementRows
                    addMovementRow
                    if !activeExercise.isEmpty {
                        sidePanel
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
    }

    private var sheetHeader: some View {
        HStack(alignment: .bottom, spacing: 9) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    .frame(width: 44, height: 44)
                    .background(
                        RecordingContextPalette.nested(scheme),
                        in: Circle()
                    )
                    .overlay(
                        Circle().strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
                    )
                    .contentShape(Circle())
            }
            .hapticButtonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityHint("Closes the movement and side picker")

            VStack(alignment: .leading, spacing: 3) {
                Text("RECORDING CONTEXT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                Text("Movement & side")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            Text("Updates instantly")
                .font(.caption2)
                .foregroundStyle(RecordingContextPalette.metadata(scheme))
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 17)
        .padding(.top, 8)
        .padding(.bottom, 11)
        .frame(minHeight: 92)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RecordingContextPalette.line(scheme))
                .frame(height: 1)
        }
    }

    private var pickerLabelRow: some View {
        HStack {
            Text("MOVEMENT")
            Spacer()
            Text("SIDE POLICY")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(RecordingContextPalette.metadata(scheme))
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .frame(minHeight: 26)
    }

    private var movementRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(movements.enumerated()), id: \.element) { index, name in
                movementRow(name: name, number: index + 1)
                Rectangle()
                    .fill(RecordingContextPalette.line(scheme))
                    .frame(height: 1)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RecordingContextPalette.line(scheme))
                .frame(height: 1)
        }
        .background(
            Color.clear,
            in: RoundedRectangle(cornerRadius: 0, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Movements")
    }

    private func movementRow(name: String, number: Int) -> some View {
        let isSelected = name == activeExercise
        let mode = modeProvider(name)
        return Button {
            Haptics.shared.tap()
            if isSelected {
                tag = ""
            } else {
                tag = name
            }
            addingMovement = false
        } label: {
            HStack(spacing: 9) {
                Text(String(format: "%02d", number))
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected ? Color.primary : RecordingContextPalette.metadata(scheme)
                    )
                    .frame(width: 22, alignment: .leading)
                selectionMark(isSelected: isSelected)
                Text(name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(SidePolicyBadge.label(for: mode))
                    .font(.caption)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .hapticButtonStyle(.plain)
        .background(
            isSelected
                ? LinearGradient(
                    colors: [
                        RecordingContextPalette.primary(scheme).opacity(0.17),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                : LinearGradient(colors: [Color.clear, Color.clear], startPoint: .leading, endPoint: .trailing)
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(isSelected ? "Selected" : "Available")
    }

    private func selectionMark(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected ? RecordingContextPalette.primary(scheme) : Color.clear)
            .frame(width: 34, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? RecordingContextPalette.primary(scheme) : RecordingContextPalette.line(scheme),
                        lineWidth: 1
                    )
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white : Color.clear)
            )
            .accessibilityHidden(true)
    }

    private var addMovementRow: some View {
        VStack(spacing: 0) {
            if addingMovement {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                        .frame(width: 34, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(RecordingContextPalette.primaryBorder(scheme), lineWidth: 1)
                        )
                    TextField("New movement name", text: $draftName)
                        .font(.subheadline)
                        .focused($nameFieldFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(commitDraft)
                        .onAppear { nameFieldFocused = true }
                    Button("Add", action: commitDraft)
                        .hapticButtonStyle(.borderedProminent)
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.vertical, 6)
                .frame(minHeight: 52)
            } else {
                Button {
                    Haptics.shared.tap()
                    addingMovement = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                            .frame(width: 34, height: 32)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
                            )
                        Text("Add movement")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .hapticButtonStyle(.plain)
                .accessibilityLabel("Add movement")
                .accessibilityHint("Names a new movement to record against")
            }
            Rectangle()
                .fill(RecordingContextPalette.line(scheme))
                .frame(height: 1)
        }
        .padding(.bottom, 8)
    }

    private func commitDraft() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tag = trimmed
        }
        draftName = ""
        addingMovement = false
        nameFieldFocused = false
    }

    /// The side panel — in document flow 8px below the movement list
    /// (locked punch 1). Only the sides the active exercise's policy allows
    /// are enabled; disabled choices stay legible but are never tappable.
    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SIDE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    Text(SidePolicyBadge.sentence(for: activeMode, movement: activeExercise))
                        .font(.caption)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                }
                Spacer(minLength: 8)
                if SidePolicyBadge.showsFilteredBadge(activeMode) {
                    Text("Filtered")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RecordingContextPalette.nestedRaised(scheme),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 8)

            HStack(spacing: 7) {
                ForEach([TindeqSide.left, .right, .both]) { option in
                    sideOption(option)
                }
            }
        }
        .padding(11)
        .background(
            RecordingContextPalette.nested(scheme),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side options for \(activeExercise)")
    }

    private func sideOption(_ option: TindeqSide) -> some View {
        let allowed = ExerciseSidePolicy.isSideAllowed(activeMode, option)
        let selected = side == option
        return Button {
            Haptics.shared.tap()
            guard allowed else { return }
            side = option
        } label: {
            Text(option.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    selected
                        ? Color.white
                        : (allowed ? Color.primary : RecordingContextPalette.disabledLabel(scheme))
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .hapticButtonStyle(.plain)
        .disabled(!allowed)
        .background(
            selected
                ? RecordingContextPalette.primary(scheme)
                : (allowed ? Color.clear : RecordingContextPalette.disabledBackground(scheme)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    selected || allowed ? RecordingContextPalette.line(scheme) : RecordingContextPalette.line(scheme),
                    lineWidth: 1
                )
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue(selected ? "Selected" : (allowed ? "Available" : "Not available for this movement"))
    }
}

/// The picker's side-policy presentation (#543) — badges, panel sentences,
/// and the Filtered marker. Copy for the one-side / both-only policies is
/// the locked design wording (S2 "FDP supports one side at a time", S6
/// "Edge Block records both sides together").
private enum SidePolicyBadge {
    static func label(for mode: ExerciseSideMode) -> String {
        switch mode {
        case .unilateralOrBilateral: return "Either"
        case .unilateralOnly: return "One side"
        case .bilateralOnly: return "Both only"
        case .notApplicable: return "Not applicable"
        }
    }

    static func sentence(for mode: ExerciseSideMode, movement: String) -> String {
        switch mode {
        case .unilateralOrBilateral: return "\(movement) works on one side or both"
        case .unilateralOnly: return "\(movement) supports one side at a time"
        case .bilateralOnly: return "\(movement) records both sides together"
        case .notApplicable: return "\(movement) has no side to record"
        }
    }

    static func showsFilteredBadge(_ mode: ExerciseSideMode) -> Bool {
        mode != .unilateralOrBilateral
    }
}
