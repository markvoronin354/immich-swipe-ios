import Foundation
import Testing
@testable import Immich_Swipe_iOS

/// A backup as Gson writes it from the Android `DatabaseExport` (null fields are left out).
private let sampleBackup = """
{
  "swipeDecisions": [
    {"assetId":"a1","albumId":"virtual_all_assets","userId":"me","decision":"KEEP","fileSize":1000,"createdAt":1730000000000,"isSynced":true,"wasSyncedSkip":false},
    {"assetId":"a2","albumId":"album-9","userId":"me","decision":"DELETE","fileSize":2000,"createdAt":1730000001000,"isSynced":false,"wasSyncedSkip":false},
    {"assetId":"a3","albumId":"album-9","userId":"me","decision":"SKIP","createdAt":1730000002000,"isSynced":false,"wasSyncedSkip":true},
    {"assetId":"a4","albumId":"virtual_all_assets","userId":"me","decision":"PANORAMA","createdAt":1730000003000,"isSynced":false,"wasSyncedSkip":false},
    {"assetId":"b1","albumId":"virtual_all_assets","userId":"someone-else","decision":"ARCHIVE","createdAt":1730000004000,"isSynced":false,"wasSyncedSkip":false}
  ],
  "syncHistory": [
    {"id":7,"userId":"me","timestamp":1729000000000,"deletedCount":12,"bytesSaved":4096,"keptCount":30,"archivedCount":2,"lockedCount":0,"skippedCount":5}
  ],
  "exportDate":1730000009000,
  "scope":"ALL"
}
"""

@MainActor
struct AndroidBackupTests {
    let store: DecisionStore

    init() throws {
        store = try DecisionStore.inMemory()
    }

    private func importSample() throws -> AndroidBackup.Result {
        try store.importBackup(try AndroidBackup.read(Data(sampleBackup.utf8)))
    }

    @Test func importsDecisionsWithTheirDatesAndSyncState() throws {
        let result = try importSample()
        #expect(result.decisionsByUser == ["me": 2, "someone-else": 1])
        #expect(result.unreadableDecisions == 1)

        let mine = try store.allDecisions(userID: "me")
        #expect(mine.keys.sorted() == ["a1", "a2"])
        #expect(mine["a1"]?.decision == .keep && mine["a1"]?.isSynced == true)
        #expect(mine["a2"]?.decision == .delete && mine["a2"]?.isSynced == false && mine["a2"]?.albumID == "album-9")
        #expect(mine["a2"]?.fileSize == 2000)
        #expect(mine["a2"]?.createdAt == Date(timeIntervalSince1970: 1_730_000_001))
        #expect(try store.allDecisions(userID: "someone-else")["b1"]?.decision == .archive)
    }

    @Test func skipRowsAreDroppedAndClearLocalState() throws {
        try store.save(.keep, assetID: "a3", albumID: "album-9", userID: "me", fileSize: nil)
        _ = try importSample()
        #expect(try store.allDecisions(userID: "me")["a3"] == nil)
    }

    @Test func importReplacesExistingDecisions() throws {
        try store.save(.keep, assetID: "a2", albumID: "elsewhere", userID: "me", fileSize: nil)
        _ = try importSample()
        #expect(try store.allDecisions(userID: "me")["a2"]?.decision == .delete)
        #expect(try store.totals(userID: "me").decided == 2)
    }

    @Test func importingTwiceDoesNotDuplicateHistory() throws {
        let first = try importSample()
        let second = try importSample()
        #expect(first.historyImported == 1)
        #expect(second.historyImported == 0 && second.duplicateHistory == 1)

        let history = try store.syncHistory(userID: "me")
        #expect(history.count == 1)
        #expect(history.first?.deletedCount == 12 && history.first?.bytesSaved == 4096)
    }

    @Test func rejectsFilesThatAreNotBackups() {
        #expect(throws: AndroidBackup.NotABackup.self) { try AndroidBackup.read(Data("not json".utf8)) }
        #expect(throws: AndroidBackup.NotABackup.self) { try AndroidBackup.read(Data(#"{"something":"else"}"#.utf8)) }
        #expect(throws: AndroidBackup.NotABackup.self) { try AndroidBackup.read(Data(#"{"swipeDecisions":[],"syncHistory":[]}"#.utf8)) }
    }

    @Test func messageWarnsWhenNothingMatchesThisAccount() {
        let result = AndroidBackup.Result(decisionsByUser: ["other": 3])
        let message = HomeModel.message(for: result, userID: "me")
        #expect(message.contains("0"))
        #expect(message.contains("same server and user"))
    }
}
