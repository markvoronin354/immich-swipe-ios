import Foundation
import Testing
@testable import Immich_Swipe_iOS

@MainActor
final class FakeNotifier: ReminderNotifying {
    struct Scheduled: Equatable { var id: String; var seconds: TimeInterval }
    var granted = true
    var queue: [Scheduled] = []
    private(set) var cancelled: [String] = []

    func requestAuthorization() async -> Bool { granted }
    func pendingReminderIDs(prefix: String) async -> [String] { queue.map(\.id).filter { $0.hasPrefix(prefix) } }
    func schedule(id: String, title: String, body: String, after seconds: TimeInterval) async {
        queue.append(Scheduled(id: id, seconds: seconds))
    }
    func cancel(ids: [String]) {
        cancelled += ids
        queue.removeAll { ids.contains($0.id) }
    }
}

@MainActor
struct ReminderSchedulerTests {
    let notifier = FakeNotifier()
    let defaults = UserDefaults(suiteName: "reminder-tests-\(UUID().uuidString)")!

    private func scheduler(random: @escaping (ClosedRange<Int>) -> Int = { $0.lowerBound }) -> ReminderScheduler {
        ReminderScheduler(notifier: notifier, defaults: defaults, random: random)
    }

    private func config(_ interval: ReminderInterval = .often, enabled: Bool = true) -> ReminderConfig {
        ReminderConfig(enabled: enabled, interval: interval, customMinDays: 3, customMaxDays: 7)
    }

    @Test func queuesTenRemindersWithGrowingGaps() async {
        await scheduler().refresh(config())
        #expect(notifier.queue.count == ReminderScheduler.queueLength)
        // The shortest "often" gap is 7 days, so each reminder is a week after the previous one.
        let days = notifier.queue.map { $0.seconds / 86_400 }
        #expect(days.first == 7 && days.last == 70)
        #expect(zip(days, days.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func gapsStayInsideTheChosenRange() async {
        let picked = Counter()
        await scheduler(random: { range in
            picked.record(range)
            return range.upperBound
        }).refresh(config(.rarely))
        #expect(picked.ranges.allSatisfy { $0 == (21 * 24)...(35 * 24) })
        #expect(notifier.queue.first?.seconds == 35.0 * 86_400)
    }

    @Test func openingTheAppAgainDoesNotPushRemindersBack() async {
        let scheduler = scheduler()
        await scheduler.refresh(config())
        let before = notifier.queue
        await scheduler.refresh(config())
        #expect(notifier.queue == before)
        #expect(notifier.cancelled.isEmpty)
    }

    @Test func changingTheFrequencyRebuildsTheQueue() async {
        let scheduler = scheduler()
        await scheduler.refresh(config(.often))
        await scheduler.refresh(config(.rarely))
        #expect(notifier.queue.count == ReminderScheduler.queueLength)
        #expect(notifier.queue.first?.seconds == 21.0 * 86_400)
    }

    @Test func runningLowRefillsTheQueue() async {
        let scheduler = scheduler()
        await scheduler.refresh(config())
        notifier.queue.removeFirst(8) // most have fired
        #expect(notifier.queue.count == 2)
        await scheduler.refresh(config())
        #expect(notifier.queue.count == ReminderScheduler.queueLength)
    }

    @Test func turningRemindersOffClearsTheQueue() async {
        let scheduler = scheduler()
        await scheduler.refresh(config())
        await scheduler.refresh(config(enabled: false))
        #expect(notifier.queue.isEmpty)
        // Turning back on starts fresh instead of thinking the old queue is still there.
        await scheduler.refresh(config())
        #expect(notifier.queue.count == ReminderScheduler.queueLength)
    }

    @Test func permissionIsReportedAsGivenOrDenied() async {
        #expect(await scheduler().requestPermission())
        notifier.granted = false
        #expect(await scheduler().requestPermission() == false)
    }

    @Test func hoursFollowTheAndroidRule() {
        let low = ReminderScheduler.randomDelayHours(days: 3...7, random: { $0.lowerBound })
        let high = ReminderScheduler.randomDelayHours(days: 3...7, random: { $0.upperBound })
        #expect(low == 72 && high == 168)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ClosedRange<Int>] = []
    func record(_ range: ClosedRange<Int>) { lock.withLock { stored.append(range) } }
    var ranges: [ClosedRange<Int>] { lock.withLock { stored } }
}

// MARK: - Backup export

@MainActor
struct BackupExportTests {
    let store: DecisionStore

    init() throws {
        store = try DecisionStore.inMemory()
    }

    private func seed() throws {
        try store.save(.delete, assetID: "a1", albumID: "album-1", userID: "me", fileSize: 2000)
        try store.save(.keep, assetID: "a2", albumID: Album.virtualAllID, userID: "me", fileSize: nil)
        try store.save(.archive, assetID: "b1", albumID: Album.virtualAllID, userID: "other", fileSize: 5)
        try store.markSynced(assetIDs: ["a2"], userID: "me")
        try store.recordSync(userID: "me", deletedCount: 3, bytesSaved: 300, keptCount: 2, archivedCount: 1, lockedCount: 0)
    }

    @Test func exportUsesTheAndroidFieldNames() throws {
        try seed()
        let data = try store.exportBackup(userID: "me", now: Date(timeIntervalSince1970: 1_730_000_000))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["scope"] as? String == "USER")
        #expect(json["userId"] as? String == "me")
        #expect(json["exportDate"] as? Int == 1_730_000_000_000)

        let decisions = try #require(json["swipeDecisions"] as? [[String: Any]])
        #expect(decisions.count == 2)
        let deleted = try #require(decisions.first { $0["assetId"] as? String == "a1" })
        #expect(deleted["albumId"] as? String == "album-1")
        #expect(deleted["decision"] as? String == "DELETE")
        #expect(deleted["fileSize"] as? Int == 2000)
        #expect(deleted["isSynced"] as? Bool == false)
        #expect(deleted["wasSyncedSkip"] as? Bool == false)
        #expect(deleted["createdAt"] is Int)
        let kept = try #require(decisions.first { $0["assetId"] as? String == "a2" })
        #expect(kept["fileSize"] == nil, "a missing size is left out, like Gson does")

        let history = try #require(json["syncHistory"] as? [[String: Any]])
        #expect(history.count == 1)
        #expect(history[0]["bytesSaved"] as? Int == 300 && history[0]["skippedCount"] as? Int == 0)
    }

    @Test func allAccountsScopeIncludesEveryone() throws {
        try seed()
        let data = try store.exportBackup(userID: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["scope"] as? String == "ALL")
        #expect(json["userId"] == nil)
        #expect((json["swipeDecisions"] as? [Any])?.count == 3)
    }

    @Test func anExportImportsBackIntoAFreshDatabase() throws {
        try seed()
        let data = try store.exportBackup(userID: nil)

        let fresh = try DecisionStore.inMemory()
        let result = try fresh.importBackup(try AndroidBackup.read(data))
        #expect(result.decisionsByUser == ["me": 2, "other": 1])
        #expect(result.historyImported == 1)

        let mine = try fresh.allDecisions(userID: "me")
        #expect(mine["a1"]?.decision == .delete && mine["a1"]?.albumID == "album-1" && mine["a1"]?.fileSize == 2000)
        #expect(mine["a2"]?.isSynced == true)
        #expect(mine["a1"]?.createdAt.timeIntervalSince1970 == (try store.allDecisions(userID: "me")["a1"]?.createdAt.timeIntervalSince1970 ?? -1).rounded(toPlaces: 3))
    }

    @Test func deletingEverythingClearsEveryAccount() throws {
        try seed()
        try store.removeAllAccountsData()
        #expect(try store.totals(userID: "me").decided == 0)
        #expect(try store.totals(userID: "other").decided == 0)
        #expect(try store.syncHistory(userID: "me").isEmpty)
    }

    @Test func deletingOneAccountLeavesTheOther() throws {
        try seed()
        try store.removeAllData(userID: "me")
        #expect(try store.totals(userID: "me").decided == 0)
        #expect(try store.totals(userID: "other").decided == 1)
    }
}

private extension Double {
    /// Backups store milliseconds, so dates survive a round trip to the millisecond.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
