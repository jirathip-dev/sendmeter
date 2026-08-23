import SendmeterCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode: HistoryMode = .all
    @State private var query = ""
    @State private var editingSession: SendmeterCore.Session?
    @State private var showingTrash = false
    /// #630: multi-select of loose recordings → one new session (web parity).
    @State private var selectedIDs: Set<UUID> = []
    @State private var creating = false
    @State private var createError: String?
    @State private var assignOpen = false
    @State private var retryingUploads = false
    /// Lazy paging (web pages 40/batch).
    @State private var visibleCount = HistoryPaging.pageSize
    /// Filter chips (web `historyFilters.ts`): a stale selection is coerced
    /// to nil in `filterOptions` and committed back via `onChange`.
    @State private var selectedType: String?
    @State private var selectedTag: String?

    private enum HistoryMode: String, CaseIterable, Identifiable {
        case all = "All"
        case sessions = "Sessions"
        case force = "Force"
        var id: String { rawValue }
    }

    // MARK: Derived data

    private var recordingsByGroup: [UUID: [TindeqRecording]] {
        var result: [UUID: [TindeqRecording]] = [:]
        for recording in model.recordings {
            guard let groupID = recording.groupID else { continue }
            result[groupID, default: []].append(recording)
        }
        return result
    }

    private var looseRecordings: [TindeqRecording] {
        HistoryTimeline.looseRecordings(model.recordings, in: model.sessions)
    }

    private var filterOptions: HistoryFilterOptions {
        HistoryFilters.options(
            sessions: model.sessions,
            looseRecordings: looseRecordings,
            groupedRecordings: model.recordings.filter { $0.groupID != nil },
            selectedType: selectedType,
            selectedTag: selectedTag,
            hiddenTagNames: model.hiddenTagNames
        )
    }

    private var queryFilteredSessions: [SendmeterCore.Session] {
        guard !query.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.typeLabel.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || $0.date.localizedCaseInsensitiveContains(query)
        }
    }

    private var queryFilteredRecordings: [TindeqRecording] {
        // #647 (SL-92): hiding a tag removes its chip, not its timeline rows.
        return HistoryFilters.recordingsMatchingQuery(model.recordings, query: query)
    }

    private var filteredSessions: [SendmeterCore.Session] {
        queryFilteredSessions.filter { session in
            HistoryFilters.sessionMatches(
                session,
                groupRecordings: session.groupID.flatMap { recordingsByGroup[$0] } ?? [],
                type: filterOptions.activeType,
                tag: filterOptions.activeTag
            )
        }
    }

    private var filteredLooseRecordings: [TindeqRecording] {
        HistoryTimeline.looseRecordings(queryFilteredRecordings, in: model.sessions).filter {
            HistoryFilters.looseRecordingMatches($0, type: filterOptions.activeType, tag: filterOptions.activeTag)
        }
    }

    /// Force mode shows every recording (grouped + loose), filtered.
    private var filteredForceRecordings: [TindeqRecording] {
        queryFilteredRecordings.filter {
            HistoryFilters.looseRecordingMatches($0, type: filterOptions.activeType, tag: filterOptions.activeTag)
        }
    }

    private var timelineItems: [HistoryTimelineItem] {
        HistoryTimeline.combinedItems(sessions: filteredSessions, recordings: filteredLooseRecordings)
    }

    private var remainingCount: Int { timelineItems.count - visibleCount }

    private var tindeqSessions: [SendmeterCore.Session] {
        model.sessions.filter { $0.type == "tindeq" && $0.groupID != nil && !$0.pending }
    }

    private var sessionGroupIDs: Set<UUID> {
        Set(model.sessions.compactMap(\.groupID))
    }

    private var searchPrompt: String {
        switch mode {
        case .all: return "Search history"
        case .sessions: return "Search sessions"
        case .force: return "Search force recordings"
        }
    }

    // MARK: Body

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

                uploadBanner
                filterChips

                switch mode {
                case .all:
                    combinedList
                case .sessions:
                    sessionsList
                case .force:
                    forceList
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("History")
            .searchable(text: $query, prompt: searchPrompt)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // #656: a tap opening a sheet arms the presentation
                        // tick.
                        Haptics.shared.tap()
                        showingTrash = true
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
            }
            .refreshable { await model.refreshAll(showSpinner: false) }
            .sheet(item: $editingSession, onDismiss: { Haptics.shared.sheetDismissed() }) { session in
                SessionEditorSheet(session: session)
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showingTrash, onDismiss: { Haptics.shared.sheetDismissed() }) {
                TrashView()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $assignOpen, onDismiss: { Haptics.shared.sheetDismissed() }) {
                SelectionAssignSheet(recordings: selectedRecordings)
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                selectionBar
            }
            .onChange(of: mode) { _ in
                visibleCount = HistoryPaging.pageSize
                selectedIDs = []
                createError = nil
            }
            .onChange(of: filterOptions.activeType) { value in
                if value == nil { selectedType = nil }
                pruneSelectionToVisible()
            }
            .onChange(of: filterOptions.activeTag) { value in
                if value == nil { selectedTag = nil }
                pruneSelectionToVisible()
            }
            .onChange(of: query) { _ in
                pruneSelectionToVisible()
            }
        }
    }

    private var selectedRecordings: [TindeqRecording] {
        filteredLooseRecordings.filter { selectedIDs.contains($0.id) }
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// A filter/search change can hide a ticked recording without unticking
    /// it — prune the selection to what still shows, so a bulk action never
    /// silently includes a row the user can no longer see (web
    /// `pruneSelectionToVisible`).
    private func pruneSelectionToVisible() {
        guard !selectedIDs.isEmpty else { return }
        let pruned = HistoryFilters.pruneSelection(
            selectedIDs,
            toVisible: filteredLooseRecordings,
            type: filterOptions.activeType,
            tag: filterOptions.activeTag
        )
        if pruned != selectedIDs { selectedIDs = pruned }
    }

    private func createSessionFromSelection() async {
        let selected = selectedRecordings
        guard !selected.isEmpty else {
            selectedIDs = []
            return
        }
        createError = nil
        let ok = await model.createSessionFromRecordings(selected)
        creating = false
        if ok {
            selectedIDs = []
        } else {
            createError = "Couldn't create session — try again."
        }
    }

    // MARK: Lists

    private var combinedList: some View {
        Group {
            if timelineItems.isEmpty {
                HistoryEmptyState(
                    title: model.sessions.isEmpty && model.recordings.isEmpty
                        ? "No history yet"
                        : "No history matches these filters",
                    description: "Log a session, complete a workout, or save a pull to build your training history.",
                    symbol: "calendar.badge.plus"
                )
            } else {
                List {
                    ForEach(combinedSections, id: \.date) { section in
                        Section(section.date) {
                            ForEach(section.items) { item in
                                row(for: item)
                            }
                        }
                    }
                    loadMoreRow
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var sessionsList: some View {
        Group {
            if filteredSessions.isEmpty {
                HistoryEmptyState(
                    title: "No sessions yet",
                    description: "Log a session or complete a workout to build your training history.",
                    symbol: "calendar.badge.plus"
                )
            } else {
                List {
                    ForEach(sessionSections, id: \.date) { section in
                        Section(section.date) {
                            ForEach(section.items) { session in
                                sessionRow(session)
                            }
                        }
                    }
                    if filteredSessions.count > visibleCount {
                        Section {
                            Button {
                                visibleCount += HistoryPaging.pageSize
                            } label: {
                                loadMoreLabel(total: filteredSessions.count)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var forceList: some View {
        Group {
            if filteredForceRecordings.isEmpty {
                HistoryEmptyState(
                    title: "No force recordings yet",
                    description: "Connect a Progressor in Force and save a pull.",
                    symbol: "waveform.path.ecg"
                )
            } else {
                List {
                    ForEach(Array(filteredForceRecordings.prefix(visibleCount))) { recording in
                        recordingRow(recording)
                    }
                    if filteredForceRecordings.count > visibleCount {
                        Section {
                            Button {
                                visibleCount += HistoryPaging.pageSize
                            } label: {
                                loadMoreLabel(total: filteredForceRecordings.count)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var pagedItems: [HistoryTimelineItem] {
        Array(timelineItems.prefix(visibleCount))
    }

    private var combinedSections: [(date: String, items: [HistoryTimelineItem])] {
        groupedByDate(pagedItems.map { ($0.date, $0) })
    }

    private var sessionSections: [(date: String, items: [SendmeterCore.Session])] {
        groupedByDate(Array(filteredSessions.prefix(visibleCount)).map { ($0.date, $0) })
    }

    private func groupedByDate<Item>(_ pairs: [(date: String, item: Item)]) -> [(date: String, items: [Item])] {
        let grouped = Dictionary(grouping: pairs, by: \.date).mapValues { $0.map(\.item) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if remainingCount > 0 {
            Section {
                Button {
                    visibleCount += HistoryPaging.pageSize
                } label: {
                    loadMoreLabel(total: timelineItems.count)
                }
            }
        }
    }

    private func loadMoreLabel(total: Int) -> some View {
        Text(
            "Load \(min(HistoryPaging.pageSize, total - visibleCount)) more · "
                + "\(total - visibleCount) older"
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(for item: HistoryTimelineItem) -> some View {
        switch item {
        case let .session(session): sessionRow(session)
        case let .recording(recording): recordingRow(recording)
        }
    }

    // MARK: Rows

    private func isExpandable(_ session: SendmeterCore.Session) -> Bool {
        (session.type == "tindeq" && session.groupID != nil) || session.workoutSource != nil
    }

    private func zoneMix(for session: SendmeterCore.Session) -> [ZoneQuality: Double]? {
        guard session.type == "tindeq", let groupID = session.groupID else { return nil }
        return ZoneMix.zoneSets(recordingsByGroup[groupID] ?? [])
    }

    private func zone(for session: SendmeterCore.Session) -> ZoneQuality? {
        guard let mix = zoneMix(for: session) else { return nil }
        return ZoneMix.dominantZone(mix)
    }

    @ViewBuilder
    private func sessionRow(_ session: SendmeterCore.Session) -> some View {
        let row = HistorySessionRow(
            session: session,
            zone: zone(for: session),
            zoneMix: zoneMix(for: session)
        )
        if isExpandable(session) {
            NavigationLink {
                SessionDetailView(session: session)
            } label: {
                row
            }
            .hapticButtonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { delete(session) } label: {
                    Label("Trash", systemImage: "trash")
                }
                Button {
                    // #656: a tap opening a sheet arms the presentation tick.
                    Haptics.shared.tap()
                    editingSession = session
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(SendmeterStyle.primary)
            }
        } else {
            Button {
                // #656: a tap opening a sheet arms the presentation tick —
                // inside the action, the same mechanism as every other site
                // (review F13 — no second gesture recognizer).
                Haptics.shared.tap()
                editingSession = session
            } label: {
                row
            }
            .hapticButtonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { delete(session) } label: {
                    Label("Trash", systemImage: "trash")
                }
                Button {
                    // #656: a tap opening a sheet arms the presentation tick.
                    Haptics.shared.tap()
                    editingSession = session
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(SendmeterStyle.primary)
            }
        }
    }

    private func delete(_ session: SendmeterCore.Session) {
        // #656: a confirmed destructive action fires the medium tick once per
        // gesture (the swipe-action trash tap or the confirmation dialog's).
        Haptics.shared.playGesture(.medium)
        Task { await model.deleteSession(session) }
    }

    private func delete(_ recording: TindeqRecording) {
        // #656: see `delete(_ session:)`.
        Haptics.shared.playGesture(.medium)
        Task { await model.deleteRecording(recording) }
    }

    @ViewBuilder
    private func recordingRow(_ recording: TindeqRecording) -> some View {
        let isLoose = recording.groupID == nil
            || !sessionGroupIDs.contains(recording.groupID!)
        NavigationLink {
            ForceRecordingDetailView(recording: recording)
        } label: {
            HistoryRecordingRow(
                recording: recording,
                tickVisible: isLoose && mode != .sessions,
                ticked: selectedIDs.contains(recording.id),
                toggleTick: { toggleSelect(recording.id) }
            )
        }
        .hapticButtonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { delete(recording) } label: {
                Label("Trash", systemImage: "trash")
            }
        }
    }

    // MARK: Upload warning banner (#630-6)

    private var uploadBanner: some View {
        let phonePending = model.queuedWriteCount
        // #675 F8: `quarantinedWrites == nil` means "the queue has not been
        // read yet this session" — collapsing it to 0 would render an unknown
        // state as "nothing quarantined" (#269 honest-states rule). The
        // unknown state never shows the banner (there is nothing actionable
        // yet); once read, `[]` means genuinely nothing quarantined.
        let phoneQuarantined = model.quarantinedWrites?.count ?? -1
        let quarantineUnknown = phoneQuarantined < 0
        let watchPending = model.watch.pendingSyncCount ?? 0
        // A banner is shown only when it has something actionable: a real
        // pending count, or a CONFIRMED (non-nil) quarantined count > 0.
        // Unknown quarantine must not show as empty and must not fabricate a
        // banner either.
        if phonePending > 0 || watchPending > 0 || (phoneQuarantined > 0 && !quarantineUnknown) {
            return AnyView(
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .foregroundStyle(SendmeterStyle.caution)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(uploadTitle(phone: phonePending, watch: watchPending, quarantined: phoneQuarantined))
                            .font(.subheadline.weight(.semibold))
                        Text(uploadMessage(phone: phonePending, watch: watchPending, quarantined: phoneQuarantined))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        retryingUploads = true
                        Task {
                            await model.retryAllQueuedWrites()
                            // #675: the banner also surfaces quarantined items
                            // ("rejected, not retrying"), so its one Retry
                            // action re-attempts those too — the web's History
                            // "Retry now" covers stuck entries the same way.
                            await model.retryQuarantinedWrites()
                            retryingUploads = false
                        }
                    } label: {
                        if retryingUploads { ProgressView() } else { Text("Retry") }
                    }
                    .hapticButtonStyle(.bordered)
                    .disabled(retryingUploads)
                }
                .padding(12)
                .background(SendmeterStyle.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 4)
            )
        }
        return AnyView(EmptyView())
    }

    /// #675 F8: "Uploads waiting" only when something is actually waiting to
    /// upload. A quarantined item is NOT waiting to upload — it was rejected
    /// and won't retry on its own — so a banner whose only entries are
    /// quarantined reads honestly: "Rejected uploads", not "Uploads waiting".
    private func uploadTitle(phone: Int, watch: Int, quarantined: Int) -> String {
        let hasWaiting = phone > 0 || watch > 0
        let hasQuarantined = quarantined > 0
        if hasWaiting {
            return "Uploads waiting"
        }
        if hasQuarantined {
            return "Rejected uploads"
        }
        return "Uploads waiting"
    }

    private func uploadMessage(phone: Int, watch: Int, quarantined: Int) -> String {
        var parts: [String] = []
        if phone > 0 { parts.append("\(phone) queued on this iPhone") }
        if watch > 0 { parts.append("\(watch) on your watch") }
        if quarantined > 0 {
            parts.append("\(quarantined) rejected, not retrying")
        }
        if parts.isEmpty {
            return "The server rejected these; they are kept on this device and never retried on their own — manage them in Settings."
        }
        return parts.joined(separator: " · ") + ". Queued data is durable on device and retries automatically; rejected items never retry on their own — manage them in Settings."
    }

    // MARK: Filter chips (#630-4)

    @ViewBuilder
    private var filterChips: some View {
        if !filterOptions.types.isEmpty || !filterOptions.tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !filterOptions.types.isEmpty {
                    chipRow(
                        label: "Session type",
                        allLabel: "All types",
                        options: filterOptions.types.map { ($0.id, $0.label) },
                        active: filterOptions.activeType,
                        select: { selectedType = $0 }
                    )
                }
                if !filterOptions.tags.isEmpty {
                    chipRow(
                        label: "Force tag",
                        allLabel: "All tags",
                        options: filterOptions.tags.map { ($0, $0) },
                        active: filterOptions.activeTag,
                        select: { selectedTag = $0 }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }

    private func chipRow(
        label: String,
        allLabel: String,
        options: [(String, String)],
        active: String?,
        select: @escaping (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    HistoryFilterChip(title: allLabel, isActive: active == nil) { select(nil) }
                    ForEach(options, id: \.0) { option in
                        HistoryFilterChip(title: option.1, isActive: active == option.0) {
                            select(option.0)
                        }
                    }
                }
            }
        }
    }

    // MARK: Multi-select action bar (#630-2)

    @ViewBuilder
    private var selectionBar: some View {
        if !selectedIDs.isEmpty {
            VStack(spacing: 8) {
                if let createError {
                    Text(createError)
                        .font(.caption)
                        .foregroundStyle(SendmeterStyle.alert)
                }
                HStack(spacing: 12) {
                    Button {
                        creating = true
                        Task { await createSessionFromSelection() }
                    } label: {
                        HStack(spacing: 8) {
                            if creating { ProgressView().tint(.white) }
                            Text(creating ? "Creating…" : "New session (\(selectedIDs.count))")
                        }
                    }
                    .hapticButtonStyle(PrimaryActionButtonStyle())
                    .disabled(creating)
                    if !tindeqSessions.isEmpty {
                        Button {
                            // #656: a tap opening a sheet arms the
                            // presentation tick.
                            Haptics.shared.tap()
                            assignOpen = true
                        } label: { Text("Assign…") }
                            .hapticButtonStyle(.bordered)
                            .disabled(creating)
                    }
                    Button { selectedIDs = [] } label: { Text("Cancel") }
                        .hapticButtonStyle(.bordered)
                        .disabled(creating)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }
}

/// Lazy paging constants (web `PAGE_SIZE`).
enum HistoryPaging {
    static let pageSize = 40
}

private struct HistorySessionRow: View {
    let session: SendmeterCore.Session
    let zone: ZoneQuality?
    let zoneMix: [ZoneQuality: Double]?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    zone != nil
                        ? SendmeterStyle.zoneColor(zone!)
                        : SendmeterStyle.phaseColor(session.phase)
                )
                .frame(width: 5, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(session.typeLabel)
                        .font(.headline)
                    if let zone {
                        ZoneBadge(zone: zone, mix: zoneMix)
                    }
                    if session.pending {
                        // #675 F1: a restored quarantined placeholder reads
                        // "Rejected", never "Pending"/"Syncing" — it will NOT
                        // upload on its own and the user should manage it in
                        // Settings, not wait.
                        StatusPill(
                            session.rejected ? "Rejected" : "Pending",
                            color: session.rejected ? SendmeterStyle.alert : SendmeterStyle.caution
                        )
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

private struct HistoryRecordingRow: View {
    let recording: TindeqRecording
    let tickVisible: Bool
    let ticked: Bool
    let toggleTick: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if tickVisible {
                Button(action: toggleTick) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(ticked ? SendmeterStyle.primary : .secondary)
                }
                .hapticButtonStyle(.plain)
                .accessibilityLabel(ticked ? "Untick recording" : "Tick recording")
            }
            Image(systemName: recording.protocolMode == .reverseAction ? "arrow.left.and.right.circle.fill" : "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(SendmeterStyle.primary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(recording.tag.isEmpty ? "Untitled pull" : recording.tag)
                        .font(.headline)
                    // #675 F1: a restored quarantined placeholder reads
                    // "Rejected", never silently "syncing" — it won't upload
                    // on its own.
                    if recording.rejected {
                        StatusPill("Rejected", color: SendmeterStyle.alert)
                    }
                }
                HStack(spacing: 7) {
                    Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    if recording.side != .unspecified { Text(recording.side.label) }
                    if let zone = recording.zone { Text(zone.displayLabel) }
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
        .contentShape(Rectangle())
    }
}

private struct HistoryFilterChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .background(
                    isActive ? SendmeterStyle.primary : Color.secondary.opacity(0.1),
                    in: Capsule()
                )
        }
        .hapticButtonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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

/// Shared with `SessionDetailView`'s per-recording rows, so it stays
/// internal (not `private`).
struct ForceRecordingDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var recording: TindeqRecording
    @State private var samples: [TindeqSample] = []
    @State private var loadingSamples = false
    @State private var isSaving = false
    /// Nil means the user is editing only recording metadata. Once the
    /// linked session's slider is touched, this becomes the RPE PATCH value.
    @State private var editedSessionRPE: Double?
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
                        if let linkedSession {
                            SectionLabel("Session effort", systemImage: "gauge")
                            HStack {
                                Text("RPE")
                                Slider(
                                    value: Binding(
                                        get: { editedSessionRPE ?? linkedSession.rpe },
                                        set: { editedSessionRPE = $0 }
                                    ),
                                    in: 1...10,
                                    step: 0.5
                                )
                                Text((editedSessionRPE ?? linkedSession.rpe).formatted(.number.precision(.fractionLength(0...1))))
                                    .monospacedDigit()
                                    .frame(width: 34)
                            }
                            Text("RPE is stored on the linked session and changing it confirms the effort review.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label(
                            "Raw force samples are immutable; this editor changes metadata only.",
                            systemImage: "lock"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button {
                            isSaving = true
                            Task {
                                await model.updateRecording(
                                    recording,
                                    sessionRPE: linkedSession == nil ? nil : editedSessionRPE
                                )
                                isSaving = false
                            }
                        } label: {
                            HStack {
                                if isSaving { ProgressView().tint(.white) }
                                Text("Save Changes")
                            }
                        }
                        .hapticButtonStyle(PrimaryActionButtonStyle())
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
                    // #656: a tap opening a sheet arms the presentation tick.
                    Haptics.shared.tap()
                    showingLinkSheet = true
                } label: {
                    Label(
                        recording.groupID == nil ? "Link to Session" : "Linked to Session",
                        systemImage: recording.groupID == nil ? "link.badge.plus" : "link.circle.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .hapticButtonStyle(.bordered)
                .disabled(recording.groupID != nil)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(recording.tag.isEmpty ? "Force Recording" : recording.tag)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSamples()
        }
        .sheet(isPresented: $showingLinkSheet, onDismiss: { Haptics.shared.sheetDismissed() }) {
            LinkRecordingSheet(recordings: [recording])
                .onAppear { Haptics.shared.sheetPresented() }
        }
    }

    private var targetRange: ClosedRange<Double>? {
        guard let low = recording.targetLowKilograms,
              let high = recording.targetHighKilograms else { return nil }
        return low...high
    }

    private var linkedSession: SendmeterCore.Session? {
        guard let groupID = recording.groupID else { return nil }
        return model.sessions.first { $0.groupID == groupID && !$0.pending }
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
    let recordings: [TindeqRecording]

    var body: some View {
        NavigationStack {
            List(model.sessions.filter { !$0.pending }.prefix(100)) { session in
                Button {
                    Task {
                        await model.linkRecordings(recordings, to: session)
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
                .hapticButtonStyle(.plain)
            }
            .navigationTitle(recordings.count > 1 ? "Assign \(recordings.count) recordings" : "Link to Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// #630: the multi-select assign sheet — move ticked recordings into an
/// existing Tindeq session, mirroring the web's Assign sheet.
private struct SelectionAssignSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let recordings: [TindeqRecording]

    var body: some View {
        NavigationStack {
            List(model.sessions.filter { $0.type == "tindeq" && $0.groupID != nil && !$0.pending }.prefix(100)) { session in
                Button {
                    Task {
                        await model.linkRecordings(recordings, to: session)
                        dismiss()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(session.date) · \(session.durationMinutes)min · RPE \(session.rpe.formatted(.number.precision(.fractionLength(0...1))))")
                            .font(.headline)
                        if !session.note.isEmpty {
                            Text(session.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .hapticButtonStyle(.plain)
            }
            .navigationTitle("Assign \(recordings.count) recording\(recordings.count == 1 ? "" : "s")")
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
                                Button {
                                    Haptics.shared.playGesture(.light)
                                    Task { await model.restoreSession(session) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    Haptics.shared.playGesture(.medium)
                                    sessionToPurge = session
                                } label: {
                                    Label("Delete Permanently", systemImage: "trash.slash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .hapticTap()
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
                                Button {
                                    Haptics.shared.playGesture(.light)
                                    Task { await model.restoreRecording(recording) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    Haptics.shared.playGesture(.medium)
                                    recordingToPurge = recording
                                } label: {
                                    Label("Delete Permanently", systemImage: "trash.slash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .hapticTap()
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
                    // #656: a confirmed destructive action fires the medium
                    // tick once per gesture.
                    Haptics.shared.playGesture(.medium)
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
