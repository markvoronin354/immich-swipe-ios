import Foundation
import Testing
@testable import Immich_Swipe_iOS

private func assetJSON(_ id: String, date: String, size: Int = 100, edited: Bool = false) -> String {
    #"{"id":"\#(id)","ownerId":"u","fileCreatedAt":"\#(date)","type":"IMAGE","isFavorite":false,"isArchived":false,"isTrashed":false,"isEdited":\#(edited),"exifInfo":{"fileSizeInByte":\#(size)}}"#
}

/// A flag the fake server's handler can read while the test flips it.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

// MARK: - Plan

struct ApplyPlanTests {
    private func asset(_ id: String, edited: Bool = false, size: Int64? = nil) -> Asset {
        Asset(id: id, ownerId: "u", fileCreatedAt: "2024", type: .image, isEdited: edited, exifInfo: size.map { ExifInfo(fileSizeInByte: $0) })
    }

    @Test func includesOnlyDecisionsStillPending() {
        let deck = Deck(assets: [asset("a"), asset("b"), asset("c")], decisions: ["a": .keep, "b": .delete, "c": .archive])
        let plan = ApplyPlan.make(deck: deck, pending: ["b", "c"], favorites: [:], rotations: [:])
        #expect(plan.keep.isEmpty)
        #expect(plan.delete.map(\.id) == ["b"])
        #expect(plan.archive.map(\.id) == ["c"])
        #expect(plan.serverChangeCount == 2)
    }

    @Test func groupsByDecisionAndTotalsBytes() {
        let deck = Deck(assets: [asset("a", size: 10), asset("b", size: 20), asset("c"), asset("d")], decisions: ["a": .delete, "b": .delete, "c": .lock, "d": .keep])
        let plan = ApplyPlan.make(deck: deck, pending: ["a", "b", "c", "d"], favorites: [:], rotations: [:])
        #expect(plan.delete.count == 2 && plan.bytesToFree == 30)
        #expect(plan.lock.map(\.id) == ["c"])
        #expect(plan.keep.map(\.id) == ["d"])
        #expect(plan.pendingCount == 4 && plan.serverChangeCount == 3)
    }

    @Test func skipsFavouritesAndRotationsForPhotosBeingDeleted() {
        let deck = Deck(assets: [asset("a"), asset("b")], decisions: ["a": .delete])
        let plan = ApplyPlan.make(deck: deck, pending: ["a"], favorites: ["a": true, "b": false], rotations: ["a": 90, "b": 90])
        #expect(plan.favoritesOn.isEmpty)
        #expect(plan.favoritesOff == ["b"])
        #expect(plan.rotations == [ApplyPlan.Rotation(assetID: "b", angle: 90)])
    }

    @Test func leavesAlreadyEditedPhotosAloneBecauseRotationReplacesEdits() {
        let deck = Deck(assets: [asset("a", edited: true), asset("b")])
        let plan = ApplyPlan.make(deck: deck, pending: [], favorites: [:], rotations: ["a": 90, "b": 270])
        #expect(plan.skippedRotationIDs == ["a"])
        #expect(plan.rotations.map(\.assetID) == ["b"])
    }

    @Test func emptyWhenNothingPending() {
        #expect(ApplyPlan.make(deck: Deck(assets: [asset("a")]), pending: [], favorites: [:], rotations: [:]).isEmpty)
    }
}

// MARK: - Running an apply against the fake server

@MainActor
struct ApplyChangesTests {
    /// Each test gets its own host, so suites running in parallel never share a fake server.
    let host = "apply-\(UUID().uuidString.prefix(8).lowercased()).example.com"
    let store: DecisionStore
    let defaults: UserDefaults

    init() throws {
        store = try DecisionStore.inMemory()
        defaults = UserDefaults(suiteName: "apply-tests-\(UUID().uuidString)")!
    }

    private func makeModel() -> DeckModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingServer.self]
        let client = ImmichClient(serverURL: URL(string: "https://\(host)")!, apiKey: "KEY", session: URLSession(configuration: configuration), retry: .none)
        return DeckModel(title: "Test", source: .all, client: client, userID: "u", decisions: store, shuffleSeed: 1, defaults: defaults, listingCache: .temporary())
    }

    /// Serves one page of photos newest-first, and accepts every write unless `fails` says otherwise.
    private func serve(_ assets: [String], failStatus: Int = 500, fails: @escaping @Sendable (String, String, [String: Any]) -> Bool = { _, _, _ in false }) {
        let page = assets.joined(separator: ",")
        RoutingServer.route(host: host) { method, path, body in
            if fails(method, path, body) { return (failStatus, #"{"message":"boom"}"#) }
            switch (method, path) {
            case ("POST", "/api/search/statistics"): return (200, #"{"total":\#(assets.count)}"#)
            case ("POST", "/api/search/metadata"): return (200, #"{"assets":{"items":[\#(page)],"total":\#(assets.count),"nextPage":null,"nextCursor":null}}"#)
            case ("PUT", "/api/assets"), ("DELETE", "/api/assets"): return (204, "")
            case ("PUT", _) where path.hasSuffix("/edits"): return (200, "{}")
            default: return (404, "{}")
            }
        }
    }

    /// The write requests made so far, without the loading ones.
    private var writes: [RoutingServer.Request] {
        RoutingServer.requests(host: host).filter { !$0.path.hasPrefix("/api/search") }
    }

    private func standardPile() -> [String] {
        [
            assetJSON("a", date: "2024-05"), assetJSON("b", date: "2024-04"), assetJSON("c", date: "2024-03"),
            assetJSON("d", date: "2024-02"), assetJSON("e", date: "2024-01"),
        ]
    }

    @Test func sendsEachStepInOrderAndTidiesUp() async throws {
        serve(standardPile())
        let model = makeModel()
        await model.load()
        model.decide(.keep)    // a
        model.decide(.delete)  // b
        model.decide(.archive) // c
        model.decide(.lock)    // d
        model.toggleFavoriteForCurrent() // e
        model.rotateCurrent()

        await model.apply()

        let sent = writes
        #expect(sent.map { "\($0.method) \($0.path)" } == [
            "DELETE /api/assets", "PUT /api/assets", "PUT /api/assets", "PUT /api/assets/e/edits", "PUT /api/assets",
        ])
        #expect(sent[0].body["ids"] as? [String] == ["b"])
        #expect(sent[0].body["force"] as? Bool == false, "deletes must go to the trash, never be forced")
        #expect(sent[1].body["visibility"] as? String == "archive" && sent[1].body["ids"] as? [String] == ["c"])
        #expect(sent[2].body["visibility"] as? String == "locked" && sent[2].body["ids"] as? [String] == ["d"])
        #expect((sent[3].body["edits"] as? [[String: Any]])?.first?["action"] as? String == "rotate")
        #expect(sent[4].body["isFavorite"] as? Bool == true && sent[4].body["ids"] as? [String] == ["e"])

        let outcome = try #require(model.lastOutcome)
        #expect(!outcome.hasFailures)
        #expect(outcome.bytesFreed == 100)

        // Deleted and locked photos are gone from the deck and the database; kept and archived stay, applied.
        #expect(model.deck.assets.map(\.id) == ["a", "c", "e"])
        let saved = try store.allDecisions(userID: "u")
        #expect(saved.keys.sorted() == ["a", "c"])
        #expect(saved.values.allSatisfy { $0.isSynced })

        let history = try #require(try store.syncHistory(userID: "u").first)
        #expect((history.deletedCount, history.keptCount, history.archivedCount, history.lockedCount, history.bytesSaved) == (1, 1, 1, 1, 100))

        // Favourite and rotation now live on the server, and nothing is left to send.
        let favoured = try #require(model.deck.assets.first { $0.id == "e" })
        #expect(favoured.isFavorite && favoured.isEdited)
        #expect(model.favoriteOverrides.isEmpty && model.rotations.isEmpty)
        #expect(model.plan.isEmpty)
        #expect(!model.deck.canUndo, "applied decisions can't be undone")
        #expect(model.serverTotal == 3)
    }

    @Test func aRefusedStepIsFlaggedAsAMissingPermission() async throws {
        serve(standardPile(), failStatus: 403) { method, path, body in
            method == "PUT" && path == "/api/assets" && body["visibility"] as? String == "archive"
        }
        let model = makeModel()
        await model.load()
        model.decide(.archive)
        await model.apply()
        #expect(model.lastOutcome?.permissionDenied == true)

        // A step that fails any other way is not a permission problem.
        serve(standardPile()) { method, path, body in
            method == "PUT" && path == "/api/assets" && body["visibility"] as? String == "archive"
        }
        await model.apply()
        #expect(model.lastOutcome?.permissionDenied == false)
    }

    @Test func aFailedStepLeavesItsPhotosPendingAndOthersApplied() async throws {
        let archiveWorks = Switch(false)
        serve(standardPile()) { method, path, body in
            method == "PUT" && path == "/api/assets" && body["visibility"] as? String == "archive" && !archiveWorks.isOn
        }
        let model = makeModel()
        await model.load()
        model.decide(.keep)    // a
        model.decide(.delete)  // b
        model.decide(.archive) // c

        await model.apply()

        let outcome = try #require(model.lastOutcome)
        #expect(Array(outcome.failures.keys) == [.archive])
        #expect(outcome.deletedIDs == ["b"], "the delete still happened")

        var saved = try store.allDecisions(userID: "u")
        #expect(saved.keys.sorted() == ["a", "c"])
        #expect(saved["c"]?.isSynced == false)
        #expect(saved["a"]?.isSynced == false, "kept photos stay pending until delete, archive and lock all succeed")
        #expect(model.plan.archive.map(\.id) == ["c"] && model.plan.keep.map(\.id) == ["a"])

        var history = try store.syncHistory(userID: "u")
        #expect(history.count == 1 && history[0].deletedCount == 1 && history[0].keptCount == 0)

        // Retrying sends only what's left, and counts the kept photo exactly once.
        archiveWorks.isOn = true
        await model.apply()
        #expect(model.lastOutcome?.hasFailures == false)
        #expect(writes.filter { $0.method == "DELETE" }.count == 1, "the delete isn't repeated")
        saved = try store.allDecisions(userID: "u")
        #expect(saved.values.allSatisfy { $0.isSynced })
        history = try store.syncHistory(userID: "u")
        #expect(history.count == 2)
        #expect(history.reduce(0) { $0 + $1.keptCount } == 1 && history.reduce(0) { $0 + $1.archivedCount } == 1)
        #expect(model.plan.isEmpty)
    }

    @Test func largeDeletesGoInChunksAndStopAtTheFirstFailure() async throws {
        let photos = (0..<1200).map { assetJSON("p\($0)", date: "2024-\(String(format: "%04d", 9999 - $0))") }
        let deleteCalls = Counter()
        serve(photos) { method, _, _ in method == "DELETE" && deleteCalls.next() == 2 }
        let model = makeModel()
        await model.load()
        for _ in 0..<1200 { model.decide(.delete) }
        #expect(model.plan.delete.count == 1200)

        await model.apply()

        #expect(writes.filter { $0.method == "DELETE" }.count == 2, "stops after the failed chunk instead of retrying the rest")
        let outcome = try #require(model.lastOutcome)
        #expect(outcome.deletedIDs.count == 500)
        #expect(outcome.failures[.delete] != nil)
        #expect(model.deck.assets.count == 700)
        let remaining = try store.totals(userID: "u").decided
        #expect(remaining == 700, "only the 500 deleted photos lose their decision")
        #expect(model.plan.delete.count == 700)
    }

    @Test func rotationIsNotSentForPhotosAlreadyEditedInImmich() async throws {
        serve([assetJSON("a", date: "2024-02", edited: true), assetJSON("b", date: "2024-01")])
        let model = makeModel()
        await model.load()
        model.rotateCurrent() // a, already edited on the server
        #expect(model.plan.skippedRotationIDs == ["a"])
        model.decide(.keep)
        await model.apply()
        #expect(!writes.contains { $0.path.hasSuffix("/edits") })
    }

    @Test func decidingAgainAfterApplyIsPendingAgain() async throws {
        serve(standardPile())
        let model = makeModel()
        await model.load()
        model.decide(.keep) // a
        await model.apply()
        #expect(model.plan.isEmpty)

        model.move(toAssetID: "a")
        model.decide(.archive)
        #expect(model.plan.archive.map(\.id) == ["a"])
        await model.apply()
        #expect(writes.last?.body["visibility"] as? String == "archive")
        let final = try store.allDecisions(userID: "u")
        #expect(final["a"]?.decision == .archive)
    }

    @Test func theLastResultDisappearsOnceThePlanChanges() async {
        serve(standardPile())
        let model = makeModel()
        await model.load()
        model.decide(.keep)
        await model.apply()
        #expect(model.lastOutcome != nil)

        model.decide(.delete)
        #expect(model.lastOutcome == nil, "a result from before the new decision would be misleading")
    }

    @Test func nothingIsSentWhenNothingIsPending() async {
        serve(standardPile())
        let model = makeModel()
        await model.load()
        await model.apply()
        #expect(writes.isEmpty)
        #expect(model.lastOutcome?.changedAnything == false)
    }
}
