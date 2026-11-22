import SwiftData
import SwiftUI

@main struct MyApp: App {
    @State private var session = SessionStore()
    @AppStorage(Setting.Key.theme) private var theme = Setting.Default.theme
    @AppStorage(Setting.Key.reminderEnabled) private var reminderEnabled = Setting.Default.reminderEnabled
    @AppStorage(Setting.Key.reminderInterval) private var reminderInterval = Setting.Default.reminderInterval
    @AppStorage(Setting.Key.reminderCustomMinDays) private var reminderMinDays = Setting.Default.reminderCustomMinDays
    @AppStorage(Setting.Key.reminderCustomMaxDays) private var reminderMaxDays = Setting.Default.reminderCustomMaxDays
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var reminders = ReminderScheduler()
    private let decisions: DecisionStore

    init() {
        AppLog.startSession()
        AppLog.i("App", "Application started")
        TutorialFlags.processInstall()
        decisions = Self.makeDecisionStore()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(decisions: decisions)
                .environment(session)
                .preferredColorScheme(theme.colorScheme)
                // Re-checks the queue when a reminder setting changes and each time the app comes forward.
                .task(id: reminderConfig) { await reminders.refresh(reminderConfig) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await reminders.refresh(reminderConfig) } }
                }
        }
    }

    private var reminderConfig: ReminderConfig {
        ReminderConfig(enabled: reminderEnabled, interval: reminderInterval, customMinDays: reminderMinDays, customMaxDays: reminderMaxDays)
    }

    /// The on-disk decision database. Falls back to memory so a broken store can't stop the app launching;
    /// decisions then last only until the app quits.
    private static func makeDecisionStore() -> DecisionStore {
        do {
            return DecisionStore(container: try ModelContainer(for: DecisionStore.schema))
        } catch {
            AppLog.e("Database", "Couldn't open the decision database, using a temporary one", error)
            assertionFailure("Couldn't open the decision database: \(error)")
            return try! DecisionStore.inMemory()
        }
    }
}
