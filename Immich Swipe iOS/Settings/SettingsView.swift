import SwiftUI
import UniformTypeIdentifiers

/// Settings, laid out like the Android app: Appearance, Preferences, Reminder, Database, Debugging
/// (here: storage), About & Legal, Account.
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var model: SettingsModel
    @State private var reminders = ReminderScheduler()

    @AppStorage(Setting.Key.theme) private var theme = Setting.Default.theme
    @AppStorage(Setting.Key.includeArchived) private var includeArchived = Setting.Default.includeArchived
    @AppStorage(Setting.Key.playbackBehavior) private var playbackBehavior = Setting.Default.playbackBehavior
    @AppStorage(Setting.Key.reminderEnabled) private var reminderEnabled = Setting.Default.reminderEnabled
    @AppStorage(Setting.Key.reminderInterval) private var reminderInterval = Setting.Default.reminderInterval
    @AppStorage(Setting.Key.reminderCustomMinDays) private var customMinDays = Setting.Default.reminderCustomMinDays
    @AppStorage(Setting.Key.reminderCustomMaxDays) private var customMaxDays = Setting.Default.reminderCustomMaxDays

    private enum DatabaseAction { case export, delete }
    @State private var databaseAction: DatabaseAction?
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isConfirmingClearCache = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingRemoveAll = false
    @State private var accountToRemove: Account?

    init(model: SettingsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Form {
            appearance
            preferences
            reminder
            database
            storage
            about
            accountSection
        }
        .formStyle(.grouped)
        // The reminder's frequency and custom-day rows slide in and out as it's turned on or changed.
        .animation(.snappy, value: reminderEnabled)
        .animation(.snappy, value: reminderInterval)
        .navigationTitle("Settings")
        .task { await model.load() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { model.importBackup(from: $0) }
        .fileExporter(isPresented: $isExporting, document: model.exportDocument, contentType: .json, defaultFilename: model.exportFileName) {
            model.finishExport($0)
        }
        .alert("Immich Swipe", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        Section("Appearance") {
            Picker("App theme", selection: $theme) {
                Text("System").tag(AppTheme.system)
                Text("Light").tag(AppTheme.light)
                Text("Dark").tag(AppTheme.dark)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Preferences

    private var preferences: some View {
        Section("Preferences") {
            NavigationLink {
                InteractionsSettingsView()
            } label: {
                SettingsRow(title: "Interactions", subtitle: "Toolbar buttons, auto-advance, and tap gestures", systemImage: "hand.tap")
            }
            NavigationLink {
                SwipeActionsSettingsView()
            } label: {
                SettingsRow(title: "Swipe actions", subtitle: "Choose what each swipe direction does", systemImage: "hand.draw")
            }
            NavigationLink {
                ActionButtonsSettingsView()
            } label: {
                SettingsRow(title: "Swipe card action buttons", subtitle: "Customize visibility and position of overlay buttons", systemImage: "circle.grid.2x2")
            }
            Toggle(isOn: $includeArchived) {
                SettingsRow(title: "Include external archives", subtitle: "View and sort photos that have been archived in Immich (outside of Immich Swipe)", systemImage: "archivebox")
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsRow(title: "Sound behavior", subtitle: "Manage interaction with other device sounds when playing a video", systemImage: "speaker.wave.2")
                Picker("Sound behavior", selection: $playbackBehavior) {
                    Text("Pause others").tag(PlaybackBehavior.pauseOthers)
                    Text("Play over others").tag(PlaybackBehavior.playOverOthers)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: Reminder

    private var reminder: some View {
        Section {
            Toggle(isOn: reminderToggle) {
                SettingsRow(title: "Cleanup reminder", subtitle: "Get a notification to remind you to sort your photos. Disabled by default.", systemImage: "bell")
            }

            if reminderEnabled {
                Picker("Frequency", selection: $reminderInterval) {
                    Text("Often").tag(ReminderInterval.often)
                    Text("Rarely").tag(ReminderInterval.rarely)
                    Text("Custom").tag(ReminderInterval.custom)
                }
                .pickerStyle(.segmented)

                if reminderInterval == .custom {
                    Stepper("Minimum days: \(customMinDays)", value: $customMinDays, in: 1...365)
                    Stepper("Maximum days: \(customMaxDays)", value: $customMaxDays, in: customMinDays...365)
                }
            }
        } header: {
            Text("Reminder")
        } footer: {
            if reminderEnabled {
                Text(reminderHint)
            }
        }
        // Keep the maximum from falling below the minimum.
        .onChange(of: customMinDays) { _, newValue in
            if customMaxDays < newValue { customMaxDays = newValue }
        }
    }

    /// Turning reminders on needs notification permission, so the switch only stays on if it's granted.
    private var reminderToggle: Binding<Bool> {
        Binding(
            get: { reminderEnabled },
            set: { wantsOn in
                guard wantsOn else {
                    reminderEnabled = false
                    return
                }
                Task {
                    if await reminders.requestPermission() {
                        reminderEnabled = true
                    } else {
                        reminderEnabled = false
                        model.message = String(localized: "Notification permission denied. The reminder stays disabled.")
                    }
                }
            }
        )
    }

    private var reminderHint: LocalizedStringKey {
        switch reminderInterval {
        case .often: "Every 1–2 weeks, at random intervals"
        case .rarely: "Every 3–5 weeks, at random intervals"
        case .custom: "Every \(customMinDays)–\(customMaxDays) days, at random intervals"
        }
    }

    // MARK: Database

    private var database: some View {
        Section {
            Button {
                databaseAction = .delete
            } label: {
                SettingsRow(title: "Delete data", subtitle: "Clear your swipe choices and history.", systemImage: "trash", isDestructive: true)
            }
            Button {
                databaseAction = .export
            } label: {
                SettingsRow(title: "Export database", subtitle: "Save your data to a JSON file.", systemImage: "square.and.arrow.up")
            }
            Button {
                isImporting = true
            } label: {
                SettingsRow(title: "Import database", subtitle: "Restore data from a JSON file. Works with backups from the Android app.", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Database")
        }
        .buttonStyle(.plain)
        .alert(
            databaseAction == .delete ? "Delete data?" : "Export data",
            isPresented: Binding(get: { databaseAction != nil }, set: { if !$0 { databaseAction = nil } })
        ) {
            let action = databaseAction
            Button("Only My Account (\(model.account.displayName))", role: action == .delete ? .destructive : nil) { run(action, scope: .account) }
            Button("All Accounts", role: action == .delete ? .destructive : nil) { run(action, scope: .allAccounts) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if databaseAction == .delete {
                Text("This permanently erases your local swipe decisions and sync statistics. It can't be undone.")
            }
        }
    }

    private func run(_ action: DatabaseAction?, scope: SettingsModel.Scope) {
        switch action {
        case .export: if model.prepareExport(scope) { isExporting = true }
        case .delete: model.deleteData(scope)
        case nil: break
        }
    }

    // MARK: Storage

    private var storage: some View {
        Section {
            NavigationLink {
                LogsView()
            } label: {
                SettingsRow(title: "View local logs", subtitle: "View or export system events in case of problems", systemImage: "clock.arrow.circlepath")
            }
            LabeledContent("Image cache", value: model.cacheBytes.formatted(.byteCount(style: .file)))
            Button(role: .destructive) {
                isConfirmingClearCache = true
            } label: {
                SettingsRow(title: "Clear app cache", subtitle: "Delete temporary files, thumbnails and cached images", systemImage: "xmark.bin", isDestructive: true)
            }
            .buttonStyle(.plain)
            .alert("Clear app cache?", isPresented: $isConfirmingClearCache) {
                Button("Clear Cache", role: .destructive) { Task { await model.clearCache() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all temporary files and cached images. They'll be downloaded from the server again as needed.")
            }
        } header: {
            Text("Storage")
        }
    }

    // MARK: About

    private var about: some View {
        Section("About & Legal") {
            LabeledContent("Version", value: Self.versionText)
            Link(destination: URL(string: "https://github.com/markvoronin354/immich-swipe-ios")!) {
                SettingsRow(title: "Source code", subtitle: "View the open source repository on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/markvoronin354/immich-swipe-ios/issues/new")!) {
                SettingsRow(title: "Report a bug", subtitle: "Open an issue on GitHub", systemImage: "ladybug")
            }
            Link(destination: URL(string: "https://github.com/markvoronin354/immich-swipe-ios/blob/HEAD/PRIVACY_POLICY.md")!) {
                SettingsRow(title: "Privacy policy", subtitle: "Read the privacy policy regarding data and permissions", systemImage: "hand.raised")
            }
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: Account

    private var accountSection: some View {
        Section("Account") {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.account.displayName).font(.headline)
                Text(model.account.email).foregroundStyle(.secondary)
                Label("Connected to Immich server", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                Text(model.account.serverURL.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            StorageUsageRow(user: model.user)

            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                isConfirmingSignOut = true
            }
            .alert("Sign out?", isPresented: $isConfirmingSignOut) {
                Button("Sign Out", role: .destructive) { session.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out of this account? You can switch back to it later without entering the key again.")
            }

            let others = session.accounts.filter { $0.userID != model.account.userID }
            if !others.isEmpty {
                ForEach(others) { other in
                    Button {
                        try? session.switchTo(other)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(other.displayName)
                            Text(other.serverURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Remove", role: .destructive) { accountToRemove = other }
                    }
                }
            }

            Button("Add Another Account", systemImage: "person.badge.plus") {
                // Signing out keeps this account saved, and shows the sign-in screen for the new one.
                session.signOut()
            }

            Button("Remove All Accounts", systemImage: "person.2.slash", role: .destructive) {
                isConfirmingRemoveAll = true
            }
        }
        .alert(
            "Remove account?",
            isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
            presenting: accountToRemove
        ) { account in
            Button("Remove \(account.displayName)", role: .destructive) { try? session.forget(account) }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("This removes \(account.displayName) and its API key from this device. Your server isn't changed.")
        }
        .alert("Remove all accounts?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All Accounts", role: .destructive) {
                for account in session.accounts { try? session.forget(account) }
                session.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved account and API key from this device and signs you out. Your server isn't changed.")
        }
    }
}

// MARK: - Pieces

private struct SettingsRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    var isDestructive = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(isDestructive ? Color.red : Color.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(isDestructive ? Color.red : Color.accentColor)
        }
        .contentShape(.rect)
    }
}

/// How much of the server storage quota the account uses, or "Unlimited" when there's no quota.
private struct StorageUsageRow: View {
    let user: User?

    var body: some View {
        if let user, let used = user.quotaUsageInBytes {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Storage usage")
                    Spacer()
                    if let limit = user.quotaSizeInBytes, limit > 0 {
                        Text("\(used.formatted(.byteCount(style: .file))) of \(limit.formatted(.byteCount(style: .file)))")
                    } else {
                        Text("\(used.formatted(.byteCount(style: .file))) · Unlimited")
                    }
                }
                .font(.subheadline)
                if let limit = user.quotaSizeInBytes, limit > 0 {
                    ProgressView(value: min(Double(used) / Double(limit), 1))
                }
            }
        }
    }
}

#Preview {
    let account = Account(userID: "preview", serverURL: URL(string: "https://photos.example.com")!, name: "Family_Media", email: "family@example.com", avatarColor: "yellow", lastActive: .now)
    NavigationStack {
        SettingsView(model: SettingsModel(
            account: account,
            client: ImmichClient(serverURL: account.serverURL, apiKey: "preview"),
            decisions: try! DecisionStore.inMemory()
        ))
    }
    .environment(SessionStore(defaults: UserDefaults(suiteName: "preview-settings")!))
}
