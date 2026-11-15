import Foundation

/// The backup file, written in the same shape the Android app uses (`DatabaseExport`), so a backup
/// made here can be imported on Android and the other way round.
nonisolated struct BackupExport: Encodable, Sendable {
    struct Decision: Encodable, Sendable {
        var assetId: String
        var albumId: String
        var userId: String
        var decision: String
        var fileSize: Int64?
        /// Milliseconds since 1970.
        var createdAt: Int64
        var isSynced: Bool
        var wasSyncedSkip = false
    }

    struct History: Encodable, Sendable {
        var id: Int
        var userId: String
        /// Milliseconds since 1970.
        var timestamp: Int64
        var deletedCount: Int
        var bytesSaved: Int64
        var keptCount: Int
        var archivedCount: Int
        var lockedCount: Int
        var skippedCount = 0
    }

    var swipeDecisions: [Decision]
    var syncHistory: [History]
    var exportDate: Int64
    /// "USER" for one account, "ALL" for everything on this device.
    var scope: String
    var userId: String?

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
