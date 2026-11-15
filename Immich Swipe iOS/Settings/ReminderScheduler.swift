import Foundation
import UserNotifications

/// The slice of the notification system the reminders need, so tests can swap in a fake.
@MainActor
protocol ReminderNotifying: AnyObject {
    func requestAuthorization() async -> Bool
    func pendingReminderIDs(prefix: String) async -> [String]
    func schedule(id: String, title: String, body: String, after seconds: TimeInterval) async
    func cancel(ids: [String])
}

/// Local notifications through the system.
@MainActor
final class SystemReminderNotifier: ReminderNotifying {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingReminderIDs(prefix: String) async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
    }

    func schedule(id: String, title: String, body: String, after seconds: TimeInterval) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// What the reminder settings say right now. Hashable so a view can re-run its refresh when it changes.
nonisolated struct ReminderConfig: Hashable, Sendable {
    var enabled: Bool
    var interval: ReminderInterval
    var customMinDays: Int
    var customMaxDays: Int

    var dayRange: ClosedRange<Int> { interval.dayRange(customMin: customMinDays, customMax: customMaxDays) }
}

/// Keeps a queue of cleanup reminders scheduled, like the Android app's random-interval reminder.
///
/// iOS can't run code in the background at a chosen time the way Android's WorkManager does, so
/// instead of one reminder that schedules the next, this queues the next several in advance with
/// random gaps. The queue is topped up whenever the app opens, and left alone while enough remain,
/// so opening the app often never pushes the reminders further away.
@MainActor
final class ReminderScheduler {
    static let idPrefix = "cleanup-reminder-"
    static let queueLength = 10
    /// Rebuild the queue when fewer than this many are left.
    static let refillBelow = 3
    private static let signatureKey = "reminder_queue_signature"

    private let notifier: ReminderNotifying
    private let defaults: UserDefaults
    private let random: (ClosedRange<Int>) -> Int

    init(
        notifier: ReminderNotifying? = nil,
        defaults: UserDefaults = .standard,
        random: @escaping (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
    ) {
        self.notifier = notifier ?? SystemReminderNotifier()
        self.defaults = defaults
        self.random = random
    }

    /// Asks permission to show notifications. Returns whether reminders can be turned on.
    func requestPermission() async -> Bool {
        await notifier.requestAuthorization()
    }

    /// Brings the queued reminders in line with the settings.
    func refresh(_ config: ReminderConfig) async {
        let queued = await notifier.pendingReminderIDs(prefix: Self.idPrefix)

        guard config.enabled else {
            if !queued.isEmpty { AppLog.i("Reminder", "Reminder cancelled") }
            notifier.cancel(ids: queued)
            defaults.removeObject(forKey: Self.signatureKey)
            return
        }

        let signature = "\(config.interval.rawValue):\(config.dayRange.lowerBound)-\(config.dayRange.upperBound)"
        if queued.count >= Self.refillBelow, defaults.string(forKey: Self.signatureKey) == signature { return }

        notifier.cancel(ids: queued)
        var elapsedHours = 0
        for index in 0..<Self.queueLength {
            elapsedHours += Self.randomDelayHours(days: config.dayRange, random: random)
            if index == 0 { AppLog.i("Reminder", "Next reminder (\(config.interval.rawValue)) in \(elapsedHours / 24) d \(elapsedHours % 24) h") }
            await notifier.schedule(
                id: "\(Self.idPrefix)\(index)",
                title: String(localized: "Time to tidy up!"),
                body: String(localized: "Sort a few photos in Immich Swipe."),
                after: TimeInterval(elapsedHours) * 3600
            )
        }
        defaults.set(signature, forKey: Self.signatureKey)
    }

    /// A whole number of hours inside the day range, as on Android (`min * 24 … max * 24`).
    nonisolated static func randomDelayHours(days: ClosedRange<Int>, random: (ClosedRange<Int>) -> Int) -> Int {
        random((days.lowerBound * 24)...(days.upperBound * 24))
    }
}
