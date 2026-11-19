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

    @Test func backgroundReadsSeeWhatWasJustSavedAndMatchTheMainReads() async throws {
        try store.save(.keep, assetID: "x1", albumID: "a", userID: "u", fileSize: 10)
        try store.save(.delete, assetID: "x2", albumID: "b", userID: "u", fileSize: 20)
        try store.save(.archive, assetID: "x3", albumID: "b", userID: "other", fileSize: nil)
        try store.markSynced(assetIDs: ["x1"], userID: "u")

        let all = try await store.allDecisionsInBackground(userID: "u")
        #expect(all == (try store.allDecisions(userID: "u")))
        #expect(all.keys.sorted() == ["x1", "x2"])

        let progress = try await store.progressByAlbumInBackground(userID: "u")
        #expect(progress == (try store.progressByAlbum(userID: "u")))
        #expect(progress["b"] == AlbumProgress(decided: 1, unsynced: 1))
        // Home adds the albums up for its totals, which must match counting directly.
        let totals = try store.totals(userID: "u")
        #expect(progress.values.reduce(0) { $0 + $1.decided } == totals.decided)
        #expect(progress.values.reduce(0) { $0 + $1.unsynced } == totals.unsynced)

        // A change after the first read shows up in the next one.
        try store.remove(assetIDs: ["x2"], userID: "u")
        #expect(try await store.allDecisionsInBackground(userID: "u").keys.sorted() == ["x1"])
    }

    @Test func bulkSaveCrossesBatchBoundaries() throws {
        let sizes = Dictionary(uniqueKeysWithValues: (0..<1200).map { ("b\($0)", Int64?.some(Int64($0))) })
        try store.save(sizes, decision: .delete, albumID: "albumB", userID: "u")
        #expect(try store.totals(userID: "u").decided == 1200)

        try store.remove(assetIDs: (0..<700).map { "b\($0)" }, userID: "u")
        #expect(try store.totals(userID: "u").decided == 500)
    }

    /// Bulk writes save in batches of 500; every batch must land, whether its rows are new or already stored.
    @Test func bulkWritesMixingNewAndStoredRowsLandInEveryBatch() throws {
        try store.save(Dictionary(uniqueKeysWithValues: (0..<600).map { ("m\($0)", Int64?.some(1)) }), decision: .keep, albumID: "a", userID: "u")
        // 600 already stored, 700 new, across three batches.
        try store.save(Dictionary(uniqueKeysWithValues: (0..<1300).map { ("m\($0)", Int64?.some(2)) }), decision: .delete, albumID: "b", userID: "u")

        let all = try store.allDecisions(userID: "u")
        #expect(all.count == 1300)
        #expect(all.values.allSatisfy { $0.decision == .delete && $0.albumID == "b" && $0.fileSize == 2 })

        try store.markSynced(assetIDs: (0..<1100).map { "m\($0)" }, userID: "u")
        #expect(try store.totals(userID: "u").unsynced == 200)
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
