import Foundation

/// The JSON file the Android app writes from Settings › Export database (`DatabaseExport`).
/// Field names follow the Android Room entities, serialised by Gson.
nonisolated struct AndroidBackup: Decodable, Sendable {
    struct Decision: Decodable, Sendable {
        var assetId: String
        var albumId: String
        var userId: String
        var decision: String
        var fileSize: Int64?
        /// Milliseconds since 1970.
        var createdAt: Int64?
        var isSynced: Bool?

        var isSkip: Bool { decision.caseInsensitiveCompare("SKIP") == .orderedSame }
        var swipeDecision: SwipeDecision? { SwipeDecision(rawValue: decision.uppercased()) }
        var createdDate: Date { createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .now }
    }

    struct History: Decodable, Sendable {
        var userId: String
        /// Milliseconds since 1970.
        var timestamp: Int64
        var deletedCount: Int?
        var bytesSaved: Int64?
        var keptCount: Int?
        var archivedCount: Int?
        var lockedCount: Int?
    }

    var decisions: [Decision]
    var history: [History]

    private enum CodingKeys: String, CodingKey {
        case swipeDecisions, syncHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisions = try container.decodeIfPresent([Decision].self, forKey: .swipeDecisions) ?? []
        history = try container.decodeIfPresent([History].self, forKey: .syncHistory) ?? []
    }

    struct NotABackup: Error, LocalizedError {
        var errorDescription: String? {
            String(localized: "This file isn't an Immich Swipe backup. Export one from the Android app under Settings › Database.")
        }
    }

    /// Reads a backup file. Anything that isn't one, including an empty export, is reported as such.
    static func read(_ data: Data) throws -> AndroidBackup {
        let backup: AndroidBackup
        do {
            backup = try JSONDecoder().decode(AndroidBackup.self, from: data)
        } catch {
            throw NotABackup()
        }
        guard !backup.decisions.isEmpty || !backup.history.isEmpty else { throw NotABackup() }
        return backup
    }

    /// What an import did, for the confirmation message.
    struct Result: Equatable, Sendable {
        var decisionsByUser: [String: Int] = [:]
        var historyImported = 0
        var duplicateHistory = 0
        var unreadableDecisions = 0

        var totalDecisions: Int { decisionsByUser.values.reduce(0, +) }
    }
}
