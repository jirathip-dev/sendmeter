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
    /// #1028 F3: what the card may claim about the link and the mode. The
    /// "Recording device" row is gone (F1: the bottom bar is the only device
    /// status surface).
    let readiness: ForceContextReadiness
    /// Armed-state presentation: the hero shows unless the user asked for the
    /// protocol list ("Change", or the bar's protocol name — #1028 D2);
    /// arming again returns to the hero. Owned by the parent so the bar can
    /// open it.
    @Binding var showProtocolList: Bool
    /// Movement & side summary value, e.g. "FDP · Left".
    let movementSummary: String
    /// Opens the combined movement + side picker.
    let onOpenPicker: () -> Void

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
                if locked && !showsArmedHero {
                    // #1028: while a pull owns the device nothing on this
                    // card can change — a dimmed head, picker row and
                    // seven-tile grid only pushed the live trace below the
                    // bar. Collapse to ONE locked line; the full card
                    // returns when the pull settles.
                    lockedFreePullRow
                } else {
                    recordingHead
                    summaryRow
                    if showsArmedHero {
                        protocolHero
                    } else {
                        protocolSection
                    }
                }
            }
            .padding(.bottom, showsArmedHero || locked ? 0 : 6)
        }
        // #1028 A1: chalk on the hero only while a protocol is armed.
        .overlay { if showsArmedHero { ChalkTexture().clipShape(RoundedRectangle(cornerRadius: SendmeterStyle.radius, style: .continuous)) } }
        .accessibilityElement(children: .contain)
    }

    // MARK: Recording head

    private var recordingHead: some View {
        HStack(spacing: 8) {
            RecordingContextEyebrow(title: "Recording context", systemImage: "tag")
            Spacer(minLength: 8)
            // #1028 F2: in Hands-free the free pull IS the plan — "Nothing
            // armed" next to the bar's "Armed · pull to start" contradicted it.
            // F3: without a link the protocol is only selected, not armed.
            Text(headerWord)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecordingContextPalette.metadata(scheme))
                .accessibilityAddTraits(isFree ? [] : [.isSelected])
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(minHeight: 40)
    }

    /// #1038 H: the card's ONE status word. In Free hold the free pull IS
    /// the plan (G2 names it "Free hold"); in Guided it is the protocol's
    /// state — "Armed" with a link (G3), "Selected" without one.
    private var headerWord: String {
        if isFree { return readiness.isFreeHold ? "Free hold" : "Nothing armed" }
        return readiness.claim == .waitingForProgressor ? "Selected" : "Armed"
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
                changeLabel
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

    private var lockedFreePullRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecordingContextPalette.metadata(scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(movementSummary) · \(isFree ? "Free hold" : (selectedPreset?.name ?? "Free hold"))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // #899: armed, the next physical action stays on the card;
                // mid-pull, say why nothing here can change.
                Text(readiness.claim == .handsFreeArmed
                    ? "Pull to start · release to stop"
                    : "Locked until this pull is saved")
                    .font(.caption)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("force-context-locked-free-pull")
    }

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
        // `gridCellColumns` is a Grid modifier — LazyVGrid ignores it, so the
        // full-width last row is laid out after the grid (it truncated to
        // "Resisted mov…" in one column).
        return VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(SuggestedProtocol.allCases.filter { $0 != .movement }, id: \.identity) { suggestion in
                    suggestionRow(suggestion)
                }
            }
            if SuggestedProtocol.allCases.contains(.movement) {
                suggestionRow(.movement)
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

    /// #1038 H (density): the armed hero is ONE flat block inside the card —
    /// no card-in-card-in-card. Rows are separated by hairlines: identity
    /// (dot + name + Change), the timing line, the target (band + one basis
    /// line), and the intensity dial when a suggested zone is armed. The
    /// mode chip is gone (the bar's switch already names the mode) and the
    /// connected readiness row is gone (the bar's status says "Armed · tap
    /// Start"); without a link the row stays, because it explains why the
    /// header says "Selected" instead of "Armed".
    private var protocolHero: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        .minimumScaleFactor(0.85)
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
                    // #1038 H: ONE "Change" idiom on the card — the same
                    // text + chevron as the movement row above.
                    Button {
                        Haptics.shared.tap()
                        showProtocolList = true
                    } label: {
                        changeLabel
                    }
                    .hapticButtonStyle(.plain)
                    .disabled(locked)
                    .accessibilityLabel("Change protocol")
                    .accessibilityHint("Shows the suggested and saved protocol list")
                }
                .frame(minHeight: 44)

                timingRow(preset)

                loadModule(preset)

                if preset.protocolMode == .reverseAction {
                    movementGuide
                        .padding(.top, 10)
                }

                if readiness.claim == .waitingForProgressor {
                    readinessRow
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Armed protocol")
    }

    private var changeLabel: some View {
        HStack(spacing: 4) {
            Text("Change")
                .font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
        // #1038 H (stats row): kept — it is the protocol's dose, and the name
        // alone ("Max Hangs 10 s") does not carry reps/sets. One quiet line
        // with middle dots instead of boxed separators.
        return Text(segments.map(\.text).joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(RecordingContextPalette.metadata(scheme))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
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

    /// #1038 H (density): the target is one row — label, band — plus ONE
    /// basis line. The old third line ("From CF 10.1 kg") repeated the CF the
    /// basis already names; it only returns when the intensity moved the
    /// schedule ("Adjusted from 30s @100%"), where it is new information.
    /// No "Live readout" chip: with G1 the tab shows no live force.
    @ViewBuilder
    private func loadModule(_ preset: TindeqPreset) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hairline
            if let band = displayBand {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Target")
                        .font(.subheadline)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    Spacer(minLength: 8)
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
                .padding(.top, 10)

                if let zoneTarget {
                    Text(zoneTarget.isAdjusted ? "\(zoneTarget.basis) · \(moduleSourceNote)" : zoneTarget.basis)
                        .font(.caption)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .padding(.top, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No target configured for this protocol")
                        .font(.subheadline)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    if preset.zoneQuality != nil {
                        Text("No reference curve for this exercise yet")
                            .font(.caption)
                            .foregroundStyle(RecordingContextPalette.metadata(scheme))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            }

            if showIntensityDial, let intensityPercent {
                intensityDial(intensityPercent)
                    .padding(.top, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Target band and intensity bound control")
    }

    /// The design's short source note: "From maxF 22.0 kg" at 100%,
    /// "Adjusted from 5s @100%" once the intensity moved the schedule.
    private var moduleSourceNote: String {
        zoneTarget?.sourceNote ?? "From your force curve"
    }

    private func intensityDial(_ intensityPercent: Binding<Int>) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Intensity")
                    .font(.subheadline)
                    .foregroundStyle(RecordingContextPalette.metadata(scheme))
                Spacer(minLength: 8)
                Text("\(intensityPercent.wrappedValue)%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            IntensityTrack(
                value: intensityPercent.wrappedValue,
                locked: locked,
                tint: RecordingContextPalette.primary(scheme),
                rail: RecordingContextPalette.line(scheme),
                tickColor: RecordingContextPalette.metadata(scheme),
                onChange: { intensityPercent.wrappedValue = $0 }
            )
        }
        .accessibilityElement(children: .contain)
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

    // MARK: Readiness row (#899 pull-gated; #1028 F3 honest link state)

    /// #1028 F3: with no live link the row says "Waiting for Progressor" —
    /// never "Armed now". Connect/Reconnect itself lives only in the bar (F1).
    private var readinessRow: some View {
        let waiting = readiness.claim == .waitingForProgressor
        let tint = waiting ? RecordingContextPalette.metadata(scheme) : RecordingContextPalette.primaryMixed(scheme)
        return VStack(alignment: .leading, spacing: 0) {
            hairline
            HStack(spacing: 9) {
                Image(systemName: readiness.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(readiness.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(waiting ? Color.primary : tint)
                    Text(readiness.detail)
                        .font(.caption)
                        .foregroundStyle(RecordingContextPalette.metadata(scheme))
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .padding(.top, 8)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("force-context-readiness")
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
    // #1028 B1: every value resolves from the shared `SendmeterPalette`
    // (phone = Watch). The `scheme` parameters stay so call sites are
    // unchanged; the palette colours are trait-dynamic themselves.
    static let statusBlue = SendmeterStyle.optimal
    static let enduranceTeal = SendmeterStyle.zoneEndurance
    /// `color-mix(primary 68%, danger)` — the approved non-blue Pow End mauve.
    static let powEndMauve = SendmeterStyle.zonePowerEndurance
    static let handsFreeGold = SendmeterStyle.caution

    static func primary(_ scheme: ColorScheme) -> Color { SendmeterStyle.primary }
    static func primaryMixed(_ scheme: ColorScheme) -> Color { SendmeterStyle.primaryText }
    static func primaryBorder(_ scheme: ColorScheme) -> Color { SendmeterStyle.primarySoft }
    static func metadata(_ scheme: ColorScheme) -> Color { SendmeterStyle.textSecondary }
    static func line(_ scheme: ColorScheme) -> Color { SendmeterStyle.line }
    static func nested(_ scheme: ColorScheme) -> Color { SendmeterStyle.surfaceRaised }
    static func nestedRaised(_ scheme: ColorScheme) -> Color { SendmeterStyle.surfaceNested }
    static func moduleBackground(_ scheme: ColorScheme) -> Color { SendmeterStyle.surface }
    static func heroSurface(_ scheme: ColorScheme) -> Color { SendmeterStyle.surfaceRaised }
    static func paused(_ scheme: ColorScheme) -> Color { SendmeterStyle.paused }
    static func disabledLabel(_ scheme: ColorScheme) -> Color { SendmeterStyle.textDisabled }
    static func disabledBackground(_ scheme: ColorScheme) -> Color { SendmeterStyle.surfaceDisabled }

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
        case .power: color = SendmeterStyle.power
        case .strength: color = SendmeterStyle.strength
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

// MARK: - Movement & side picker (#1038 G5 + amendment H)

/// #1038 G5: the movement & side picker is a regular bottom sheet. A tap
/// APPLIES and CLOSES — there is no X and no "Updates instantly" label. The
/// grabber is the cancel affordance: swiping down dismisses with no change,
/// because every tap edits a local draft and only `onCommit` reaches the
/// recording context.
///
/// Layout (H proposals): the side control sits FIRST, directly under the
/// title, so the 1–2 tap flow stays in one thumb zone; then recently used
/// movements, then the rest. Each row is the movement name + a small area
/// hint + a single-selection mark — no row numbers, no checkboxes, no
/// column headers. A side-policy badge appears only where a movement
/// DIFFERS from the default "either side or both" (H2).
struct ForceMovementSidePicker: View {
    @Environment(\.colorScheme) private var scheme
    /// The context the sheet opened on — the draft starts here.
    let initialMovement: String
    let initialSide: TindeqSide
    let knownTags: [String]
    /// Recently used movements first (computed by
    /// `MovementSidePickerPolicy.recentFirst` from the saved pulls).
    let recentMovements: [String]
    /// #720: the side-applicability policy per movement (single source of
    /// truth `ExerciseSidePolicy`).
    let modeProvider: (String) -> ExerciseSideMode
    /// The last side recorded per movement (G5 default).
    let lastSideProvider: (String) -> TindeqSide?
    /// Applies the completed pair and closes the sheet.
    let onCommit: (MovementSideDraft) -> Void

    @State private var draft: MovementSideDraft
    /// A side tapped before any movement in this sheet (side-first flow).
    @State private var sidePickedFirst = false
    @State private var addingMovement = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
    /// The sheet sizes to its content (no dead half-sheet under a short
    /// list); a long list still opens to `.large` and scrolls.
    @State private var contentHeight: CGFloat = 560

    init(
        initialMovement: String,
        initialSide: TindeqSide,
        knownTags: [String],
        recentMovements: [String],
        modeProvider: @escaping (String) -> ExerciseSideMode,
        lastSideProvider: @escaping (String) -> TindeqSide?,
        onCommit: @escaping (MovementSideDraft) -> Void
    ) {
        self.initialMovement = initialMovement
        self.initialSide = initialSide
        self.knownTags = knownTags
        self.recentMovements = recentMovements
        self.modeProvider = modeProvider
        self.lastSideProvider = lastSideProvider
        self.onCommit = onCommit
        var start = MovementSideDraft(
            movement: initialMovement.trimmingCharacters(in: .whitespacesAndNewlines),
            side: initialSide
        )
        #if DEBUG
        // #1038 design harness only: open on a movement that is still
        // waiting for its side (the G5 "closes once both are set" state).
        if let pending = DesignFixture1038.pickerPendingMovement {
            start = MovementSideDraft(movement: pending, side: .unspecified)
        }
        #endif
        _draft = State(initialValue: start)
    }

    private var movements: [String] {
        knownTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var recent: [String] {
        recentMovements.filter { movements.contains($0) }
    }

    private var others: [String] {
        movements.filter { !recent.contains($0) }
    }

    private var draftMode: ExerciseSideMode {
        modeProvider(draft.movement)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    sideControl
                        .padding(.bottom, 18)
                    if !recent.isEmpty {
                        groupLabel("Recent")
                        movementGroup(recent)
                            .padding(.bottom, 16)
                    }
                    if !others.isEmpty {
                        // Recent rows are not repeated below, so the second
                        // group is "Other", never a mislabelled "All".
                        groupLabel(recent.isEmpty ? "Movements" : "Other movements")
                        movementGroup(others)
                    }
                    addMovementRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    contentHeight = height
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        // An oversized height detent is clamped by the system to its own
        // maximum, so a long list opens as tall as allowed and scrolls; a
        // short one hugs its rows. (A fixed 720 cap left "Add movement"
        // jammed against the sheet edge on a 17 Pro.)
        .presentationDetents([.height(contentHeight + Self.headerHeight), .large])
    }

    /// Grabber + title + instruction line + the home-indicator inset, for
    /// the content-sized detent.
    private static let headerHeight: CGFloat = 140

    /// G5: a movement is picked and only the side is owed — the sheet stays
    /// open and the caption under the pills asks for it (ink, semibold).
    /// The pills stay neutral: ringing both read as "both selected".
    private var awaitingSide: Bool {
        !draft.movement.isEmpty
            && draft.side == .unspecified
            && MovementSidePickerPolicy.needsSideChoice(draftMode)
    }

    /// Title + the one-line instruction that replaces both the X and the
    /// "Updates instantly" label: what a tap does, and how to back out.
    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Movement & side")
                .font(.title3.bold())
                .foregroundStyle(.primary)
            Text("Tap to apply · swipe down to keep \(currentSummary)")
                .font(.footnote)
                .foregroundStyle(RecordingContextPalette.metadata(scheme))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    /// What swiping down keeps — the context the sheet opened on.
    private var currentSummary: String {
        let movement = initialMovement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !movement.isEmpty else { return "no movement" }
        let mode = modeProvider(movement)
        guard MovementSidePickerPolicy.needsSideChoice(mode), initialSide != .unspecified else {
            return movement
        }
        return "\(movement) · \(initialSide.label)"
    }

    // MARK: Side control (first — H proposal)

    private var sideControl: some View {
        let mode = draft.movement.isEmpty ? ExerciseSideMode.unilateralOrBilateral : draftMode
        let choosable = MovementSidePickerPolicy.needsSideChoice(mode)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach([TindeqSide.left, .right, .both]) { option in
                    sideChip(option, mode: mode, choosable: choosable)
                }
            }
            Text(sideCaption(mode: mode))
                .font(awaitingSide ? .caption.weight(.semibold) : .caption)
                // Ink, not the accent: accent text in this sheet means "tap"
                // (Add movement); the prompt is an instruction.
                .foregroundStyle(
                    awaitingSide
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(RecordingContextPalette.metadata(scheme))
                )
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side")
    }

    private func sideCaption(mode: ExerciseSideMode) -> String {
        if draft.movement.isEmpty { return "Pick a movement — the side applies with it" }
        if awaitingSide {
            return mode == .unilateralOnly
                ? "Pick a side for \(draft.movement) — it records one side at a time"
                : "Pick a side for \(draft.movement)"
        }
        switch mode {
        case .unilateralOrBilateral, .unilateralOnly:
            if let last = lastSideProvider(draft.movement),
               ExerciseSidePolicy.isSideAllowed(mode, last), last != .unspecified {
                return "Last time on \(draft.movement): \(last.label)"
            }
            return mode == .unilateralOnly
                ? "\(draft.movement) records one side at a time"
                : "Pick the side for \(draft.movement)"
        case .bilateralOnly:
            return "\(draft.movement) records both sides together"
        case .notApplicable:
            return "\(draft.movement) has no side to record"
        }
    }

    private func sideChip(_ option: TindeqSide, mode: ExerciseSideMode, choosable: Bool) -> some View {
        let allowed = ExerciseSidePolicy.isSideAllowed(mode, option) && (choosable || draft.movement.isEmpty)
        let selected = draft.side == option && (choosable || mode == .bilateralOnly)
        return Button {
            guard allowed else { return }
            Haptics.shared.tap()
            apply(MovementSidePickerPolicy.tapSide(option, draft: draft, mode: mode))
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
                .contentShape(Capsule())
        }
        .hapticButtonStyle(.plain)
        .disabled(!allowed)
        .background(
            selected
                ? RecordingContextPalette.primary(scheme)
                : (allowed ? RecordingContextPalette.nested(scheme) : Color.clear),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                selected ? RecordingContextPalette.primary(scheme) : RecordingContextPalette.line(scheme),
                lineWidth: 1
            )
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue(selected ? "Selected" : (allowed ? "Available" : "Not available for this movement"))
    }

    // MARK: Movement list

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(RecordingContextPalette.metadata(scheme))
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func movementGroup(_ names: [String]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.element) { index, name in
                if index > 0 {
                    Rectangle()
                        .fill(RecordingContextPalette.line(scheme))
                        .frame(height: 1)
                        .padding(.leading, 14)
                }
                movementRow(name)
            }
        }
        .background(
            RecordingContextPalette.nested(scheme),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RecordingContextPalette.line(scheme), lineWidth: 1)
        )
    }

    private func movementRow(_ name: String) -> some View {
        let isSelected = name == draft.movement
        let mode = modeProvider(name)
        let hint = MovementAreaHint.hint(for: name)
        let badge = MovementSideBadge.badge(for: mode)
        return Button {
            Haptics.shared.tap()
            addingMovement = false
            apply(
                MovementSidePickerPolicy.tapMovement(
                    name,
                    mode: mode,
                    lastSide: lastSideProvider(name),
                    pendingSide: sidePickedFirst ? draft.side : nil
                )
            )
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if hint != nil || badge != nil {
                        Text([hint, badge].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(RecordingContextPalette.metadata(scheme))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? RecordingContextPalette.primaryMixed(scheme) : Color.clear)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .hapticButtonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(isSelected ? "Selected" : "Available")
    }

    private var addMovementRow: some View {
        Group {
            if addingMovement {
                HStack(spacing: 9) {
                    TextField("New movement name", text: $draftName)
                        .font(.body)
                        .focused($nameFieldFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(commitNewMovement)
                        .onAppear { nameFieldFocused = true }
                    Button("Add", action: commitNewMovement)
                        .hapticButtonStyle(.borderedProminent)
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
            } else {
                Button {
                    Haptics.shared.tap()
                    addingMovement = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Add movement")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(RecordingContextPalette.primaryMixed(scheme))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .hapticButtonStyle(.plain)
                .accessibilityLabel("Add movement")
                .accessibilityHint("Names a new movement to record against")
            }
        }
        .padding(.top, 6)
    }

    private func commitNewMovement() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftName = ""
        addingMovement = false
        nameFieldFocused = false
        guard !trimmed.isEmpty else { return }
        apply(
            MovementSidePickerPolicy.tapMovement(
                trimmed,
                mode: modeProvider(trimmed),
                lastSide: lastSideProvider(trimmed),
                pendingSide: sidePickedFirst ? draft.side : nil
            )
        )
    }

    /// The single exit: a complete pair commits (and the host closes the
    /// sheet); an incomplete one stays in the draft for the next tap.
    private func apply(_ outcome: MovementSidePickerPolicy.Outcome) {
        switch outcome {
        case .commit(let pair):
            draft = pair
            onCommit(pair)
        case .needsSide(let pending):
            sidePickedFirst = pending.movement.isEmpty && pending.side != .unspecified
            draft = pending
        }
    }
}

/// #1038 H1 (defect): the intensity control draws its OWN thumb and ticks
/// through one mapping, `IntensityScale.center`, so the 100% tick sits under
/// the thumb at 100 by construction. The system Slider's thumb inset changes
/// with the OS (iOS 26's capsule thumb is wider than the 28 pt circle), so
/// ticks computed beside it drifted ~3 pt — the exact defect H1 names.
struct IntensityTrack: View {
    let value: Int
    let locked: Bool
    let tint: Color
    let rail: Color
    let tickColor: Color
    let onChange: (Int) -> Void

    private let thumbDiameter = CGFloat(IntensityScale.thumbRadius * 2)
    private let railHeight: CGFloat = 4

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = Double(proxy.size.width)
                let thumbX = CGFloat(IntensityScale.center(value: Double(value), trackWidth: width))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(rail)
                        .frame(height: railHeight)
                    Capsule()
                        .fill(locked ? rail : tint)
                        .frame(width: max(railHeight, thumbX), height: railHeight)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                        .overlay(Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .position(x: thumbX, y: proxy.size.height / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard !locked else { return }
                            let next = IntensityScale.value(atX: Double(drag.location.x), trackWidth: width)
                            if next != value {
                                Haptics.shared.tap()
                                onChange(next)
                            }
                        }
                )
            }
            .frame(height: 44)

            GeometryReader { proxy in
                let width = Double(proxy.size.width)
                ForEach(IntensityScale.tickValues, id: \.self) { tick in
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(tickColor.opacity(0.6))
                            .frame(width: 1, height: 4)
                        Text("\(tick)%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(tickColor)
                            .fixedSize()
                    }
                    .position(
                        x: CGFloat(IntensityScale.center(value: Double(tick), trackWidth: width)),
                        y: 9
                    )
                }
            }
            .frame(height: 18)
            .accessibilityHidden(true)
        }
        .opacity(locked ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intensity")
        .accessibilityValue("\(value) percent")
        .accessibilityAdjustableAction { direction in
            guard !locked else { return }
            switch direction {
            case .increment: onChange(IntensityScale.stepped(value, by: 1))
            case .decrement: onChange(IntensityScale.stepped(value, by: -1))
            @unknown default: break
            }
        }
    }
}
