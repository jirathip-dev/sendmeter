import SendmeterCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode: HistoryMode = .sessions
    @State private var query = ""
    @State private var editingSession: SendmeterCore.Session?
    @State private var showingTrash = false

    private enum HistoryMode: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case force = "Force"
        var id: String { rawValue }
    }

    private var filteredSessions: [SendmeterCore.Session] {
        guard !query.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.typeLabel.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || $0.date.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredRecordings: [TindeqRecording] {
        // #631 (SL-92): hidden tags leave the default force list — their
        // recordings still exist and remain reachable through search.
        let base = query.isEmpty
            ? model.recordings.filter { !model.hiddenTagNames.contains($0.tag) }
            : model.recordings
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.tag.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || $0.side.label.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("History type", selection: $mode) {
                    ForEach(HistoryMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == .sessions {
                    SessionHistoryList(
                        sessions: filteredSessions,
                        edit: { editingSession = $0 },
                        delete: { session in Task { await model.deleteSession(session) } }
                    )
                } else {
                    ForceHistoryList(
                        recordings: filteredRecordings,
                        delete: { recording in Task { await model.deleteRecording(recording) } }
                    )
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("History")
            .searchable(text: $query, prompt: mode == .sessions ? "Search sessions" : "Search force recordings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingTrash = true } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
            }
            .refreshable { await model.refreshAll(showSpinner: false) }
            .sheet(item: $editingSession) { session in
                SessionEditorSheet(session: session)
            }
            .sheet(isPresented: $showingTrash) {
                TrashView()
            }
        }
    }
}

private struct SessionHistoryList: View {
    let sessions: [SendmeterCore.Session]
    let edit: (SendmeterCore.Session) -> Void
    let delete: (SendmeterCore.Session) -> Void

    var body: some View {
        if sessions.isEmpty {
            HistoryEmptyState(
                title: "No sessions yet",
                description: "Log a session or complete a workout to build your training history.",
                symbol: "calendar.badge.plus"
            )
        } else {
            List {
                ForEach(groupedDates, id: \.0) { date, rows in
                    Section(date) {
                        ForEach(rows) { session in
                            Button { edit(session) } label: {
                                SessionHistoryRow(session: session)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { delete(session) } label: {
                                    Label("Trash", systemImage: "trash")
                                }
                                Button { edit(session) } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(SendmeterStyle.primary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var groupedDates: [(String, [SendmeterCore.Session])] {
        let grouped = Dictionary(grouping: sessions, by: \.date)
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }
}

private struct SessionHistoryRow: View {
    let session: SendmeterCore.Session

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(SendmeterStyle.phaseColor(session.phase))
                .frame(width: 5, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(session.typeLabel)
                        .font(.headline)
                    if session.pending {
                        StatusPill("Pending", color: SendmeterStyle.caution)
                    }
                }
                Text(session.note.isEmpty ? PhaseCatalog.definition(for: session.phase).name : session.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(session.durationMinutes) min")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text("RPE \(session.rpe.formatted(.number.precision(.fractionLength(0...1))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ForceHistoryList: View {
    let recordings: [TindeqRecording]
    let delete: (TindeqRecording) -> Void

    var body: some View {
        if recordings.isEmpty {
            HistoryEmptyState(
                title: "No force recordings yet",
                description: "Connect a Progressor in Force and save a pull.",
                symbol: "waveform.path.ecg"
            )
        } else {
            List(recordings) { recording in
                NavigationLink {
                    ForceRecordingDetailView(recording: recording)
                } label: {
                    ForceHistoryRow(recording: recording)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { delete(recording) } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct ForceHistoryRow: View {
    let recording: TindeqRecording

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recording.protocolMode == .reverseAction ? "arrow.left.and.right.circle.fill" : "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(SendmeterStyle.primary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.tag.isEmpty ? "Untitled pull" : recording.tag)
                    .font(.headline)
                HStack(spacing: 7) {
                    Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    if recording.side != .unspecified { Text(recording.side.label) }
                    if let zone = recording.zone { Text(zone.rawValue.capitalized) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text((recording.peakKilograms ?? 0).formatted(.number.precision(.fractionLength(1))) + " kg")
                    .font(.headline.monospacedDigit())
                Text("\(recording.sampleCount) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SendmeterCore.Session
    @State private var isSaving = false

    init(session: SendmeterCore.Session) {
        self._draft = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    Picker("Type", selection: $draft.type) {
                        ForEach(SessionTypeCatalog.all) { type in
                            Text(type.label).tag(type.id)
                        }
                    }
                    .onChange(of: draft.type) { value in
                        draft.typeLabel = SessionTypeCatalog.definition(for: value).label
                    }
                    Stepper("Duration: \(draft.durationMinutes) min", value: $draft.durationMinutes, in: 1...600)
                    HStack {
                        Text("RPE")
                        Slider(value: $draft.rpe, in: 1...10, step: 0.5)
                        Text(draft.rpe.formatted(.number.precision(.fractionLength(0...1))))
                            .monospacedDigit()
                            .frame(width: 34)
                    }
                    // #627: a W'-depletion prediction is banked
                    // `rpe_confirmed = false` — nobody reviewed it. It stays
                    // fully editable; saving here is the review (the repo
                    // always writes `rpe_confirmed: true` on edit, matching
                    // the web).
                    if !draft.rpeConfirmed {
                        Label(
                            "Predicted from W′ depletion — adjust the slider to confirm",
                            systemImage: "wand.and.stars"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    TextField("Notes", text: $draft.note, axis: .vertical)
                }
                Section("Training Block") {
                    Label(PhaseCatalog.definition(for: draft.phase).name, systemImage: "square.stack.3d.up.fill")
                        .foregroundStyle(SendmeterStyle.phaseColor(draft.phase))
                    Text("Historical sessions keep the block they were logged under.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isSaving = true
                        Task {
                            await model.updateSession(draft)
                            isSaving = false
                            dismiss()
                        }
                    } label: {
                        if isSaving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

private struct ForceRecordingDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var recording: TindeqRecording
    @State private var samples: [TindeqSample] = []
    @State private var loadingSamples = false
    @State private var isSaving = false
    @State private var showingLinkSheet = false

    init(recording: TindeqRecording) {
        self._recording = State(initialValue: recording)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            MetricValue(
                                (recording.peakKilograms ?? 0).formatted(.number.precision(.fractionLength(1))),
                                unit: "kg"
                            )
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Avg \((recording.averageKilograms ?? 0).formatted(.number.precision(.fractionLength(1)))) kg")
                                Text((Double(recording.durationMilliseconds) / 1_000).formatted(.number.precision(.fractionLength(1))) + " s")
                                Text("\(recording.sampleCount) samples")
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        if loadingSamples {
                            ProgressView("Loading trace…")
                                .frame(maxWidth: .infinity, minHeight: 160)
                        } else if samples.isEmpty {
                            Text("No trace samples are available for this recording.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            ForceTraceChart(
                                samples: samples,
                                targetRange: targetRange,
                                target: recording.targetKilograms
                            )
                            .frame(height: 220)
                        }
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Metadata", systemImage: "tag")
                        TextField("Exercise or grip", text: $recording.tag)
                            .padding(10)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        Picker("Side", selection: $recording.side) {
                            ForEach(TindeqSide.allCases) { side in
                                Text(side.label).tag(side)
                            }
                        }
                        TextField("Notes", text: $recording.note, axis: .vertical)
                            .padding(10)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        Button {
                            isSaving = true
                            Task {
                                await model.updateRecording(recording)
                                isSaving = false
                            }
                        } label: {
                            HStack {
                                if isSaving { ProgressView().tint(.white) }
                                Text("Save Changes")
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(isSaving)
                    }
                }

                if let setNumber = recording.setNumber {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Protocol", systemImage: "list.number")
                            if recording.protocolMode == .reverseAction {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(reverseActionSummary(setNumber: setNumber))
                                        .font(.headline)
                                    Spacer()
                                    if let status = recording.completionStatus {
                                        StatusPill(
                                            status == "complete" ? "Complete" : "Partial",
                                            color: status == "complete" ? SendmeterStyle.optimal : SendmeterStyle.caution
                                        )
                                    }
                                }
                                if let metrics = recording.setMetrics {
                                    VStack(spacing: 7) {
                                        metricRow("Mean force", value: metrics.meanKilograms, suffix: "kg")
                                        metricRow("Stability (CV)", value: metrics.coefficientOfVariationPercent, suffix: "%")
                                        metricRow("In target", value: metrics.inTargetPercent, suffix: "%")
                                        metricRow("Drift", value: metrics.driftPercent, suffix: "%")
                                        HStack {
                                            Text("Cadence coverage")
                                            Spacer()
                                            Text("\(metrics.cadenceAdherencePercent.formatted(.number.precision(.fractionLength(1))))%")
                                                .monospacedDigit()
                                        }
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Set \(setNumber) · Rep \(recording.repetitionNumber ?? 1)")
                                    .font(.headline)
                            }
                            if let target = recording.targetKilograms {
                                Text("Target \(target.formatted(.number.precision(.fractionLength(1)))) kg")
                                    .foregroundStyle(.secondary)
                            }
                            if !recording.setupNote.isEmpty {
                                Text(recording.setupNote)
                                    .font(.subheadline)
                            }
                        }
                    }
                }

                Button {
                    showingLinkSheet = true
                } label: {
                    Label(
                        recording.groupID == nil ? "Link to Session" : "Linked to Session",
                        systemImage: recording.groupID == nil ? "link.badge.plus" : "link.circle.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(recording.groupID != nil)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(recording.tag.isEmpty ? "Force Recording" : recording.tag)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSamples() }
        .sheet(isPresented: $showingLinkSheet) {
            LinkRecordingSheet(recording: recording)
        }
    }

    private var targetRange: ClosedRange<Double>? {
        guard let low = recording.targetLowKilograms,
              let high = recording.targetHighKilograms else { return nil }
        return low...high
    }

    private func reverseActionSummary(setNumber: Int) -> String {
        let completed = recording.completedRepetitions ?? 0
        guard let planned = recording.plannedDurationMilliseconds,
              let out = recording.cadenceOutSeconds,
              let back = recording.cadenceReturnSeconds,
              out + back > 0
        else { return "Set \(setNumber) · \(completed) completed reps" }
        let prescribed = max(1, Int((Double(planned) / ((out + back) * 1_000)).rounded()))
        return "Set \(setNumber) · \(completed)/\(prescribed) reps"
    }

    @ViewBuilder
    private func metricRow(_ label: String, value: Double?, suffix: String) -> some View {
        if let value {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(1)))) \(suffix)")
                    .monospacedDigit()
            }
        }
    }

    private func loadSamples() async {
        loadingSamples = true
        defer { loadingSamples = false }
        do {
            samples = try await model.repository.fetchRecordingSamples(id: recording.id)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct LinkRecordingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let recording: TindeqRecording

    var body: some View {
        NavigationStack {
            List(model.sessions.filter { !$0.pending }.prefix(100)) { session in
                Button {
                    Task {
                        await model.linkRecordings([recording], to: session)
                        dismiss()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.typeLabel).font(.headline)
                            Text(session.date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("RPE \(session.rpe.formatted(.number.precision(.fractionLength(0...1))))")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Link to Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct TrashView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: TrashMode = .sessions
    @State private var sessionToPurge: SendmeterCore.Session?
    @State private var recordingToPurge: TindeqRecording?

    private enum TrashMode: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case force = "Force"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Trash type", selection: $mode) {
                    ForEach(TrashMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == .sessions {
                    List(model.deletedSessions) { session in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.typeLabel).font(.headline)
                                Text(session.date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button { Task { await model.restoreSession(session) } } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) { sessionToPurge = session } label: {
                                    Label("Delete Permanently", systemImage: "trash.slash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                } else {
                    List(model.deletedRecordings) { recording in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(recording.tag.isEmpty ? "Untitled pull" : recording.tag).font(.headline)
                                Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button { Task { await model.restoreRecording(recording) } } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) { recordingToPurge = recording } label: {
                                    Label("Delete Permanently", systemImage: "trash.slash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.refreshTrash() }
            .confirmationDialog(
                "Delete permanently?",
                isPresented: Binding(
                    get: { sessionToPurge != nil || recordingToPurge != nil },
                    set: { visible in
                        if !visible {
                            sessionToPurge = nil
                            recordingToPurge = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    let session = sessionToPurge
                    let recording = recordingToPurge
                    sessionToPurge = nil
                    recordingToPurge = nil
                    Task {
                        if let session { await model.purgeSession(session) }
                        if let recording { await model.purgeRecording(recording) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    sessionToPurge = nil
                    recordingToPurge = nil
                }
            } message: {
                Text("This item will be removed from Sendmeter and cannot be restored.")
            }
        }
    }
}

private struct HistoryEmptyState: View {
    let title: String
    let description: String
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(SendmeterStyle.primary)
            Text(title).font(.title3.bold())
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
