import Foundation
import Testing
@testable import Immich_Swipe_iOS

@MainActor
struct DecisionStoreTests {
    let store: DecisionStore

    init() throws {
        store = try DecisionStore.inMemory()
    }

    @Test func savingAgainReplacesTheDecision() throws {
        try store.save(.delete, assetID: "x1", albumID: Album.virtualAllID, userID: "u", fileSize: 100)
        try store.save(.archive, assetID: "x1", albumID: Album.virtualAllID, userID: "u", fileSize: 100)

        let totals = try store.totals(userID: "u")
        #expect(totals.decided == 1)
        let stored = try store.decisions(userID: "u", albumID: Album.virtualAllID, albumAssetIDs: [])
        #expect(stored["x1"]?.decision == .archive)
    }

    @Test func decisionsAreScopedPerUser() throws {
        try store.save(.keep, assetID: "x1", albumID: "a", userID: "u", fileSize: nil)
        try store.save(.delete, assetID: "x1", albumID: "a", userID: "other", fileSize: nil)

        #expect(try store.totals(userID: "u").decided == 1)
        #expect(try store.decisions(userID: "other", albumID: "a", albumAssetIDs: [])["x1"]?.decision == .delete)
    }

    @Test func albumIncludesDecisionsMadeElsewhereForItsAssets() throws {
        try store.save(.archive, assetID: "x1", albumID: Album.virtualAllID, userID: "u", fileSize: nil)
        try store.save(.keep, assetID: "x2", albumID: "albumA", userID: "u", fileSize: nil)
        try store.save(.delete, assetID: "y9", albumID: "albumB", userID: "u", fileSize: nil)

        let inA = try store.decisions(userID: "u", albumID: "albumA", albumAssetIDs: ["x1", "x2", "x3"])
        #expect(inA.keys.sorted() == ["x1", "x2"])
        #expect(inA["x1"]?.decision == .archive)
    }

    @Test func redecidingClearsTheSyncedFlag() throws {
        try store.save(.keep, assetID: "x1", albumID: "a", userID: "u", fileSize: nil)
        try store.markSynced(assetIDs: ["x1"], userID: "u")
        #expect(try store.totals(userID: "u").unsynced == 0)

        try store.save(.delete, assetID: "x1", albumID: "a", userID: "u", fileSize: nil)
        #expect(try store.totals(userID: "u").unsynced == 1)
    }

    @Test func bulkSaveCrossesBatchBoundaries() throws {
        let sizes = Dictionary(uniqueKeysWithValues: (0..<1200).map { ("b\($0)", Int64?.some(Int64($0))) })
        try store.save(sizes, decision: .delete, albumID: "albumB", userID: "u")
        #expect(try store.totals(userID: "u").decided == 1200)

        try store.remove(assetIDs: (0..<700).map { "b\($0)" }, userID: "u")
        #expect(try store.totals(userID: "u").decided == 500)
    }

    @Test func resetRemovesDecisionsMadeInOrApplyingToTheAlbum() throws {
        try store.save(.keep, assetID: "x1", albumID: "albumA", userID: "u", fileSize: nil)
        try store.save(.keep, assetID: "x2", albumID: Album.virtualAllID, userID: "u", fileSize: nil)
        try store.save(.keep, assetID: "x3", albumID: Album.virtualAllID, userID: "u", fileSize: nil)

        try store.removeAll(userID: "u", albumID: "albumA", albumAssetIDs: ["x2"])
        let remaining = try store.decisions(userID: "u", albumID: Album.virtualAllID, albumAssetIDs: [])
        #expect(remaining.keys.sorted() == ["x3"])
    }

    @Test func syncHistoryIsNewestFirstAndClearedWithUserData() throws {
        try store.recordSync(userID: "u", deletedCount: 1, bytesSaved: 10, keptCount: 0, archivedCount: 0, lockedCount: 0)
        try store.recordSync(userID: "u", deletedCount: 2, bytesSaved: 20, keptCount: 0, archivedCount: 0, lockedCount: 0)
        #expect(try store.syncHistory(userID: "u").first?.bytesSaved == 20)

        try store.removeAllData(userID: "u")
        #expect(try store.syncHistory(userID: "u").isEmpty)
    }

    /// Android's `HomeViewModelTest`: deleted and locked come from the history, kept and archived from the
    /// decisions, synced or not, so an apply doesn't count them a second time.
    @Test func statsTakeKeptAndArchivedFromTheDecisions() throws {
        try store.save(.keep, assetID: "k1", albumID: "a", userID: "u", fileSize: nil)
        try store.save(.keep, assetID: "k2", albumID: "a", userID: "u", fileSize: nil)
        try store.save(.archive, assetID: "a1", albumID: "a", userID: "u", fileSize: nil)
        try store.markSynced(assetIDs: ["k1", "a1"], userID: "u")
        try store.recordSync(userID: "u", deletedCount: 2, bytesSaved: 1000, keptCount: 4, archivedCount: 1, lockedCount: 1)

        let stats = StatisticsSheet.Stats(decisions: store, userID: "u")
        #expect(stats.totalKept == 2)
        #expect(stats.totalArchived == 1)
        #expect(stats.totalDeleted == 2)
        #expect(stats.totalLocked == 1)
        #expect(stats.totalSwiped == 6)
    }
}
