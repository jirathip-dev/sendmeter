import SendmeterCore
import SwiftUI

private struct GuidedProtocolLaunch: Identifiable {
    let preset: TindeqPreset
    let targetPlan: ForceTargetPlan
    var id: UUID { preset.id }
}

struct ForceView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("sendmeter.native.force.tag") private var tag = ""
    @AppStorage("sendmeter.native.force.side") private var sideValue = ""
    @AppStorage("sendmeter.native.force.zone") private var zoneValue = ""
    /// #628: the persisted hands-free toggle — the web's
    /// `sendmeter:gauge-hands-free` AppStorage equivalent.
    @AppStorage("sendmeter.native.force.hands-free") private var handsFreeEnabled = false
    @State private var selectedPresetID: UUID?
    @State private var editingPreset: TindeqPreset?
    @State private var creatingPreset = false
    @State private var runningProtocol: GuidedProtocolLaunch?
    @State private var selectedTargetPlan = ForceTargetPlan.empty
    @State private var resolvingTargets = false
    @State private var savingSummary = false
    /// #653: the recommended zone's preset + the quality it arms, kept in
    /// ForceView state rather than persisted with the user's own presets —
    /// arming Focus Next is a temporary guided-protocol selection, the same
    /// way the web's `zoneSel` is transient. Armed zone and user preset are
    /// mutually exclusive (#653 review finding 3). The quality is stored
    /// explicitly (not re-derived from the preset name) so the save-time zone
    /// stamp stays exact.
    @State private var zoneArmedPreset: TindeqPreset?
    @State private var armedZoneQuality: ZoneQuality?

    private var side: TindeqSide {
        get { TindeqSide(rawValue: sideValue) ?? .unspecified }
        nonmutating set { sideValue = newValue.rawValue }
    }

    /// The persisted zone pick (the metadata card's "Zone" picker). Deliberately
    /// separate from the Focus-Next arm: arming a recommendation never writes
    /// this, so clearing the arm never leaves a stale persisted zone stamp on
    /// unrelated presets or free pulls (#653 review finding 5). The arm's own
    /// zone is derived from the armed preset at save time instead.
    private var zone: RecordedZone? {
        get { RecordedZone(rawValue: zoneValue) }
        nonmutating set { zoneValue = newValue?.rawValue ?? "" }
    }

    private var selectedPreset: TindeqPreset? {
        if let selectedPresetID {
            return model.presets.first(where: { $0.id == selectedPresetID })
        }
        return zoneArmedPreset
    }

    /// The currently selected guided target for the metadata card: a user
    /// preset, the armed Focus-Next zone preset, or nil (free pull).
    private var selectedTarget: GuidedTarget? {
        if let selectedPresetID {
            return .userPreset(selectedPresetID)
        }
        if let zoneArmedPreset {
            return .armedZone(zoneArmedPreset.name)
        }
        return nil
    }

    /// True when the selected guided target is a reverse-action (movement)
    /// preset — the training-balance card offers only static-hold protocols,
    /// so it hides while one is selected (#653 review finding 13, web
    /// `capacityModality === "static"`).
    private var isReverseActionTarget: Bool {
        guard let preset = selectedPreset else { return false }
        return preset.protocolMode == .reverseAction
    }

    /// #627: the active gauge session's recording count (for the Finish pill
    /// on the device card).
    private var gaugeSessionCount: Int {
        guard model.gaugeSessionTracker.isActive else { return 0 }
        let groupID = model.gaugeSessionTracker.active?.groupID
        return model.recordings.filter { $0.groupID == groupID }.count
    }

    /// The force-curve signal for the Focus-Next tie-break: the cached static
    /// fit for the active tag, if any. Scoped to the tag (both sides) like the
    /// card, matching the web's model for the zone pick.
    private var zoneCurve: ZoneCurveInput? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard let curve = model.tagCurves.first(where: {
            $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                && $0.modality == "static"
        }) else { return nil }
        return ZoneCurveInput(curve)
    }

    /// The zone stamped onto recordings saved under the current selection:
    /// the armed Focus-Next quality wins (a guided run's holds carry the zone
    /// they were performed under as a fact — #653 review finding 1), otherwise
    /// the persisted metadata picker's zone. Never persisted itself.
    private var recordingZone: RecordedZone? {
        if let armedZoneQuality {
            return ZoneMix.recordedZone(for: armedZoneQuality)
        }
        return zone
    }

    /// #653: arm the recommended zone's guided protocol for the active tag —
    /// the web's Focus-Next pick path. Arming is just a selection (web
    /// `selectZone`): connection and the unsaved-recording guard belong to
    /// Start, not the pick — the main Start button launches the armed zone's
    /// guided protocol. Arming replaces any user preset (mutually exclusive,
    /// web `selectZoneOutcome`), and it never writes the persisted `zone`
    /// picker — the arm's zone is applied to saved recordings at save time,
    /// not left behind on the next free pull (#653 review findings 3 and 5).
    private func armRecommendedZone(_ zone: ZoneQuality) {
        zoneArmedPreset = ZoneMix.zonePreset(for: zone)
        armedZoneQuality = zone
        selectedPresetID = nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForceDeviceCard(
                        device: model.tindeq,
                        handsFreeEnabled: $handsFreeEnabled,
                        handsFreeArmed: model.handsFree.isArmed,
                        handsFreeMeasuring: model.handsFree.isMeasuring,
                        targetBand: selectedTargetPlan.band(forSet: 1, side: side),
                        resolvingTarget: resolvingTargets,
                        savingSummary: savingSummary,
                        gaugeSessionCount: gaugeSessionCount,
                        // #653: a Focus-Next-armed zone makes the main Start
                        // button launch that zone's guided protocol — the
                        // native equivalent of the web's Start-with-an-armed-
                        // zone opening the guided timer. With nothing armed it
                        // stays a free pull.
                        start: {
                            if let zoneArmedPreset {
                                launch(zoneArmedPreset)
                            } else {
                                startMeasurement()
                            }
                        },
                        connect: { model.requestConnect() },
                        armHandsFree: armHandsFree,
                        stopAndSave: stopAndSave,
                        cancelArm: { model.handsFree.cancelArm() },
                        finishSession: { Task { await model.endGaugeSession() } },
                        saveCompleted: saveCompleted,
                        saveRecovered: saveRecovered,
                        discardCompleted: { model.tindeq.clearCompletedRecording() },
                        discardRecovered: { model.tindeq.clearInterruptedRecording() }
                    )

                    ForceMetadataCard(
                        tag: $tag,
                        side: Binding(get: { side }, set: { side = $0 }),
                        zone: Binding(get: { zone }, set: { zone = $0 }),
                        selectedTarget: selectedTarget,
                        onSelectTarget: { target in
                            // A user preset pick and a Focus-Next arm are
                            // mutually exclusive (web `selectZoneOutcome` /
                            // `withPresetSelected`). Selecting any real target
                            // — or Free pull — clears the other.
                            switch target {
                            case .userPreset(let id):
                                zoneArmedPreset = nil
                                armedZoneQuality = nil
                                selectedPresetID = id
                            case .armedZone:
                                break
                            case nil:
                                selectedPresetID = nil
                                zoneArmedPreset = nil
                                armedZoneQuality = nil
                            }
                            publishFreePullContext()
                        },
                        presets: model.presets,
                        knownTags: model.visibleTagNames
                    )

                    // #653: training balance + Focus Next for the active
                    // exercise (both sides), arming the recommended zone's
                    // guided protocol — the same arms the ForceMetadataCard
                    // zone picker uses. The card shows for any selected tag;
                    // `zoneCurve` (the Focus-Next tie-break) is optional and
                    // nil when no static fit exists yet. It offers only
                    // static-hold zone protocols, so it hides while a
                    // reverse-action (movement) preset is selected — the
                    // native analogue of the web's `capacityModality ===
                    // "static"` gate (#653 review finding 13).
                    if !tag.isEmpty, !isReverseActionTarget {
                        ZoneFocusCard(
                            recordings: model.recordings.filter { $0.tag == tag },
                            exercise: tag,
                            curveInput: zoneCurve,
                            onPick: armRecommendedZone,
                            locked: model.tindeq.status == .measuring
                                || model.handsFree.isArmed
                                || model.handsFree.isMeasuring
                        )
                    }

                    if let live = model.watch.liveForce,
                       live.accountUserID == nil || live.accountUserID == model.currentUserID {
                        WatchForceMirrorCard(force: live)
                    }

                    ForceProtocolLibraryCard(
                        presets: model.presets,
                        run: { preset in
                            // #656: a tap opening the fullscreen arms the
                            // presentation tick (the guided protocol view
                            // spends it on appear).
                            Haptics.shared.tap()
                            launch(preset)
                        },
                        edit: {
                            // #656: see `run:` above.
                            Haptics.shared.tap()
                            editingPreset = $0
                        },
                        create: {
                            // #656: see `run:` above.
                            Haptics.shared.tap()
                            creatingPreset = true
                        },
                        delete: { preset in
                            // #656 (review F14): deleting a protocol preset is
                            // a confirm/destructive action — medium tick.
                            Haptics.shared.play(.medium)
                            Task { await model.deletePreset(preset) }
                        }
                    )

                    RecentForceCard(recordings: Array(model.recordings.prefix(8)))
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Force")
            .refreshable { await model.refreshAll(showSpinner: false) }
            .task(id: targetResolutionKey) {
                await resolveSelectedTarget()
            }
            // #628: the hands-free save path snapshots the recording context
            // (tag/side/zone/preset/target) at arm time.
            .onChange(of: tag) { _ in publishFreePullContext() }
            .onChange(of: side) { _ in publishFreePullContext() }
            .onChange(of: zone) { _ in publishFreePullContext() }
            .onChange(of: selectedPresetID) { _ in publishFreePullContext() }
            .onChange(of: zoneArmedPreset) { _ in publishFreePullContext() }
            .onChange(of: selectedTargetPlan) { _ in publishFreePullContext() }
            .onChange(of: handsFreeEnabled) { enabled in
                if !enabled { model.handsFree.disarm() }
                model.updateKeepAwake()
            }
            .sheet(item: $editingPreset) { preset in
                ForcePresetEditor(preset: preset, isNew: false)
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $creatingPreset) {
                ForcePresetEditor(preset: Self.defaultPreset(), isNew: true)
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .fullScreenCover(item: $runningProtocol) { launch in
                GuidedForceProtocolView(
                    preset: launch.preset,
                    targetPlan: launch.targetPlan,
                    tag: tag,
                    startingSide: side == .right ? .right : .left,
                    fallbackSide: side,
                    zone: recordingZone,
                    handsFreeEnabled: handsFreeEnabled
                )
            }
        }
    }

    /// #656: a refused gauge action fires the warning pattern, never the
    /// accepted tick (#222). The live surfaces are the guided-protocol Run
    /// button (not connected / pull owed — those two buttons carry no
    /// `.disabled`, so the tap is how the user learns why) and a Stop & Save
    /// with no samples. The Force tab's Start/Arm buttons use hard `.disabled`
    /// for the same conditions and therefore fire nothing — matching the web's
    /// #222 rule, where a genuinely disabled control gets no cue at all.
    private func refuseAction(_ message: String) {
        model.errorMessage = message
        Haptics.shared.play(RefusedActionHaptics.cue(tappableAndRefused: true))
    }

    private func startMeasurement() {
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction("Save or discard the previous pull before starting another.")
            return
        }
        do {
            try model.tindeq.startMeasuring()
        } catch {
            refuseAction(error.localizedDescription)
        }
    }

    /// #628: with the hands-free toggle on, Start arms the load-triggered
    /// loop instead of recording immediately.
    private func armHandsFree() {
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction("Save or discard the previous pull before starting another.")
            return
        }
        guard model.tindeq.status == .connected else {
            refuseAction("Connect the Progressor before arming hands-free.")
            return
        }
        publishFreePullContext()
        model.handsFree.arm()
    }

    private func stopAndSave() {
        // A manual Stop & Save while the hands-free loop owns the rep must go
        // through the loop (its claim + re-arm bookkeeping), not the direct
        // path — otherwise the machine still thinks it is recording.
        if model.handsFree.isMeasuring {
            model.handsFree.stopManually()
            return
        }
        // Defensive: an armed-but-not-measuring stream has no rep to save.
        if model.handsFree.isArmed {
            model.handsFree.cancelArm()
            return
        }
        guard let summary = model.tindeq.stopMeasuring() else {
            refuseAction("No force samples were received.")
            return
        }
        save(summary, recovered: false)
    }

    private func publishFreePullContext() {
        model.freePullContext = FreePullContext(
            tag: tag,
            side: side,
            zone: recordingZone,
            preset: selectedPreset,
            targetBand: selectedTargetPlan.band(forSet: 1, side: side)
        )
    }

    private func saveCompleted() {
        guard let summary = model.tindeq.completedSummary else { return }
        save(summary, recovered: false)
    }

    private func saveRecovered() {
        guard let summary = model.tindeq.interruptedRecording else { return }
        save(summary, recovered: true)
    }

    private func save(_ summary: ForceSummary, recovered: Bool) {
        savingSummary = true
        let savedTag = recovered && !tag.isEmpty ? "\(tag) · Recovered" : tag
        Task {
            let enqueued = await model.saveForceSummary(
                summary,
                tag: savedTag,
                side: side,
                zone: recordingZone,
                preset: selectedPreset,
                targetBand: selectedTargetPlan.band(forSet: 1, side: side)
            )
            if enqueued {
                model.tindeq.clearCompletedRecording()
                if recovered { model.tindeq.clearInterruptedRecording() }
            }
            savingSummary = false
        }
    }


    private var targetResolutionKey: String {
        let recordingFingerprint = model.recordings.prefix(24).map {
            "\($0.id.uuidString):\($0.sampleCount):\($0.recordedAt.timeIntervalSince1970)"
        }.joined(separator: "|")
        // #653 review finding 4: the key includes the armed zone preset (not
        // just `selectedPresetID`), so `.task(id:)` re-resolves the target
        // band the moment Focus Next is armed — the web resolves and displays
        // the zone's target as soon as it is picked, not after Start.
        let presetKey = selectedPresetID?.uuidString
            ?? zoneArmedPreset.map { "zone:\($0.name)" }
            ?? "free"
        return "\(presetKey)|\(tag)|\(side.rawValue)|\(recordingFingerprint)"
    }

    @MainActor
    private func resolveSelectedTarget() async {
        guard let preset = selectedPreset else {
            selectedTargetPlan = .empty
            resolvingTargets = false
            return
        }
        resolvingTargets = true
        let startSide: TindeqSide = side == .right ? .right : .left
        selectedTargetPlan = await model.resolveForceTargetPlan(
            preset: preset,
            tag: tag,
            startingSide: startSide,
            fallbackSide: side
        )
        resolvingTargets = false
    }

    private func launch(_ preset: TindeqPreset) {
        guard !model.tindeq.hasUnsavedRecording else {
            refuseAction("Save or discard the previous pull before starting a guided protocol.")
            return
        }
        guard model.tindeq.status == .connected else {
            refuseAction("Connect the Progressor before starting a guided protocol.")
            return
        }
        // #653: only a persisted user preset keeps the metadata picker in
        // sync; a transient Focus-Next zone preset is not in `model.presets`,
        // so it must not clobber `selectedPresetID` (which would read back
        // as "Free pull" and clear the zone arm).
        if model.presets.contains(where: { $0.id == preset.id }) {
            // A user preset and a Focus-Next arm are mutually exclusive
            // (#653 review finding 3): launching a user preset clears the arm.
            zoneArmedPreset = nil
            armedZoneQuality = nil
            selectedPresetID = preset.id
        }
        resolvingTargets = true
        Task {
            let startSide: TindeqSide = side == .right ? .right : .left
            let plan = await model.resolveForceTargetPlan(
                preset: preset,
                tag: tag,
                startingSide: startSide,
                fallbackSide: side
            )
            selectedTargetPlan = plan
            resolvingTargets = false
            runningProtocol = GuidedProtocolLaunch(preset: preset, targetPlan: plan)
        }
    }

    private static func defaultPreset() -> TindeqPreset {
        TindeqPreset(
            name: "Max Hangs",
            holdSeconds: 10,
            repetitions: 3,
            sets: 3,
            restBetweenRepetitionsSeconds: 120,
            restBetweenSetsSeconds: 180,
            prepareSeconds: 5
        )
    }
}

private struct ForceDeviceCard: View {
    @ObservedObject var device: TindeqBluetooth
    @Binding var handsFreeEnabled: Bool
    /// #628: the hands-free loop's state, mirrored from AppModel (the loop
    /// re-renders through the device's published sample/status changes).
    let handsFreeArmed: Bool
    let handsFreeMeasuring: Bool
    let targetBand: ForceTargetBand?
    let resolvingTarget: Bool
    let savingSummary: Bool
    let gaugeSessionCount: Int
    let start: () -> Void
    let connect: () -> Void
    let armHandsFree: () -> Void
    let stopAndSave: () -> Void
    let cancelArm: () -> Void
    let finishSession: () -> Void
    let saveCompleted: () -> Void
    let saveRecovered: () -> Void
    let discardCompleted: () -> Void
    let discardRecovered: () -> Void
    @State private var showingDiscardConfirmation = false
    @State private var discardIsRecovered = false

    private var targetRange: ClosedRange<Double>? { targetBand?.range }

    var body: some View {
        SurfaceCard {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel("Progressor", systemImage: "dot.radiowaves.left.and.right")
                        Text(statusLabel)
                            .font(.headline)
                    }
                    Spacer()
                    StatusPill(statusPill.text, color: statusPill.color)
                }

                if device.status == .measuring || device.handsFreeArmed || !device.visibleSamples.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        MetricValue(
                            device.currentKilograms.formatted(.number.precision(.fractionLength(1))),
                            unit: "kg",
                            color: inTarget ? SendmeterStyle.optimal : .primary
                        )
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("Peak \(device.peakKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                            Text("Average \(device.averageKilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                            Text((device.elapsedMilliseconds / 1_000).formatted(.number.precision(.fractionLength(1))) + " s")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    ForceTraceChart(
                        samples: device.visibleSamples,
                        targetRange: targetRange,
                        target: targetBand?.kilograms
                    )
                    .frame(height: 190)
                    .accessibilityLabel("Live force trace")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(SendmeterStyle.primary)
                        Text("Ready to measure")
                            .font(.title3.bold())
                        Text("Connect a Tindeq Progressor, tare it, then start a pull.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                }

                if resolvingTarget {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Resolving the protocol target from this exercise's force history…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if device.lowBattery {
                    Label("Progressor battery is low", systemImage: "battery.25percent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SendmeterStyle.alert)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                controls

                if gaugeSessionCount > 0, device.status == .connected {
                    HStack {
                        Label("Gauge session · \(gaugeSessionCount) recording\(gaugeSessionCount == 1 ? "" : "s")", systemImage: "waveform.path.ecg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Finish", action: finishSession)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SendmeterStyle.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                if device.interruptedRecording != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Unsaved pull recovered after disconnect", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            Button("Save Recovered Pull", action: saveRecovered)
                                .buttonStyle(.borderedProminent)
                                .disabled(savingSummary)
                            Button("Discard", role: .destructive) {
                                discardIsRecovered = true
                                showingDiscardConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(savingSummary)
                        }
                    }
                    .padding(12)
                    .background(SendmeterStyle.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                } else if device.completedSummary != nil, device.status != .measuring {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Completed pull is ready for a durable save", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            Button("Save Completed Pull", action: saveCompleted)
                                .buttonStyle(.borderedProminent)
                                .disabled(savingSummary)
                            Button("Discard", role: .destructive) {
                                discardIsRecovered = false
                                showingDiscardConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(savingSummary)
                        }
                    }
                    .padding(12)
                    .background(SendmeterStyle.optimal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert("Discard unsaved pull?", isPresented: $showingDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                // #656: a confirmed destructive action fires the medium tick
                // once per gesture.
                Haptics.shared.play(.medium)
                if discardIsRecovered { discardRecovered() }
                else { discardCompleted() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This pull has not been placed in the durable on-device queue and cannot be recovered after it is discarded.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch device.status {
        case .unavailable:
            Label("Bluetooth is not available for this app.", systemImage: "bluetooth.slash")
                .foregroundStyle(.secondary)
        case .idle, .interrupted:
            Button {
                // #656 (review F1): user-initiated — arms the transport's
                // success/error haptics for this launch.
                connect()
            } label: {
                Label("Connect Progressor", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(PrimaryActionButtonStyle())
        case .scanning, .connecting:
            HStack {
                ProgressView()
                Text(device.status == .scanning ? "Searching for Progressor…" : "Connecting…")
                Spacer()
                Button("Cancel") { device.disconnect() }
            }
        case .connected:
            VStack(spacing: 10) {
                if handsFreeMeasuring {
                    VStack(spacing: 8) {
                        Label(
                            "Measuring — release to save",
                            systemImage: "record.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SendmeterStyle.primary)
                        Button(action: stopAndSave) {
                            Label("Stop & Save", systemImage: "stop.fill")
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                } else if handsFreeArmed {
                    VStack(spacing: 8) {
                        Label("Armed — pull to measure", systemImage: "scope")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SendmeterStyle.primary)
                        Button("Cancel", role: .destructive) {
                            // #656 (review F14): disarming hands-free is a
                            // destructive action — medium tick.
                            Haptics.shared.play(.medium)
                            cancelArm()
                        }
                        .buttonStyle(.bordered)
                    }
                } else if handsFreeEnabled {
                    Button(action: armHandsFree) {
                        Label("Arm Hands-free", systemImage: "scope")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(device.hasUnsavedRecording)
                } else {
                    Button(action: start) {
                        Label("Start Pull", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(device.hasUnsavedRecording)
                }
                if device.hasUnsavedRecording {
                    Text("Save or discard the previous pull before starting another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button {
                        do { try device.tare() } catch { }
                    } label: {
                        Label("Tare", systemImage: "scalemass")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        do { try device.refreshBattery() } catch { }
                    } label: {
                        Label("Battery", systemImage: "battery.100percent")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Disconnect", role: .destructive) { device.disconnect() }
                        .buttonStyle(.borderless)
                }

                Toggle(isOn: $handsFreeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hands-free")
                            .font(.subheadline.weight(.medium))
                        Text("Measurement starts when you pull and saves when you release.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        case .measuring:
            Button(action: stopAndSave) {
                HStack {
                    if savingSummary { ProgressView().tint(.white) }
                    Label("Stop & Save", systemImage: "stop.fill")
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(savingSummary)
        }
    }

    private var statusLabel: String {
        switch device.status {
        case .unavailable: return "Unavailable"
        case .idle: return "Not connected"
        case .scanning: return "Searching"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .measuring: return "Measuring"
        case let .interrupted(message): return message
        }
    }

    private var statusPill: (text: String, color: Color) {
        switch device.status {
        case .connected: return ("Ready", SendmeterStyle.optimal)
        case .measuring: return ("Live", SendmeterStyle.primary)
        case .scanning, .connecting: return ("Working", SendmeterStyle.caution)
        case .interrupted: return ("Interrupted", SendmeterStyle.alert)
        case .unavailable: return ("Unavailable", SendmeterStyle.alert)
        case .idle: return ("Offline", .secondary)
        }
    }

    private var inTarget: Bool {
        guard let targetRange else { return false }
        return targetRange.contains(device.currentKilograms)
    }
}

private struct ForceMetadataCard: View {
    @Binding var tag: String
    @Binding var side: TindeqSide
    @Binding var zone: RecordedZone?
    /// The selected guided target. `nil` = free pull; a UUID = one of the
    /// user's presets; `armedZonePreset` is shown by name and, when picked,
    /// maps to a `nil` selection after clearing the arm (#653 review finding 2
    /// — Focus Next must be disarmable and visible in the picker).
    let selectedTarget: GuidedTarget?
    let onSelectTarget: (GuidedTarget?) -> Void
    let presets: [TindeqPreset]
    /// #631: pickable exercise names — distinct recording tags minus hidden
    /// (SL-92). Hidden tags' recordings still exist, they just leave the
    /// default pickers.
    let knownTags: [String]

    private var selection: Int {
        switch selectedTarget {
        case nil: return 0
        case let .armedZone(name): return 1
        case let .userPreset(id):
            if let index = presets.firstIndex(where: { $0.id == id }) {
                return index + 2
            }
            return 0
        }
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Recording context", systemImage: "tag")
                TextField("Exercise or grip, e.g. 20 mm half crimp", text: $tag)
                    .textInputAutocapitalization(.sentences)
                    .padding(11)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                if !knownTags.isEmpty {
                    Picker("Known exercises", selection: $tag) {
                        Text("Type your own").tag("")
                        ForEach(knownTags, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Picker("Side", selection: $side) {
                        ForEach(TindeqSide.allCases) { side in
                            Text(side.label).tag(side)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Picker("Zone", selection: $zone) {
                        Text("Not set").tag(Optional<RecordedZone>.none)
                        ForEach(RecordedZone.allCases, id: \.self) { zone in
                            Text(zone.displayLabel).tag(Optional(zone))
                        }
                    }
                    .pickerStyle(.menu)
                }
                Picker("Guided target", selection: Binding(
                    get: { selection },
                    set: { index in
                        switch index {
                        case 0: onSelectTarget(nil)
                        case 1: break // the armed zone is cleared by picking Free pull; no re-arm here
                        default:
                            let presetIndex = index - 2
                            if presets.indices.contains(presetIndex) {
                                onSelectTarget(.userPreset(presets[presetIndex].id))
                            }
                        }
                    }
                )) {
                    Text("Free pull").tag(0)
                    if case let .armedZone(name) = selectedTarget {
                        Text("\(name) (Focus Next)").tag(1)
                    }
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                        Text(preset.name).tag(index + 2)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

/// The selected guided target on the Force tab: a free pull, one of the user's
/// presets, or a Focus-Next-armed zone preset (#653).
private enum GuidedTarget: Equatable {
    case userPreset(UUID)
    case armedZone(String)
}

struct ForceTraceChart: View {
    let samples: [TindeqSample]
    let targetRange: ClosedRange<Double>?
    let target: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let maxSample = samples.map(\.kilograms).max() ?? 0
            let maxValue = max(10, max(maxSample, targetRange?.upperBound ?? 0)) * 1.15
            let firstTime = samples.first?.milliseconds ?? 0
            let lastTime = max(firstTime + 1, samples.last?.milliseconds ?? firstTime + 1)
            let gridColor = ChartToken.grid.color(scheme)
            let optimalColor = ChartToken.optimal.color(scheme)

            func y(_ kilograms: Double) -> CGFloat {
                size.height - CGFloat(max(0, kilograms) / maxValue) * size.height
            }
            func x(_ milliseconds: Double) -> CGFloat {
                CGFloat((milliseconds - firstTime) / (lastTime - firstTime)) * size.width
            }

            for index in 1..<4 {
                var grid = Path()
                let lineY = size.height * CGFloat(index) / 4
                grid.move(to: CGPoint(x: 0, y: lineY))
                grid.addLine(to: CGPoint(x: size.width, y: lineY))
                context.stroke(grid, with: .color(gridColor), lineWidth: 1)
            }

            if let targetRange {
                let upperY = y(targetRange.upperBound)
                let lowerY = y(targetRange.lowerBound)
                context.fill(
                    Path(CGRect(x: 0, y: upperY, width: size.width, height: max(1, lowerY - upperY))),
                    with: .color(optimalColor.opacity(ChartToken.optimal.bandOpacity(scheme)))
                )
            }
            if let target {
                var targetPath = Path()
                targetPath.move(to: CGPoint(x: 0, y: y(target)))
                targetPath.addLine(to: CGPoint(x: size.width, y: y(target)))
                context.stroke(
                    targetPath,
                    with: .color(optimalColor.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
            }

            guard samples.count > 1 else { return }
            var trace = Path()
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(x: x(sample.milliseconds), y: y(sample.kilograms))
                if index == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
            }
            context.stroke(
                trace,
                with: .color(ChartToken.force.color(scheme)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct WatchForceMirrorCard: View {
    let force: WatchLiveForce

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Apple Watch Force", systemImage: "applewatch")
                        .font(.headline)
                    Spacer()
                    StatusPill(force.status.capitalized, color: force.status == "measuring" ? SendmeterStyle.primary : SendmeterStyle.optimal)
                }
                HStack(alignment: .firstTextBaseline) {
                    MetricValue(
                        (force.kilograms ?? 0).formatted(.number.precision(.fractionLength(1))),
                        unit: "kg"
                    )
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Peak \((force.peakKilograms ?? 0).formatted(.number.precision(.fractionLength(1)))) kg")
                        if let tag = force.tag, !tag.isEmpty { Text(tag) }
                        if force.side != .unspecified { Text(force.side.label) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !force.spark.isEmpty {
                    ForceTraceChart(samples: force.spark, targetRange: nil, target: nil)
                        .frame(height: 100)
                }
                Text("Direct WatchConnectivity · updated \(force.updatedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ForceProtocolLibraryCard: View {
    let presets: [TindeqPreset]
    let run: (TindeqPreset) -> Void
    let edit: (TindeqPreset) -> Void
    let create: () -> Void
    let delete: (TindeqPreset) -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Guided protocols", systemImage: "list.bullet.rectangle.portrait")
                    Spacer()
                    Button(action: create) { Label("New", systemImage: "plus") }
                        .labelStyle(.iconOnly)
                }
                if presets.isEmpty {
                    Text("Create repeaters, max hangs, capacity holds, or reverse-action cadence protocols.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Create Protocol", action: create)
                        .buttonStyle(.bordered)
                } else {
                    ForEach(presets) { preset in
                        HStack(spacing: 12) {
                            Button { run(preset) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name).font(.headline)
                                    Text(protocolSummary(preset))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button { run(preset) } label: { Label("Run", systemImage: "play.fill") }
                                Button { edit(preset) } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { delete(preset) } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                            }
                        }
                        if preset.id != presets.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func protocolSummary(_ preset: TindeqPreset) -> String {
        if preset.protocolMode == .reverseAction {
            return "\(preset.sets) sets · \(preset.repetitions) reps · \(preset.cadenceOutSeconds.formatted())/\(preset.cadenceReturnSeconds.formatted()) s cadence"
        }
        return "\(preset.sets) × \(preset.repetitions) · \(preset.holdSeconds)s hold · \(preset.restBetweenRepetitionsSeconds)s rest"
    }
}

private struct RecentForceCard: View {
    let recordings: [TindeqRecording]

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Recent recordings", systemImage: "clock")
                if recordings.isEmpty {
                    Text("Completed pulls will appear here after their durable local save is queued.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recordings) { recording in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text(recording.tag.isEmpty ? "Untitled pull" : recording.tag)
                                        .font(.headline)
                                    // #675 F1: a restored quarantined
                                    // placeholder reads "Rejected" — it won't
                                    // upload on its own.
                                    if recording.rejected {
                                        StatusPill("Rejected", color: SendmeterStyle.alert)
                                    }
                                }
                                Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((recording.peakKilograms ?? 0).formatted(.number.precision(.fractionLength(1))) + " kg")
                                .font(.headline.monospacedDigit())
                        }
                        if recording.id != recordings.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private enum ForceTargetMode: String, CaseIterable, Identifiable {
    case none
    case fixed
    case percentagePR
    case percentageCF
    case curve

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .fixed: return "Fixed kg"
        case .percentagePR: return "% of PR"
        case .percentageCF: return "% of CF"
        case .curve: return "Auto curve"
        }
    }
}

private struct ForcePresetEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TindeqPreset
    @State private var targetMode: ForceTargetMode
    @State private var varyHolds: Bool
    @State private var isSaving = false
    let isNew: Bool

    init(preset: TindeqPreset, isNew: Bool) {
        self._draft = State(initialValue: preset)
        let mode: ForceTargetMode
        if preset.targetFromCurve {
            mode = .curve
        } else if preset.targetPercentage != nil {
            mode = preset.percentageBasis == .criticalForce ? .percentageCF : .percentagePR
        } else if preset.targetKilograms != nil {
            mode = .fixed
        } else {
            mode = .none
        }
        self._targetMode = State(initialValue: mode)
        self._varyHolds = State(initialValue: preset.holdSecondsBySet != nil)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Protocol") {
                    TextField("Name", text: $draft.name)
                    Picker("Mode", selection: $draft.protocolMode) {
                        Text("Hold").tag(ForceProtocolMode.hold)
                        Text("Reverse Action").tag(ForceProtocolMode.reverseAction)
                    }
                    Stepper("Sets: \(draft.sets)", value: $draft.sets, in: 1...20)
                    Stepper("Repetitions: \(draft.repetitions)", value: $draft.repetitions, in: 1...50)
                    if draft.protocolMode == .hold {
                        Stepper("Base hold: \(draft.holdSeconds) s", value: $draft.holdSeconds, in: 1...600)
                        Toggle("Vary hold by set", isOn: $varyHolds)
                        if varyHolds {
                            ForEach(1...max(1, draft.sets), id: \.self) { setNumber in
                                HStack {
                                    Text("Set \(setNumber)")
                                    Spacer()
                                    TextField(
                                        "seconds",
                                        value: holdBinding(setNumber: setNumber),
                                        format: .number
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                    Text("s").foregroundStyle(.secondary)
                                }
                            }
                        }
                        Stepper(
                            "Rest between reps: \(draft.restBetweenRepetitionsSeconds) s",
                            value: $draft.restBetweenRepetitionsSeconds,
                            in: 0...900,
                            step: 5
                        )
                    } else {
                        HStack {
                            Text("Pull out")
                            Spacer()
                            TextField("seconds", value: $draft.cadenceOutSeconds, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                            Text("s").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Return")
                            Spacer()
                            TextField("seconds", value: $draft.cadenceReturnSeconds, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                            Text("s").foregroundStyle(.secondary)
                        }
                    }
                    Stepper(
                        "Rest between sets: \(draft.restBetweenSetsSeconds) s",
                        value: $draft.restBetweenSetsSeconds,
                        in: 0...1_800,
                        step: 5
                    )
                    Stepper("Prepare: \(draft.prepareSeconds) s", value: $draft.prepareSeconds, in: 0...60)
                    Toggle("Alternate sides", isOn: $draft.alternateSides)
                }

                Section("Target") {
                    Picker("Target mode", selection: $targetMode) {
                        ForEach(ForceTargetMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    switch targetMode {
                    case .none:
                        Text("No target band will be shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .fixed:
                        kilogramsField
                    case .percentagePR, .percentageCF:
                        HStack {
                            Text(targetMode == .percentageCF ? "Percent of CF" : "Percent of PR")
                            Spacer()
                            TextField(
                                "percent",
                                value: Binding(
                                    get: { draft.targetPercentage ?? 80 },
                                    set: { draft.targetPercentage = min(150, max(1, $0)) }
                                ),
                                format: .number
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            Text("%").foregroundStyle(.secondary)
                        }
                        if draft.sets > 1 {
                            HStack {
                                Text("Increase each set")
                                Spacer()
                                TextField("step", value: $draft.percentageStep, format: .number)
                                    .keyboardType(.numbersAndPunctuation)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                Text("%").foregroundStyle(.secondary)
                            }
                        }
                        Text(targetMode == .percentageCF
                             ? "Uses this exercise and side's critical-force estimate."
                             : "Uses this exercise and side's best recorded peak.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .curve:
                        Text("Each set resolves against the exercise's Hill force-duration curve at that set's prescribed work duration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if targetMode != .none {
                        Picker("Tolerance", selection: $draft.toleranceMode) {
                            Text("Percent").tag("percent")
                            Text("Kilograms").tag("kg")
                        }
                        HStack {
                            Text("Tolerance value")
                            Spacer()
                            TextField("value", value: $draft.toleranceValue, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text(draft.toleranceMode == "kg" ? "kg" : "%")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Coaching") {
                    TextField("Setup note", text: $draft.setupNote, axis: .vertical)
                    Toggle("Counts as capacity evidence", isOn: $draft.capacityEvidence)
                }
            }
            .navigationTitle(isNew ? "New Protocol" : "Edit Protocol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .onChange(of: draft.sets) { _ in
                normalizeHoldOverrides()
            }
            .onChange(of: varyHolds) { enabled in
                if enabled { normalizeHoldOverrides() }
            }
        }
    }

    @ViewBuilder
    private var kilogramsField: some View {
        HStack {
            Text("Target")
            Spacer()
            TextField(
                "kg",
                value: Binding(
                    get: { draft.targetKilograms ?? 0 },
                    set: { draft.targetKilograms = max(0, $0) }
                ),
                format: .number
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            Text("kg").foregroundStyle(.secondary)
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.sets > 0
            && draft.repetitions > 0
            && (draft.protocolMode == .hold
                || (draft.cadenceOutSeconds >= 0.25 && draft.cadenceReturnSeconds >= 0.25))
            && (targetMode != .fixed || (draft.targetKilograms ?? 0) > 0)
            && ((targetMode != .percentagePR && targetMode != .percentageCF)
                || (draft.targetPercentage ?? 0) > 0)
    }

    private func holdBinding(setNumber: Int) -> Binding<Int> {
        Binding(
            get: {
                guard let values = draft.holdSecondsBySet,
                      values.indices.contains(setNumber - 1)
                else { return draft.holdSeconds }
                return values[setNumber - 1]
            },
            set: { value in
                normalizeHoldOverrides()
                draft.holdSecondsBySet?[setNumber - 1] = min(600, max(1, value))
            }
        )
    }

    private func normalizeHoldOverrides() {
        guard varyHolds else { return }
        var values = draft.holdSecondsBySet ?? []
        if values.count < draft.sets {
            values.append(contentsOf: Array(repeating: draft.holdSeconds, count: draft.sets - values.count))
        } else if values.count > draft.sets {
            values = Array(values.prefix(draft.sets))
        }
        draft.holdSecondsBySet = values.map { min(600, max(1, $0)) }
    }

    private func save() {
        isSaving = true
        if varyHolds {
            normalizeHoldOverrides()
        } else {
            draft.holdSecondsBySet = nil
        }
        switch targetMode {
        case .none:
            draft.targetKilograms = nil
            draft.targetPercentage = nil
            draft.targetFromCurve = false
        case .fixed:
            draft.targetKilograms = max(0.1, draft.targetKilograms ?? 0.1)
            draft.targetPercentage = nil
            draft.targetFromCurve = false
        case .percentagePR:
            draft.targetKilograms = nil
            draft.targetPercentage = min(150, max(1, draft.targetPercentage ?? 80))
            draft.percentageBasis = .personalRecord
            draft.targetFromCurve = false
        case .percentageCF:
            draft.targetKilograms = nil
            draft.targetPercentage = min(150, max(1, draft.targetPercentage ?? 80))
            draft.percentageBasis = .criticalForce
            draft.targetFromCurve = false
        case .curve:
            draft.targetKilograms = nil
            draft.targetPercentage = nil
            draft.targetFromCurve = true
        }
        draft.cadenceOutSeconds = max(0.25, draft.cadenceOutSeconds)
        draft.cadenceReturnSeconds = max(0.25, draft.cadenceReturnSeconds)
        draft.toleranceValue = max(0, draft.toleranceValue)
        draft.setupNote = String(draft.setupNote.prefix(500))
        Task {
            await model.savePreset(draft, isNew: isNew)
            isSaving = false
            dismiss()
        }
    }
}

private struct GuidedForceProtocolView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var run: ForceProtocolRun
    @State private var observedStageID: UUID?
    @State private var isAdvancing = false
    @State private var savedCount = 0
    @State private var interrupted = false
    @State private var claimedStageIDs = Set<UUID>()
    /// #656: idempotence for the segment-transition cue — the FIRST observed
    /// stage (prepare, or work on a no-prepare run) never re-cues (web
    /// "Normal protocols do not re-cue their first visible segment"), and
    /// every later stage cues exactly once per transition.
    @State private var hasObservedFirstStage = false
    /// #656: the last hands-free status a cue was fired for (armed → 80 ms,
    /// measuring → 150 ms) — the web fires once per status CHANGE, not per
    /// feed sample, so the guard is a change check against this.
    @State private var lastHandsFreeHaptic: HandsFreeHapticState?

    let preset: TindeqPreset
    let targetPlan: ForceTargetPlan
    let tag: String
    let startingSide: TindeqSide
    let fallbackSide: TindeqSide
    let zone: RecordedZone?
    /// #628: snapshot of the hands-free toggle at launch — mid-run changes
    /// apply to the next run, never to the segments already walking.
    let handsFreeEnabled: Bool

    init(
        preset: TindeqPreset,
        targetPlan: ForceTargetPlan,
        tag: String,
        startingSide: TindeqSide,
        fallbackSide: TindeqSide,
        zone: RecordedZone?,
        handsFreeEnabled: Bool = false
    ) {
        self.preset = preset
        self.targetPlan = targetPlan
        self.tag = tag
        self.startingSide = startingSide
        self.fallbackSide = fallbackSide
        self.zone = zone
        self.handsFreeEnabled = handsFreeEnabled
        self._run = State(initialValue: ForceProtocolRun(preset: preset, startingSide: startingSide))
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                VStack(spacing: 22) {
                    Spacer(minLength: 12)
                    VStack(spacing: 7) {
                        Text(run.currentStage.label)
                            .font(.largeTitle.bold())
                        if run.currentStage.side != .unspecified {
                            StatusPill(run.currentStage.side.label, color: SendmeterStyle.primary)
                        }
                        Text("Set \(run.currentStage.setNumber) · Rep \(run.currentStage.repetitionNumber)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if run.currentStage.kind == .work {
                        MetricValue(
                            model.tindeq.currentKilograms.formatted(.number.precision(.fractionLength(1))),
                            unit: "kg",
                            color: protocolInTarget ? SendmeterStyle.optimal : .primary
                        )
                        ForceTraceChart(
                            samples: model.tindeq.visibleSamples,
                            targetRange: currentTargetBand?.range,
                            target: currentTargetBand?.kilograms
                        )
                        .frame(height: 220)
                    } else {
                        Image(systemName: stageSymbol)
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(stageColor)
                    }

                    Text(Int(ceil(run.remainingSeconds(at: context.date))), format: .number)
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("seconds remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ProgressView(
                        value: run.currentStage.durationSeconds == 0
                            ? 1
                            : min(1, run.elapsedSeconds(at: context.date) / run.currentStage.durationSeconds)
                    )
                    .tint(stageColor)

                    Text("\(savedCount) pull\(savedCount == 1 ? "" : "s") durably queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if run.isComplete || interrupted {
                        Button("Finish") {
                            Task { await model.endGaugeSession() }
                            model.guidedActivity.end(immediate: true)
                            dismiss()
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    } else {
                        Button("Skip Stage") {
                            Task { await skipCurrentStage(at: context.date) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isAdvancing)
                    }
                    Spacer(minLength: 12)
                }
                .padding()
                .task(id: Int(context.date.timeIntervalSince1970 * 5)) {
                    await tick(at: context.date)
                }
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!run.isComplete && !interrupted)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .destructive) {
                        // #656 (review F14): cancelling a running protocol is
                        // a confirm/destructive action — medium tick.
                        Haptics.shared.play(.medium)
                        Task { await cancelAndPreserve() }
                    }
                }
            }
            .onAppear {
                run.start()
                // #656: the Run tap armed this presentation — give the
                // fullscreen the sheet tick, gated on that gesture.
                Haptics.shared.sheetPresented()
                // #628: hands-free arming + the lock-screen mirror own the
                // run while this view is up; the device card's automatic
                // stop/save loop must not intercept a stage's release.
                if handsFreeEnabled {
                    model.handsFree.stopPolicy = .callerOwned
                }
                model.setGuidedProtocolActive(true)
                model.guidedActivity.start(
                    run: run,
                    preset: preset,
                    targetPlan: targetPlan,
                    fallbackSide: fallbackSide
                )
            }
            .onDisappear {
                model.setGuidedProtocolActive(false)
                model.handsFree.stopPolicy = .automatic
                model.handsFree.disarm()
                model.guidedActivity.end(immediate: true)
                hasObservedFirstStage = false
                lastHandsFreeHaptic = nil
            }
        }
    }

    private var stageSymbol: String {
        switch run.currentStage.kind {
        case .prepare: return "hourglass"
        case .switchSide: return "arrow.left.arrow.right"
        case .restBetweenRepetitions, .restBetweenSets: return "pause.fill"
        case .complete: return "checkmark.circle.fill"
        case .work: return "waveform.path.ecg"
        }
    }

    private var stageColor: Color {
        switch run.currentStage.kind {
        case .work: return SendmeterStyle.primary
        case .complete: return SendmeterStyle.optimal
        case .prepare, .switchSide: return SendmeterStyle.caution
        case .restBetweenRepetitions, .restBetweenSets: return SendmeterStyle.optimal
        }
    }

    private var currentStageSide: TindeqSide {
        run.currentStage.side == .unspecified ? fallbackSide : run.currentStage.side
    }

    private var currentTargetBand: ForceTargetBand? {
        targetPlan.band(forSet: run.currentStage.setNumber, side: currentStageSide)
    }

    private var protocolInTarget: Bool {
        currentTargetBand?.range.contains(model.tindeq.currentKilograms) ?? false
    }

    @MainActor
    private func tick(at date: Date) async {
        guard !run.isComplete, !interrupted, !isAdvancing else { return }

        if case .interrupted = model.tindeq.status {
            interrupted = true
            model.handsFree.disarm()
            model.guidedActivity.end(immediate: true)
            if let summary = model.tindeq.interruptedRecording {
                let enqueued = await preserve(summary, stage: run.currentStage, partial: true)
                if enqueued { model.tindeq.clearInterruptedRecording() }
            }
            // The run owns the session end on disconnect: preserve the final
            // rep first, THEN end the session, so the partial rep joins THIS
            // group instead of a fresh one minted by a racing end.
            await model.endGaugeSession()
            return
        }

        // #656: hands-free armed → single 80 ms, measuring → single 150 ms,
        // once per status CHANGE (the web's lastHandsFreeStatusRef effect).
        // Gated on this fullscreen being hands-free; free pulls on the Force
        // tab keep the transport's own haptics (none here).
        if handsFreeEnabled {
            let next: HandsFreeHapticState?
            if model.handsFree.isMeasuring {
                next = .measuring
            } else if model.handsFree.isArmed {
                next = .armed
            } else {
                next = nil
            }
            if next != lastHandsFreeHaptic {
                lastHandsFreeHaptic = next
                if let next {
                    Haptics.shared.play(HandsFreeHaptics.cue(for: next))
                }
            }
        }

        if observedStageID != run.currentStage.id {
            observedStageID = run.currentStage.id
            // #656: the web cues segment transitions in rhythm
            // (`ForceFullscreen.tsx`); native plays the same pattern once per
            // transition. The first observed stage is skipped, matching the
            // web's no-re-cue rule for the opening segment.
            if hasObservedFirstStage {
                Haptics.shared.play(GuidedTransitionHaptics.cue(entering: run.currentStage.kind))
            } else {
                hasObservedFirstStage = true
            }
            // #628: hands-free arming gates the START of a work stage on the
            // load actually being applied; the stage timer still owns every
            // stop/save, so save-per-hold stays intact.
            if run.currentStage.kind == .work {
                if handsFreeEnabled {
                    model.handsFree.arm()
                } else {
                    do {
                        try model.tindeq.startMeasuring()
                    } catch {
                        model.errorMessage = error.localizedDescription
                        interrupted = true
                        model.guidedActivity.end(immediate: true)
                        return
                    }
                }
            }
            model.guidedActivity.refresh(run: run, at: date)
        }

        guard run.remainingSeconds(at: date) <= 0 else { return }
        await advanceCurrentStage(at: date)
    }

    @MainActor
    private func advanceCurrentStage(at date: Date) async {
        guard !isAdvancing else { return }
        isAdvancing = true
        let stage = run.currentStage
        if stage.kind == .work, let summary = model.tindeq.stopMeasuring() {
            model.guidedActivity.updatePeak(summary.peakKilograms, run: run, at: date)
            let enqueued = await preserve(summary, stage: stage, partial: false)
            guard enqueued else {
                isAdvancing = false
                interrupted = true
                model.guidedActivity.end(immediate: true)
                return
            }
            model.tindeq.clearCompletedRecording()
        }
        run.advance(at: date)
        observedStageID = nil
        // #656 (review F3): the moment the run steps into the `.complete`
        // stage, every later `tick` returns early at `guard !run.isComplete`,
        // so the transition block never reaches the `.complete` case — this
        // is the one cue the user is waiting for while looking away from the
        // phone, and the web fires it ("done" → `[80,60,80]` + 3 beeps).
        // #674 review F5: same terminal-entry reason — the Live Activity DONE
        // card must be pushed here explicitly or it sits on the last rest.
        if run.currentStage.kind == .complete {
            Haptics.shared.play(GuidedTransitionHaptics.cue(entering: .complete))
            model.guidedActivity.refresh(run: run, at: date)
        }
        // #628: disarm the stage's arming so rest/switch stages cannot start
        // a phantom recording on leftover load; the next work stage re-arms.
        if stage.kind == .work {
            model.handsFree.disarm()
        }
        isAdvancing = false
    }

    @MainActor
    private func skipCurrentStage(at date: Date) async {
        await advanceCurrentStage(at: date)
    }

    @MainActor
    private func cancelAndPreserve() async {
        let stage = run.currentStage
        if stage.kind == .work, let summary = model.tindeq.stopMeasuring() {
            let enqueued = await preserve(summary, stage: stage, partial: true)
            if enqueued {
                model.tindeq.clearCompletedRecording()
            } else {
                interrupted = true
                model.guidedActivity.end(immediate: true)
                return
            }
        }
        model.handsFree.disarm()
        model.guidedActivity.end(immediate: true)
        dismiss()
    }

    @MainActor
    private func preserve(
        _ summary: ForceSummary,
        stage: ForceProtocolStage,
        partial: Bool
    ) async -> Bool {
        guard claimedStageIDs.insert(stage.id).inserted else { return true }
        let side = stage.side == .unspecified ? fallbackSide : stage.side
        let savedTag: String
        if partial {
            savedTag = tag.isEmpty ? "\(preset.name) · Partial" : "\(tag) · Partial"
        } else {
            savedTag = tag.isEmpty ? preset.name : tag
        }
        let enqueued = await model.saveForceSummary(
            summary,
            tag: savedTag,
            side: side,
            zone: zone,
            preset: preset,
            targetBand: targetPlan.band(forSet: stage.setNumber, side: side),
            protocolRunID: run.runID,
            setNumber: stage.setNumber,
            repetitionNumber: stage.repetitionNumber,
            partial: partial
        )
        if enqueued {
            savedCount += 1
        } else {
            claimedStageIDs.remove(stage.id)
        }
        return enqueued
    }
}
