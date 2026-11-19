import Foundation
import SwiftData

/// What the user decided for an asset. Raw values match the Android database so exports import cleanly.
nonisolated enum SwipeDecision: String, CaseIterable, Codable, Sendable {
    case keep = "KEEP"
    case delete = "DELETE"
    case archive = "ARCHIVE"
    case lock = "LOCK"
}

/// One decision per asset per user (spec §2.2, table `swipe_decisions`).
@Model
final class DecisionRecord {
    #Unique<DecisionRecord>([\.assetID, \.userID])
    #Index<DecisionRecord>([\.userID, \.albumID])

    var assetID: String
    /// The album (real or virtual) the decision was made in.
    var albumID: String
    var userID: String
    var decisionRawValue: String
    /// Snapshot of the file size, for "space saved" totals.
    var fileSize: Int64?
    var createdAt: Date
    /// True once the server step for this decision has been applied.
    var isSynced: Bool

    var decision: SwipeDecision { SwipeDecision(rawValue: decisionRawValue) ?? .keep }

    init(assetID: String, albumID: String, userID: String, decision: SwipeDecision, fileSize: Int64?, createdAt: Date = .now, isSynced: Bool = false) {
        self.assetID = assetID
        self.albumID = albumID
        self.userID = userID
        self.decisionRawValue = decision.rawValue
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.isSynced = isSynced
    }
}

/// One row per successful "Apply changes" (spec §2.2, table `sync_history`).
@Model
final class SyncHistoryRecord {
    #Index<SyncHistoryRecord>([\.userID, \.timestamp])

    var userID: String
    var timestamp: Date
    var deletedCount: Int
    var bytesSaved: Int64
    var keptCount: Int
    var archivedCount: Int
    var lockedCount: Int

    init(userID: String, timestamp: Date = .now, deletedCount: Int, bytesSaved: Int64, keptCount: Int, archivedCount: Int, lockedCount: Int) {
        self.userID = userID
        self.timestamp = timestamp
        self.deletedCount = deletedCount
        self.bytesSaved = bytesSaved
        self.keptCount = keptCount
        self.archivedCount = archivedCount
        self.lockedCount = lockedCount
    }
}

/// A stored decision as a plain value, safe to hand to views and the deck logic.
nonisolated struct StoredDecision: Hashable, Sendable {
    var decision: SwipeDecision
    var albumID: String
    var fileSize: Int64?
    var createdAt: Date
    var isSynced: Bool
}

/// How far through an album the user is.
nonisolated struct AlbumProgress: Hashable, Sendable {
    var decided = 0
    var unsynced = 0
}

/// Reads and writes swipe decisions and sync history.
///
/// A decision belongs to an asset, not an album: deciding on a photo in "All" also marks it decided
/// in every album that contains it. So album queries take the album's asset IDs as well as its ID.
final class DecisionStore {
    private let context: ModelContext
    /// For reads off the main actor, each on a context of its own.
    private nonisolated let container: ModelContainer

    /// SwiftData `IN` predicates get slow with very long lists, so ID batches are split.
    private static let batchSize = 500

    static let schema = Schema([DecisionRecord.self, SyncHistoryRecord.self])

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    /// A store backed by a throwaway in-memory database, for previews and tests.
    static func inMemory() throws -> DecisionStore {
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return DecisionStore(container: container)
    }

    // MARK: Reading

    /// Decisions that apply to an album: made in it, or made anywhere for an asset it contains.
    func decisions(userID: String, albumID: String, albumAssetIDs: Set<String>) throws -> [String: StoredDecision] {
        var result: [String: StoredDecision] = [:]
        let madeHere = FetchDescriptor<DecisionRecord>(predicate: #Predicate { $0.userID == userID && $0.albumID == albumID })
        for record in try context.fetch(madeHere) {
            result[record.assetID] = Self.value(of: record)
        }
        for record in try records(userID: userID, assetIDs: albumAssetIDs.subtracting(result.keys)) {
            result[record.assetID] = Self.value(of: record)
        }
        return result
    }

    /// Every decision the user has, keyed by asset ID. One fetch, so a deck of tens of thousands of
    /// photos can pick out its own decisions in memory instead of querying in batches.
    func allDecisions(userID: String) throws -> [String: StoredDecision] {
        try Self.allDecisions(userID: userID, in: context)
    }

    /// Distinct decided assets, and how many of them are still waiting for "Apply changes".
    func totals(userID: String) throws -> (decided: Int, unsynced: Int) {
        let decided = try context.fetchCount(FetchDescriptor<DecisionRecord>(predicate: #Predicate { $0.userID == userID }))
        let unsynced = try context.fetchCount(FetchDescriptor<DecisionRecord>(predicate: #Predicate { $0.userID == userID && !$0.isSynced }))
        return (decided, unsynced)
    }

    /// Decided and unsynced counts per album, keyed by the album each decision was made in.
    ///
    /// This undercounts real albums whose photos were decided elsewhere (for example in "All"),
    /// because that needs the album's asset list. The swipe deck uses the full rule.
    func progressByAlbum(userID: String) throws -> [String: AlbumProgress] {
        try Self.progressByAlbum(userID: userID, in: context)
    }

    // MARK: Reading off the main actor

    // Reading every decision takes over half a second once there are tens of thousands, which froze the
    // screen when a deck opened or Home appeared. These read on a context of their own instead. Every
    // write here saves straight away, so they see everything written before they were called.

    @concurrent
    nonisolated func allDecisionsInBackground(userID: String) async throws -> [String: StoredDecision] {
        try Self.allDecisions(userID: userID, in: ModelContext(container))
    }

    @concurrent
    nonisolated func progressByAlbumInBackground(userID: String) async throws -> [String: AlbumProgress] {
        try Self.progressByAlbum(userID: userID, in: ModelContext(container))
    }

    private nonisolated static func allDecisions(userID: String, in context: ModelContext) throws -> [String: StoredDecision] {
        let descriptor = FetchDescriptor<DecisionRecord>(predicate: #Predicate { $0.userID == userID })
        return Dictionary(try context.fetch(descriptor).map { ($0.assetID, value(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func progressByAlbum(userID: String, in context: ModelContext) throws -> [String: AlbumProgress] {
        var descriptor = FetchDescriptor<DecisionRecord>(predicate: #Predicate { $0.userID == userID })
        descriptor.propertiesToFetch = [\.albumID, \.isSynced]
        var result: [String: AlbumProgress] = [:]
        for record in try context.fetch(descriptor) {
            result[record.albumID, default: AlbumProgress()].decided += 1
            if !record.isSynced { result[record.albumID, default: AlbumProgress()].unsynced += 1 }
        }
        return result
    }

    func syncHistory(userID: String) throws -> [SyncHistoryRecord] {
        var descriptor = FetchDescriptor<SyncHistoryRecord>(predicate: #Predicate { $0.userID == userID })
        descriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        return try context.fetch(descriptor)
    }

    // MARK: Writing

    /// Records or replaces the decision for one asset. It starts out unsynced.
    func save(_ decision: SwipeDecision, assetID: String, albumID: String, userID: String, fileSize: Int64?) throws {
        try save([assetID: fileSize], decision: decision, albumID: albumID, userID: userID)
    }

    /// Records or replaces the same decision for many assets at once (bulk mode). Keys are asset IDs.
    func save(_ fileSizes: [String: Int64?], decision: SwipeDecision, albumID: String, userID: String) throws {
        let existing = Dictionary(
            try records(userID: userID, assetIDs: Set(fileSizes.keys)).map { ($0.assetID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date.now
        for (assetID, fileSize) in fileSizes {
            if let record = existing[assetID] {
                record.albumID = albumID
                record.decisionRawValue = decision.rawValue
                record.fileSize = fileSize
                record.createdAt = now
                record.isSynced = false
            } else {
                context.insert(DecisionRecord(assetID: assetID, albumID: albumID, userID: userID, decision: decision, fileSize: fileSize, createdAt: now))
            }
        }
        try context.save()
    }

    func remove(assetIDs: some Collection<String>, userID: String) throws {
        for record in try records(userID: userID, assetIDs: Set(assetIDs)) {
            context.delete(record)
        }
        try context.save()
    }

    /// "Reset album": forgets every decision that applies to the album.
    func removeAll(userID: String, albumID: String, albumAssetIDs: Set<String>) throws {
        try context.delete(model: DecisionRecord.self, where: #Predicate { $0.userID == userID && $0.albumID == albumID })
        try remove(assetIDs: albumAssetIDs, userID: userID)
    }

    func markSynced(assetIDs: some Collection<String>, userID: String) throws {
        for record in try records(userID: userID, assetIDs: Set(assetIDs)) {
            record.isSynced = true
        }
        try context.save()
    }

    func recordSync(userID: String, deletedCount: Int, bytesSaved: Int64, keptCount: Int, archivedCount: Int, lockedCount: Int) throws {
        context.insert(SyncHistoryRecord(userID: userID, deletedCount: deletedCount, bytesSaved: bytesSaved, keptCount: keptCount, archivedCount: archivedCount, lockedCount: lockedCount))
        try context.save()
    }

    /// Removes everything stored for a user, for example on sign-out with "forget data".
    func removeAllData(userID: String) throws {
        try context.delete(model: DecisionRecord.self, where: #Predicate { $0.userID == userID })
        try context.delete(model: SyncHistoryRecord.self, where: #Predicate { $0.userID == userID })
        try context.save()
    }

    // MARK: Export and wipe

    /// Everything saved for one account, or for every account when `userID` is nil, as a backup file.
    func exportBackup(userID: String?, now: Date = .now) throws -> Data {
        let decisionRecords: [DecisionRecord]
        let historyRecords: [SyncHistoryRecord]
        if let userID {
            decisionRecords = try context.fetch(FetchDescriptor<DecisionRecord>(predicate: #Predicate { $0.userID == userID }))
            historyRecords = try context.fetch(FetchDescriptor<SyncHistoryRecord>(predicate: #Predicate { $0.userID == userID }))
        } else {
            decisionRecords = try context.fetch(FetchDescriptor<DecisionRecord>())
            historyRecords = try context.fetch(FetchDescriptor<SyncHistoryRecord>())
        }

        let export = BackupExport(
            swipeDecisions: decisionRecords.sorted { $0.createdAt < $1.createdAt }.map {
                BackupExport.Decision(
                    assetId: $0.assetID, albumId: $0.albumID, userId: $0.userID, decision: $0.decisionRawValue,
                    fileSize: $0.fileSize, createdAt: BackupExport.milliseconds($0.createdAt), isSynced: $0.isSynced
                )
            },
            syncHistory: historyRecords.sorted { $0.timestamp < $1.timestamp }.enumerated().map { index, record in
                BackupExport.History(
                    id: index + 1, userId: record.userID, timestamp: BackupExport.milliseconds(record.timestamp),
                    deletedCount: record.deletedCount, bytesSaved: record.bytesSaved, keptCount: record.keptCount,
                    archivedCount: record.archivedCount, lockedCount: record.lockedCount
                )
            },
            exportDate: BackupExport.milliseconds(now),
            scope: userID == nil ? "ALL" : "USER",
            userId: userID
        )
        return try export.data()
    }

    /// Forgets every decision and history row for every account on this device.
    func removeAllAccountsData() throws {
        try context.delete(model: DecisionRecord.self)
        try context.delete(model: SyncHistoryRecord.self)
        try context.save()
    }

    // MARK: Import

    /// Writes decisions and history from an Android backup (spec §2.2, `importData`).
    ///
    /// - Decisions replace any existing decision for the same asset and user, keeping their original
    ///   date and synced state. SKIP rows are dropped, and clear any local state for those assets.
    /// - History rows already present (same user and timestamp) are skipped, so importing twice is harmless.
    func importBackup(_ backup: AndroidBackup) throws -> AndroidBackup.Result {
        var result = AndroidBackup.Result()

        let skipped = backup.decisions.filter { $0.isSkip }
        for (userID, rows) in Dictionary(grouping: skipped, by: \.userId) {
            for record in try records(userID: userID, assetIDs: Set(rows.map(\.assetId))) {
                context.delete(record)
            }
        }

        let usable = backup.decisions.filter { !$0.isSkip }
        for (userID, rows) in Dictionary(grouping: usable, by: \.userId) {
            let existing = Dictionary(
                try records(userID: userID, assetIDs: Set(rows.map(\.assetId))).map { ($0.assetID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for row in rows {
                guard let decision = row.swipeDecision else {
                    result.unreadableDecisions += 1
                    continue
                }
                if let record = existing[row.assetId] {
                    record.albumID = row.albumId
                    record.decisionRawValue = decision.rawValue
                    record.fileSize = row.fileSize
                    record.createdAt = row.createdDate
                    record.isSynced = row.isSynced ?? false
                } else {
                    context.insert(DecisionRecord(assetID: row.assetId, albumID: row.albumId, userID: userID, decision: decision, fileSize: row.fileSize, createdAt: row.createdDate, isSynced: row.isSynced ?? false))
                }
                result.decisionsByUser[userID, default: 0] += 1
            }
        }

        let existingHistory = Set(try context.fetch(FetchDescriptor<SyncHistoryRecord>()).map { "\($0.userID)|\($0.timestamp.timeIntervalSince1970)" })
        for row in backup.history {
            let timestamp = Date(timeIntervalSince1970: Double(row.timestamp) / 1000)
            guard !existingHistory.contains("\(row.userId)|\(timestamp.timeIntervalSince1970)") else {
                result.duplicateHistory += 1
                continue
            }
            context.insert(SyncHistoryRecord(
                userID: row.userId,
                timestamp: timestamp,
                deletedCount: row.deletedCount ?? 0,
                bytesSaved: row.bytesSaved ?? 0,
                keptCount: row.keptCount ?? 0,
                archivedCount: row.archivedCount ?? 0,
                lockedCount: row.lockedCount ?? 0
            ))
            result.historyImported += 1
        }

        try context.save()
        return result
    }

    /// Reads a backup file from disk, including files outside the app's sandbox, and imports it.
    func importBackup(fromFileAt url: URL) throws -> AndroidBackup.Result {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try importBackup(try AndroidBackup.read(try Data(contentsOf: url)))
    }

    // MARK: Helpers

    private func records(userID: String, assetIDs: Set<String>) throws -> [DecisionRecord] {
        guard !assetIDs.isEmpty else { return [] }
        let ids = Array(assetIDs)
        var result: [DecisionRecord] = []
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            let batch = Array(ids[start..<min(start + Self.batchSize, ids.count)])
            let descriptor = FetchDescriptor<DecisionRecord>(predicate: #Predicate { $0.userID == userID && batch.contains($0.assetID) })
            result += try context.fetch(descriptor)
        }
        return result
    }

    private nonisolated static func value(of record: DecisionRecord) -> StoredDecision {
        StoredDecision(decision: record.decision, albumID: record.albumID, fileSize: record.fileSize, createdAt: record.createdAt, isSynced: record.isSynced)
    }
}
