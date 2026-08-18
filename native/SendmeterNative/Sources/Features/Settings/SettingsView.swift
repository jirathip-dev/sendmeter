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
    @State private var retryingQuarantined = false
    @State private var discardConfirmation: QuarantinedWrite?

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
            .sheet(isPresented: $showingBlocks) {
                PhasesView()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showingExercises) {
                TagManagerView()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showingDeleteAccount) {
                DeleteAccountSheet()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .confirmationDialog(
                signOutRemainderTitle,
                isPresented: signOutRemainderBinding,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    // #656: a confirmed destructive action carries the medium
                    // tick — once per gesture (the dialog's confirm tap).
                    Haptics.shared.play(.medium)
                    model.resolveSignOutRemainder(.signOut)
                }
                Button("Stay Signed In", role: .cancel) {
                    model.resolveSignOutRemainder(.cancel)
                }
            } message: {
                Text(signOutRemainderMessage)
            }
            .confirmationDialog(
                "Discard quarantined \(discardConfirmation?.kind.lowercased() ?? "item")?",
                isPresented: discardConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    if let item = discardConfirmation {
                        Task { await model.discardQuarantinedWrite(id: item.id) }
                    }
                    discardConfirmation = nil
                }
                Button("Keep", role: .cancel) { discardConfirmation = nil }
            } message: {
                Text("This permanently deletes the unsynced \(discardConfirmation?.kind.lowercased() ?? "item") from this device. The server never received it, so it cannot be recovered after this.")
            }
        }
    }

    /// #675: the quarantine discard is a per-item confirmation — a quarantined
    /// item is user training data the server never accepted, and the honest
    /// prompt must say exactly what goes away (mirrors the web's destructive-
    /// action discipline; never an unconditional confirm on the whole list).
    private var discardConfirmationBinding: Binding<Bool> {
        Binding(
            get: { discardConfirmation != nil },
            set: { if !$0 { discardConfirmation = nil } }
        )
    }

    /// #632: the remainder prompt from the web's SignOutPendingSheet (#273),
    /// shown only when the pre-sign-out drain left queued writes behind — it
    /// is never an unconditional confirm. "Sign Out" keeps the remainder on
    /// device for this account's next sign-in; dismissing the dialog aborts
    /// the sign-out entirely (the binding's setter resolves `.cancel`).
    private var signOutRemainderBinding: Binding<Bool> {
        Binding(
            get: { model.signOutRemainderCount != nil },
            set: { if !$0 { model.resolveSignOutRemainder(.cancel) } }
        )
    }

    private var signOutRemainderTitle: String {
        let count = model.signOutRemainderCount ?? 0
        return "\(count) recording\(count == 1 ? "" : "s") not uploaded"
    }

    private var signOutRemainderMessage: String {
        let count = model.signOutRemainderCount ?? 0
        return count == 1
            ? "It's still waiting to reach the server — usually that means no connection. Signing out keeps it on this device; it uploads the next time this account signs in."
            : "They're still waiting to reach the server — usually that means no connection. Signing out keeps them on this device; they upload the next time this account signs in."
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
            Button {
                // #656: a tap opening a sheet arms the presentation tick.
                Haptics.shared.tap()
                showingBlocks = true
            } label: {
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
            Button {
                // #656: a tap opening a sheet arms the presentation tick.
                Haptics.shared.tap()
                showingExercises = true
            } label: {
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
                if let computedAt = metric.computedAt {
                    LabeledContent("Last computed", value: computedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                }
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
            // #675: the quarantine is its own honest state — never folded into
            // the pending count above, never hidden. `nil` (queue not read yet)
            // must not render as "nothing quarantined" (#269).
            if let quarantined = model.quarantinedWrites {
                if quarantined.isEmpty {
                    LabeledContent("Rejected uploads", value: "None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent(
                        "Rejected uploads",
                        value: "\(quarantined.count) — not retrying automatically"
                    )
                    .foregroundStyle(SendmeterStyle.alert)
                    Text("The server rejected these permanently. They are kept on this device and never retried on their own; retry them by hand if you believe they should upload now, or discard them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(quarantined) { item in
                        quarantineRow(item)
                    }
                    if quarantined.count > 1 {
                        Button {
                            retryingQuarantined = true
                            Task {
                                await model.retryQuarantinedWrites()
                                retryingQuarantined = false
                            }
                        } label: {
                            HStack {
                                Label("Retry All", systemImage: "arrow.clockwise")
                                Spacer()
                                if retryingQuarantined { ProgressView() }
                            }
                        }
                        .disabled(retryingQuarantined)
                    }
                }
            } else {
                LabeledContent("Rejected uploads", value: "Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// #675: one quarantined item — its kind + when it was rejected, and the
    /// two recoverability actions (retry by hand / discard). Per-item actions
    /// only for the explicit user path; the #273 sign-out and account-
    /// deletion flows keep their own removal rules. #675 F9: Discard is
    /// disabled while a retry is in flight — `retryQuarantined` clears the
    /// stamp before the upload starts, so a Discard tap in that window would
    /// silently no-op (`discardQuarantined` guards on `quarantined != nil`)
    /// after the user confirmed a destructive dialog.
    private func quarantineRow(_ item: QuarantinedWrite) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.kind)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(item.rejection.at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let code = item.rejection.code {
                LabeledContent("Server code", value: code)
                    .font(.caption)
            }
            if !item.rejection.detail.isEmpty {
                Text(item.rejection.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Button {
                    retryingQuarantined = true
                    Task {
                        await model.retryQuarantinedWrites(id: item.id)
                        retryingQuarantined = false
                    }
                } label: {
                    Text("Retry")
                }
                .buttonStyle(.bordered)
                .disabled(retryingQuarantined)
                Button(role: .destructive) {
                    discardConfirmation = item
                } label: {
                    Text("Discard")
                }
                .buttonStyle(.bordered)
                .disabled(retryingQuarantined)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
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
                // #656 (review F6): the issue names sign-out as a
                // confirm/destructive `.medium` action. The button is fully
                // enabled at the moment of the tap (it only disables while
                // `signOut()` is in flight), so the #222 "disabled fires
                // nothing" rule does not apply; the remainder dialog's tick
                // is an additional confirm only when the queue left writes.
                Haptics.shared.play(.medium)
                Task { await model.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(model.isSigningOut)
            Button(role: .destructive) {
                // #656: a tap opening a sheet arms the presentation tick.
                Haptics.shared.tap()
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
                        // #656: the confirmed destructive action fires the
                        // medium tick once per gesture.
                        Haptics.shared.play(.medium)
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
