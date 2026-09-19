import SendmeterCore
import SwiftUI

/// Exercise tag management (SL-92, web's `TagManagerSheet` parity, #631):
/// rename a tag across the whole dataset — every recording carrying it
/// follows — or hide it from the Force-tab picker and History force list
/// without deleting anything. Renaming into an existing tag merges the two
/// (the DB RPC repoints every recording; the surviving row's hidden state
/// wins).
struct TagManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editingName: String?
    @State private var draft = ""
    @State private var busy = false

    private var entries: [TagEntry] {
        model.tagEntries
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if entries.isEmpty {
                        Text("No exercises yet — record a rep with an exercise first.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(entries, id: \.name) { entry in
                            row(entry)
                        }
                    }
                } header: {
                    Text("Rename updates every recording with that exercise. Hiding keeps the data but drops the exercise from the pickers.")
                }
                if pendingTagChanges > 0 {
                    pendingChangesSection
                }
            }
            .navigationTitle("Manage Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// #920: this editor writes the tag registry, so it is the one surface that
    /// can name the registry's own unsynced changes. The wording and the retry
    /// availability come from the shared `MutationSyncStatus` — never from a
    /// local count that can disagree with Settings.
    private var pendingTagChanges: Int { model.pendingTagWriteCount }

    private var syncStatus: MutationSyncStatus { model.mutationSyncStatus }

    @ViewBuilder
    private var pendingChangesSection: some View {
        Section {
            Text(pendingChangesSummary)
                .font(.subheadline)
                .accessibilityIdentifier("tag-pending-status")
            switch syncStatus.retry {
            case .ready, .inFlight:
                Button {
                    Task { await model.retryAllQueuedWrites() }
                } label: {
                    HStack {
                        Label("Retry Now", systemImage: "arrow.clockwise")
                        Spacer()
                        if case .inFlight = syncStatus.retry { ProgressView() }
                    }
                }
                .disabled(syncStatus.retry != .ready)
                .accessibilityIdentifier("tag-pending-retry")
            case .unavailable(.noUploadPath):
                // #920 AC2: a residue a retry cannot move explains itself here
                // instead of offering a button that does nothing.
                Text(syncStatus.retryUnavailableExplanation ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tag-pending-blocked")
            case .hidden, .unavailable(.nothingPending):
                // The queue has not been read yet (or has nothing this retry
                // reaches): no control until the answer exists.
                EmptyView()
            }
        } header: {
            Text("Not uploaded yet")
        }
    }

    private var pendingChangesSummary: String {
        let noun = "exercise change\(pendingTagChanges == 1 ? "" : "s")"
        if case .unavailable(.noUploadPath) = syncStatus.retry {
            return "\(pendingTagChanges) \(noun) can’t be uploaded by this app version."
        }
        switch syncStatus.state {
        case .notLoaded:
            return "\(pendingTagChanges) \(noun) on this iPhone — checking whether the server has them."
        default:
            return "\(pendingTagChanges) \(noun) saved on this iPhone and not uploaded yet."
        }
    }

    @ViewBuilder
    private func row(_ entry: TagEntry) -> some View {
        if editingName == entry.name {
            HStack(spacing: 10) {
                TextField("Exercise name", text: $draft)
                    .textInputAutocapitalization(.sentences)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                Button {
                    commitRename(from: entry.name)
                } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    editingName = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .disabled(busy)
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.headline)
                        if entry.hidden {
                            Text("hidden")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(entry.count) rep\(entry.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sideModePicker(entry)
                }
                Spacer()
                Button {
                    editingName = entry.name
                    draft = entry.name
                } label: {
                    Image(systemName: "pencil")
                }
                .disabled(busy)
                Button {
                    toggleHidden(entry)
                } label: {
                    Text(entry.hidden ? "Show" : "Hide")
                        .fontWeight(.medium)
                }
                .disabled(busy)
            }
        }
    }

    /// The per-exercise side-mode picker (#720): the selected mode drives the
    /// Force tab's side selector. Choices come from `ExerciseSideMode.allCases`,
    /// never a per-view mapping.
    private func sideModePicker(_ entry: TagEntry) -> some View {
        HStack(spacing: 8) {
            Text("Side")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Side", selection: sideModeBinding(entry)) {
                ForEach(ExerciseSideMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .disabled(busy)
        }
        .padding(.top, 2)
    }

    private func sideModeBinding(_ entry: TagEntry) -> Binding<ExerciseSideMode> {
        Binding(
            get: { model.sideMode(for: entry.name) },
            set: { model.setTagSideMode(name: entry.name, mode: $0) }
        )
    }

    private func commitRename(from oldName: String) {
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingName = nil
        guard !next.isEmpty, next != oldName else { return }
        busy = true
        Task {
            await model.renameTag(oldName: oldName, newName: next)
            busy = false
        }
    }

    private func toggleHidden(_ entry: TagEntry) {
        busy = true
        Task {
            await model.setTagHidden(name: entry.name, hidden: !entry.hidden)
            busy = false
        }
    }
}
