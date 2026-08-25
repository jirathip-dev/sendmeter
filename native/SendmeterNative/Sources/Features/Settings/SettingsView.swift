@_spi(Experimental) import Auth
import SendmeterCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var theme: AppThemeController
    /// #722: the Metric/Imperial presentation preference, persisted via
    /// `AppUnits` (Core). This stores the preference only — the shared
    /// conversion layer (#721) that applies it across Force/readiness/weight
    /// display is future work, so no UI value reads it yet.
    @AppStorage(AppUnits.storageKey) private var unitsRaw = UnitsPreference.metric.rawValue
    @State private var showingBlocks = false
    @State private var showingExercises = false
    @State private var showingDeleteAccount = false
    @State private var syncingHealth = false
    @State private var registeringPasskey = false
    @State private var sendingReset = false
    @State private var retryingQueue = false
    @State private var retryingQuarantined = false
    @State private var discardConfirmation: QuarantinedWrite?
    /// #712: the passkey awaiting removal confirmation (server-side delete).
    @State private var pendingPasskeyRemoval: PasskeyListItem?
    /// #712: the passkey ids whose remove requests are in flight, so each row
    /// shows a spinner instead of a second tap target while it completes.
    /// A set (not a single `UUID?`) so finishing one removal can't clear
    /// another row's in-flight state (review F-blocking race on #712).
    @State private var removingPasskeyIDs: Set<UUID> = []
    /// #758/#757: raw diagnostic details stay behind an explicit support gate.
    /// Normal rows above show only friendly copy; expanding this is opt-in.
    @State private var showingTechnicalDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                generalSection
                trainingSection
                healthDevicesSection
                accountSecuritySection
                aboutSupportSection
                dangerZoneSection
            }
            .navigationTitle("Settings")
            .refreshable {
                model.watch.refreshPairingState()
                await model.refreshAll(showSpinner: false)
                // #712: a pull-to-refresh on Settings also re-lists passkeys.
                await model.loadPasskeys()
            }
            .task {
                // #712: load the passkey list when Settings opens, so the
                // count/rows are fresh without waiting for a manual refresh.
                await model.loadPasskeys()
            }
            .sheet(isPresented: $showingBlocks, onDismiss: { Haptics.shared.sheetDismissed() }) {
                PhasesView()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showingExercises, onDismiss: { Haptics.shared.sheetDismissed() }) {
                TagManagerView()
                    .onAppear { Haptics.shared.sheetPresented() }
            }
            .sheet(isPresented: $showingDeleteAccount, onDismiss: { Haptics.shared.sheetDismissed() }) {
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
                    Haptics.shared.playGesture(.medium)
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
            .confirmationDialog(
                "Remove passkey?",
                isPresented: pendingPasskeyRemovalBinding,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let passkey = pendingPasskeyRemoval {
                        // #656: a confirmed destructive action carries the
                        // medium tick — once per gesture (the dialog's
                        // confirm tap).
                        Haptics.shared.playGesture(.medium)
                        removingPasskeyIDs.insert(passkey.id)
                        Task {
                            await model.removePasskey(passkey.id)
                            removingPasskeyIDs.remove(passkey.id)
                        }
                    }
                    pendingPasskeyRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingPasskeyRemoval = nil }
            } message: {
                Text("This deletes the passkey from your account. You'll need to register it again to use it as a sign-in method.")
            }
        }
    }

    /// #712: the removal prompt is per-passkey, mirroring the quarantine
    /// discard — never an unconditional confirm on the whole list.
    private var pendingPasskeyRemovalBinding: Binding<Bool> {
        Binding(
            get: { pendingPasskeyRemoval != nil },
            set: { if !$0 { pendingPasskeyRemoval = nil } }
        )
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

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Picker("Units", selection: unitsBinding) {
                ForEach(UnitsPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            Text("Metric (kg) or Imperial (lb). Applies to body weight; Force and load units come later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Appearance", selection: Binding(
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

    private var unitsBinding: Binding<UnitsPreference> {
        Binding(
            get: { UnitsPreference(rawValue: unitsRaw) ?? .metric },
            set: { unitsRaw = $0.rawValue }
        )
    }

    // MARK: Training

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
            .hapticButtonStyle(SwiftUI.PlainButtonStyle())
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
            .hapticButtonStyle(SwiftUI.PlainButtonStyle())
            LabeledContent("Sessions", value: "\(model.sessions.count)")
            LabeledContent("Force recordings", value: "\(model.recordings.count)")
            LabeledContent("Guided protocols", value: "\(model.presets.count)")
            LabeledContent("Routines", value: "\(model.routines.count)")
        }
    }

    // MARK: Health & Devices

    private var healthDevicesSection: some View {
        Section("Health & Devices") {
            healthSubheader("Apple Health", systemImage: "heart.fill")
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
                if let weightKg = metric.bodyMassKilograms {
                    // #721: the first surface that consumes the shared
                    // conversion layer. Canonical storage stays kg; the value
                    // is only formatted for the chosen Metric/Imperial unit.
                    LabeledContent("Weight", value: MassFormatting.storedFormatted(weightKg))
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
            if let syncedAt = model.lastHealthSyncedAt {
                LabeledContent(
                    "Last synced",
                    value: syncedAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.caption)
            } else {
                Text("Apple Health has not synced yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.lastHealthSyncObservation == .failed {
                Text("The last Apple Health refresh failed; the previous reading is kept.")
                    .font(.caption)
                    .foregroundStyle(SendmeterStyle.caution)
            } else if model.lastHealthSyncObservation == .noSourceData {
                Text("The last check found no Apple Health source data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.lastHealthSyncObservation == .noNewData {
                Text("The last check found no new health days.")
                    .font(.caption)
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

            healthSubheader("Apple Watch", systemImage: "applewatch")
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
            if let unscoped = model.watch.unscopedSyncCount, unscoped > 0 {
                HStack {
                    Label("Legacy watch items", systemImage: "questionmark.folder.fill")
                        .foregroundStyle(SendmeterStyle.caution)
                    Spacer()
                    Text("\(unscoped)").monospacedDigit()
                }
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
            healthSubheader("Progressor", systemImage: "gauge.medium")
            HStack {
                Label("Device", systemImage: "bolt.horizontal.fill")
                Spacer()
                StatusPill(progressorStatus.text, color: progressorStatus.color)
            }
            if model.tindeq.lowBattery {
                HStack {
                    Label("Low battery", systemImage: "battery.25")
                        .foregroundStyle(SendmeterStyle.alert)
                    Spacer()
                    Text("Charge the Progressor").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func healthSubheader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var progressorStatus: (text: String, color: Color) {
        switch model.tindeq.status {
        case .connected: return ("Ready", SendmeterStyle.optimal)
        case .measuring: return ("Live", SendmeterStyle.primary)
        case .scanning, .connecting: return ("Working", SendmeterStyle.caution)
        case .interrupted: return ("Interrupted", SendmeterStyle.alert)
        case .unavailable: return ("Unavailable", SendmeterStyle.alert)
        case .idle: return ("Offline", .secondary)
        }
    }

    // MARK: Account & Security

    private var accountSecuritySection: some View {
        Section("Account & Security") {
            LabeledContent("Email", value: model.currentUserEmail ?? "Signed in")
            Button {
                // #656: a tap arming a password reset ticks once.
                Haptics.shared.tap()
                sendingReset = true
                Task {
                    await model.sendPasswordResetEmail()
                    sendingReset = false
                }
            } label: {
                HStack {
                    Label("Send Password Reset Email", systemImage: "key.fill")
                    Spacer()
                    if sendingReset { ProgressView() }
                }
            }
            .disabled(sendingReset)
            Text("We'll email a secure link that lets you set a new password.")
                .font(.caption)
                .foregroundStyle(.secondary)

            healthSubheader("Passkeys", systemImage: "person.badge.key.fill")
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
            // #712: the registered passkeys for the signed-in user — a live
            // count plus per-passkey removal, so a registration shows up as a
            // persistent entry (not just a transient toast).
            LabeledContent("Passkeys", value: "\(model.passkeys.count)")
            if model.passkeys.isEmpty {
                Text("No passkeys registered. Use “Register Passkey” to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.passkeys) { passkey in
                    passkeyRow(passkey)
                }
            }

            // #722: sign-out is a destructive session action and sits at the
            // bottom of this group, spatially apart from routine preferences
            // (Delete Account lives in its own Danger zone below).
            healthSubheader("Session", systemImage: "rectangle.portrait.and.arrow.right")
            Button(role: .destructive) {
                // #656 (review F6): the issue names sign-out as a
                // confirm/destructive `.medium` action. The button is fully
                // enabled at the moment of the tap (it only disables while
                // `signOut()` is in flight), so the #222 "disabled fires
                // nothing" rule does not apply; the remainder dialog's tick
                // is an additional confirm only when the queue left writes.
                Haptics.shared.playGesture(.medium)
                Task { await model.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(model.isSigningOut)
        }
    }

    /// #712: one registered passkey — friendly name, registration date, and a
    /// server-side remove (with confirmation). The remove button is
    /// `.borderless` so tapping it doesn't select the whole row.
    private func passkeyRow(_ passkey: PasskeyListItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(passkey.friendlyName ?? "Passkey")
                    .foregroundStyle(.primary)
                Text(passkey.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if removingPasskeyIDs.contains(passkey.id) {
                ProgressView()
            } else {
                Button(role: .destructive) {
                    // #656: arming a confirmation dialog ticks once per tap.
                    Haptics.shared.tap()
                    pendingPasskeyRemoval = passkey
                } label: {
                    Image(systemName: "trash")
                }
                .hapticButtonStyle(SwiftUI.BorderlessButtonStyle())
            }
        }
    }

    private var cacheSyncStatusText: String {
        if model.queuedWriteCount + model.pendingCacheWriteCount == 0 {
            return "Synced"
        }
        if model.queuedWriteCount == 0 {
            return "\(model.pendingCacheWriteCount) unsynced"
        }
        if model.pendingCacheWriteCount == 0 {
            return "\(model.queuedWriteCount) queued"
        }
        return "\(model.queuedWriteCount) queued, \(model.pendingCacheWriteCount) unsynced"
    }

    private var cacheSyncExplanation: String {
        if model.pendingCacheWriteCount == 0 {
            let verb = model.queuedWriteCount == 1 ? "is" : "are"
            return "\(model.queuedWriteCount) queued upload\(model.queuedWriteCount == 1 ? "" : "s") \(verb) kept on this iPhone and will retry automatically."
        }
        let changes = "\(model.pendingCacheWriteCount) unconfirmed local change\(model.pendingCacheWriteCount == 1 ? "" : "s")"
        if model.queuedWriteCount == 0 {
            return "\(changes) is kept on this iPhone and preserved on the next refresh rather than being hidden as clean."
        }
        let uploads = "\(model.queuedWriteCount) queued upload\(model.queuedWriteCount == 1 ? " is" : "s are")"
        return "\(changes) and \(uploads) kept on this iPhone. Queue entries retry automatically; cache-only changes are preserved on the next refresh rather than being hidden as clean."
    }

    private var activeQueueFailureExplanation: String? {
        guard let failure = model.latestQueuedWriteFailure else { return nil }
        let reason = failure.rejectionClass.map {
            UserFacingError.message(for: $0)
        } ?? "The last upload attempt failed."
        return "Last \(failure.kind.lowercased()) attempt: \(reason) The app will retry automatically; use Retry Now if needed."
    }

    // MARK: About & Support

    private var aboutSupportSection: some View {
        Section("About & Support") {
            healthSubheader("Version", systemImage: "info.circle")
            LabeledContent("Version", value: appVersion)

            healthSubheader("Data sync", systemImage: "externaldrive.badge.icloud")
            HStack {
                Label("Pending uploads", systemImage: "externaldrive.badge.icloud")
                Spacer()
                StatusPill(
                    cacheSyncStatusText,
                    color: model.queuedWriteCount + model.pendingCacheWriteCount == 0
                        ? SendmeterStyle.optimal
                        : SendmeterStyle.caution
                )
            }
            if model.queuedWriteCount + model.pendingCacheWriteCount > 0 {
                Text(cacheSyncExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let activeQueueFailureExplanation {
                    Text(activeQueueFailureExplanation)
                        .font(.caption)
                        .foregroundStyle(SendmeterStyle.alert)
                }
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
                Text("\(UserFacingError.message(forQueueBreadcrumbReason: breadcrumb.reason)) · \(breadcrumb.attempts) failed attempt\(breadcrumb.attempts == 1 ? "" : "s")")
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

            accountActivitySection
            if hasTechnicalDiagnostics {
                Button {
                    showingTechnicalDiagnostics.toggle()
                } label: {
                    Label(
                        showingTechnicalDiagnostics ? "Hide technical details" : "Show technical details",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .font(.caption)
                if showingTechnicalDiagnostics {
                    technicalDetailsSection
                }
            }
        }
    }

    /// #757: the normal path shows only a compact, user-facing summary of the
    /// on-device auth ring. The repetitive refresh/restore noise and the full
    /// bounded ring stay behind the technical-details gate below.
    @ViewBuilder
    private var accountActivitySection: some View {
        healthSubheader("Account activity", systemImage: "person.text.rectangle")
        let summary = AuthDiagnostics.summary(of: model.authEventLog)
        if summary.lastSignIn == nil, summary.lastFailure == nil {
            Text("No recent sign-in activity recorded on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if let lastSignIn = summary.lastSignIn {
                LabeledContent(
                    "Last sign-in",
                    value: lastSignIn.occurredAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.subheadline)
            }
            if let lastFailure = summary.lastFailure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SendmeterStyle.alert)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last problem")
                            .font(.subheadline.weight(.medium))
                        Text(UserFacingError.message(forDiagnosticDetail: lastFailure.detail ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(lastFailure.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var hasTechnicalDiagnostics: Bool {
        !model.authEventLog.isEmpty
            || model.currentUserID != nil
            || model.queuedWriteDiagnostics.contains {
                $0.lastError != nil || $0.rejectionClass != nil
            }
            || model.quarantinedWrites?.contains {
                $0.rejection.code != nil || !$0.rejection.detail.isEmpty
            } == true
    }

    /// The opt-in technical details for support. This is the only normal-path
    /// surface that may show raw server codes and diagnostics (#758 AC 3);
    /// the inline account-activity rows above intentionally stay friendly.
    private var technicalDetailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let userID = model.currentUserID {
                healthSubheader("Account", systemImage: "person.crop.circle")
                LabeledContent("User ID", value: userID.uuidString.lowercased())
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if let quarantined = model.quarantinedWrites {
                let rawQuarantined = quarantined.filter {
                    $0.rejection.code != nil || !$0.rejection.detail.isEmpty
                }
                if !rawQuarantined.isEmpty {
                    healthSubheader(
                        "Rejected-upload diagnostics",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    ForEach(rawQuarantined) { item in
                        quarantineDiagnosticsRow(item)
                    }
                }
            }
            let activeFailures = model.queuedWriteDiagnostics.filter {
                $0.lastError != nil || $0.rejectionClass != nil
            }
            if !activeFailures.isEmpty {
                healthSubheader(
                    "Queued-upload diagnostics",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                ForEach(activeFailures) { item in
                    queuedDiagnosticsRow(item)
                }
            }
            if !model.authEventLog.isEmpty {
                healthSubheader("Auth events", systemImage: "key")
                ForEach(model.authEventLog.reversed()) { entry in
                    authDiagnosticsRow(entry)
                }
            }
        }
    }

    private func quarantineDiagnosticsRow(_ item: QuarantinedWrite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(item.kind) · \(item.rejection.at.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let code = item.rejection.code {
                LabeledContent("Server code", value: code)
                    .font(.caption)
            }
            if !item.rejection.detail.isEmpty {
                Text(item.rejection.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func queuedDiagnosticsRow(_ item: QueuedWriteDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(item.kind) · \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let rejectionClass = item.rejectionClass {
                LabeledContent("Class", value: rejectionClass.rawValue)
                    .font(.caption)
            }
            LabeledContent(
                "Attempts",
                value: "\(item.attempts) (\(item.permanentAttempts) permanent)"
            )
            .font(.caption)
            LabeledContent(
                "Next retry",
                value: item.nextAttemptAt.formatted(date: .abbreviated, time: .shortened)
            )
            .font(.caption)
            if let lastError = item.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func authDiagnosticsRow(_ entry: AuthEventEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(authCategoryTitle(entry.category)) · \(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail = entry.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
            Text(UserFacingError.message(for: item.rejection))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
                .hapticButtonStyle(SwiftUI.BorderedButtonStyle())
                .disabled(retryingQuarantined)
                Button(role: .destructive) {
                    discardConfirmation = item
                } label: {
                    Text("Discard")
                }
                .hapticButtonStyle(SwiftUI.BorderedButtonStyle())
                .disabled(retryingQuarantined)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func authCategoryTitle(_ category: AuthEventCategory) -> String {
        switch category {
        case .signIn: return "Sign in"
        case .refresh: return "Refresh"
        case .signOut: return "Sign out"
        case .failure: return "Failure"
        }
    }

    // MARK: Danger zone

    /// #586 review F3 (web parity): destructive actions stay spatially apart
    /// from every routine preference above, at the very bottom of the surface.
    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                // #656: a tap opening a sheet arms the presentation tick.
                Haptics.shared.tap()
                showingDeleteAccount = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Delete Account", systemImage: "person.crop.circle.badge.minus")
                    Text("Permanently deletes your account and all server data. Cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("Opens a detailed warning before the delete step.")
        } header: {
            Label("Danger Zone", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SendmeterStyle.alert)
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
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gate = DeleteAccountConfirmationGate()
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            Group {
                switch gate.stage {
                case .warning:
                    deleteAccountWarningStep
                case .confirmation:
                    deleteAccountConfirmationStep
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(deleting)
                }
            }
        }
        .interactiveDismissDisabled(deleting)
    }

    private var deleteAccountWarningStep: some View {
        Form {
            Section {
                deleteAccountDangerBanner
            }
            Section("What this deletes") {
                Text("Your account and every piece of data stored for it on the server: workouts, training sessions, force recordings and curves, readiness and health history, presets, routines, tags, and settings.")
                    .font(.subheadline)
                Text("Uploads still waiting for this account are removed only after the server confirms account deletion.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    gate.advanceFromWarning()
                } label: {
                    Label("Continue to Confirmation", systemImage: "exclamationmark.triangle.fill")
                        .frame(maxWidth: .infinity)
                }
                .hapticButtonStyle(SwiftUI.BorderedButtonStyle())
                .tint(SendmeterStyle.alert)
                .accessibilityHint("Opens the separate type-to-confirm step.")
            }
        }
    }

    private var deleteAccountConfirmationStep: some View {
        Form {
            Section {
                deleteAccountDangerBanner
            }
            Section("Final confirmation") {
                Text("To continue, type \(DeleteAccountConfirmationGate.phrase) exactly. The delete button stays disabled until the phrase matches.")
                    .font(.subheadline)
                TextField("Type DELETE", text: Binding(
                    get: { gate.entry },
                    set: { gate.updateEntry($0) }
                ))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .accessibilityLabel("Confirmation phrase")
                .accessibilityHint("Type DELETE exactly to enable account deletion.")
            }
            Section {
                Button {
                    gate.backToWarning()
                } label: {
                    Label("Back to Warning", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .hapticButtonStyle(SwiftUI.BorderedButtonStyle())
                .disabled(deleting)
                .accessibilityHint("Returns to the warning step without deleting.")

                Button(role: .destructive) {
                    // #656: the confirmed destructive action fires the
                    // medium tick once per gesture. The control is disabled
                    // until the exact phrase matches, so a refused or disabled
                    // confirm can never tick.
                    Haptics.shared.playGesture(.medium)
                    deleting = true
                    Task {
                        await model.deleteAccount()
                        deleting = false
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if deleting { ProgressView() }
                        Label("Delete Account Permanently", systemImage: "trash.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .hapticButtonStyle(SwiftUI.BorderedButtonStyle())
                .tint(SendmeterStyle.alert)
                .disabled(!gate.canConfirm || deleting)
                .accessibilityHint(
                    gate.canConfirm
                        ? "Permanently deletes your account and all server data."
                        : "Type DELETE exactly to enable this button."
                )
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var deleteAccountDangerBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("This permanently deletes your account and all server data.")
                    .font(.subheadline.weight(.semibold))
                Text("This cannot be undone.")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(SendmeterStyle.alert)
        .padding(12)
        .background(
            SendmeterStyle.alert.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}
