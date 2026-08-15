import SendmeterCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppThemeController
    @State private var showingBlocks = false
    @State private var showingExercises = false
    @State private var showingDeleteAccount = false
    @State private var syncingHealth = false
    @State private var registeringPasskey = false
    @State private var retryingQueue = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                trainingSection
                healthSection
                watchSection
                queueSection
                appearanceSection
                appSection
                destructiveSection
            }
            .navigationTitle("Settings")
            .refreshable {
                model.watch.refreshPairingState()
                await model.refreshAll(showSpinner: false)
            }
            .sheet(isPresented: $showingBlocks) { PhasesView() }
            .sheet(isPresented: $showingExercises) { TagManagerView() }
            .sheet(isPresented: $showingDeleteAccount) { DeleteAccountSheet() }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Email", value: model.currentUserEmail ?? "Signed in")
            LabeledContent("User ID", value: model.currentUserID?.uuidString.lowercased() ?? "—")
                .font(.caption)
                .textSelection(.enabled)
            Button {
                registeringPasskey = true
                Task {
                    await model.registerPasskey()
                    registeringPasskey = false
                }
            } label: {
                HStack {
                    Label("Register Passkey", systemImage: "person.badge.key.fill")
                    Spacer()
                    if registeringPasskey { ProgressView() }
                }
            }
            .disabled(registeringPasskey)
        }
    }

    private var trainingSection: some View {
        Section("Training") {
            Button { showingBlocks = true } label: {
                HStack {
                    Label("Training Blocks", systemImage: "square.stack.3d.up.fill")
                    Spacer()
                    Text(model.currentPhase.name)
                        .foregroundStyle(SendmeterStyle.phaseColor(model.settings.currentPhase))
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            // #631: the exercise tag registry (SL-92) — rename a tag across
            // every recording, or hide it from the Force picker + History
            // list, without deleting anything.
            Button { showingExercises = true } label: {
                HStack {
                    Label("Exercises", systemImage: "tag")
                    Spacer()
                    Text("\(model.tagEntries.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            LabeledContent("Sessions", value: "\(model.sessions.count)")
            LabeledContent("Force recordings", value: "\(model.recordings.count)")
            LabeledContent("Guided protocols", value: "\(model.presets.count)")
            LabeledContent("Routines", value: "\(model.routines.count)")
        }
    }

    private var healthSection: some View {
        Section("Apple Health") {
            if let metric = model.readiness {
                HStack {
                    Label("Readiness", systemImage: "heart.text.square.fill")
                    Spacer()
                    Text(metric.readiness.map(String.init) ?? "—")
                        .font(.headline.monospacedDigit())
                    if let zone = metric.zone {
                        StatusPill(zone.capitalized, color: readinessColor(zone))
                    }
                }
                LabeledContent("Last computed", value: metric.computedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            } else {
                Text("Read HRV, resting heart rate, sleep, respiratory rate, and body mass to compute daily readiness on device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                syncingHealth = true
                Task {
                    await model.syncHealth(requestAuthorization: true)
                    syncingHealth = false
                }
            } label: {
                HStack {
                    Label(model.readiness == nil ? "Connect Apple Health" : "Sync Apple Health", systemImage: "heart.fill")
                    Spacer()
                    if syncingHealth { ProgressView() }
                }
            }
            .disabled(syncingHealth)
        }
    }

    private var watchSection: some View {
        Section("Apple Watch") {
            HStack {
                Label("Connection", systemImage: "applewatch")
                Spacer()
                StatusPill(watchStatus.text, color: watchStatus.color)
            }
            if let version = model.watch.watchVersion {
                LabeledContent(
                    "Watch version",
                    value: model.watch.watchBuild.map { "\(version) (\($0))" } ?? version
                )
            }
            if let pending = model.watch.pendingSyncCount {
                LabeledContent("Waiting to upload", value: "\(pending)")
            }
            if let quarantined = model.watch.quarantinedSyncCount, quarantined > 0 {
                HStack {
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SendmeterStyle.alert)
                    Spacer()
                    Text("\(quarantined)").monospacedDigit()
                }
            }
            if let stuck = model.watch.quarantinedStuckSyncCount, stuck > 0 {
                HStack {
                    Label("Stuck — retrying", systemImage: "arrow.clockwise")
                        .foregroundStyle(SendmeterStyle.alert)
                    Spacer()
                    Text("\(stuck)").monospacedDigit()
                }
            }
            Text("The phone relays access tokens only. Refresh tokens remain owned by the phone and are never copied to the Watch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var queueSection: some View {
        Section("On-device saves") {
            HStack {
                Label("Pending uploads", systemImage: "externaldrive.badge.icloud")
                Spacer()
                StatusPill(
                    model.queuedWriteCount == 0 ? "Synced" : "\(model.queuedWriteCount) queued",
                    color: model.queuedWriteCount == 0 ? SendmeterStyle.optimal : SendmeterStyle.caution
                )
            }
            if model.queuedWriteCount > 0 {
                Text("Queued data is already durable on this iPhone. It will retry automatically and is scoped to the signed-in account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    retryingQueue = true
                    Task {
                        await model.retryAllQueuedWrites()
                        retryingQueue = false
                    }
                } label: {
                    HStack {
                        Label("Retry Now", systemImage: "arrow.clockwise")
                        Spacer()
                        if retryingQueue { ProgressView() }
                    }
                }
                .disabled(retryingQueue)
            }
            if let breadcrumb = model.queueBreadcrumbs.first {
                LabeledContent("Most recent recovery", value: breadcrumb.leftQueueAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                Text("\(breadcrumb.reason) · \(breadcrumb.attempts) failed attempt\(breadcrumb.attempts == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { theme.choice },
                set: { theme.setChoice($0) }
            )) {
                ForEach(AppThemeChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            Text("System follows the device appearance. The choice is applied on launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appSection: some View {
        Section("App") {
            LabeledContent("Client", value: "Native SwiftUI")
            LabeledContent("Version", value: appVersion)
            LabeledContent("Database", value: "Supabase · shared production schema")
            Text("This target is independent from the Capacitor target, allowing side-by-side validation before any replacement decision.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var destructiveSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await model.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button(role: .destructive) {
                showingDeleteAccount = true
            } label: {
                Label("Delete Account", systemImage: "person.crop.circle.badge.minus")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var watchStatus: (text: String, color: Color) {
        if !model.watch.activated { return ("Starting", SendmeterStyle.caution) }
        if !model.watch.paired { return ("Not paired", .secondary) }
        if !model.watch.appInstalled { return ("App missing", SendmeterStyle.alert) }
        if model.watch.reachable { return ("Connected", SendmeterStyle.optimal) }
        return ("Paired", SendmeterStyle.primary)
    }

    private func readinessColor(_ zone: String) -> Color {
        switch zone.lowercased() {
        case "push": return SendmeterStyle.optimal
        case "maintain": return SendmeterStyle.caution
        default: return SendmeterStyle.alert
        }
    }
}

private struct DeleteAccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This permanently deletes the account and server data.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SendmeterStyle.alert)
                    Text("Queued writes owned by this account are removed only after the server confirms account deletion. This cannot be undone.")
                        .font(.subheadline)
                }
                Section("Confirmation") {
                    TextField("Type DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section {
                    Button(role: .destructive) {
                        deleting = true
                        Task {
                            await model.deleteAccount()
                            deleting = false
                            dismiss()
                        }
                    } label: {
                        HStack {
                            if deleting { ProgressView() }
                            Text("Delete Account Permanently")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(confirmation != "DELETE" || deleting)
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
