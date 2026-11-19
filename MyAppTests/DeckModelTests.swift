import Foundation
import Testing
@testable import Immich_Swipe_iOS

/// Fake server that answers by path. Routes are kept per host, so test suites running at the same
/// time each get their own server by using their own host name.
final class RoutingServer: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String, _ body: [String: Any]) -> (status: Int, json: String)
    typealias MethodHandler = @Sendable (_ method: String, _ path: String, _ body: [String: Any]) -> (status: Int, json: String)
    typealias Request = (method: String, path: String, body: [String: Any])

    static let defaultHost = "photos.example.com"

    private final class Route: @unchecked Sendable {
        var handler: MethodHandler
        var log: [Request] = []
        init(_ handler: @escaping MethodHandler) { self.handler = handler }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    static func route(host: String = defaultHost, _ handler: @escaping Handler) {
        route(host: host) { _, path, body in handler(path, body) }
    }

    static func route(host: String = defaultHost, _ handler: @escaping MethodHandler) {
        lock.withLock { routes[host] = Route(handler) }
    }

    static func requests(host: String = defaultHost) -> [Request] {
        lock.withLock { routes[host]?.log ?? [] }
    }

    static var searchBodies: [[String: Any]] {
        requests().filter { $0.path == "/api/search/metadata" }.map(\.body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let method = request.httpMethod ?? ""
        let path = request.url?.path() ?? ""
        let host = request.url?.host() ?? ""
        let reply: (status: Int, json: String) = Self.lock.withLock {
            guard let route = Self.routes[host] else { return (404, "{}") }
            route.log.append((method, path, body))
            return route.handler(method, path, body)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func assetJSON(_ id: String, date: String, size: Int = 100, type: String = "IMAGE", owner: String = "u") -> String {
    #"{"id":"\#(id)","ownerId":"\#(owner)","fileCreatedAt":"\#(date)","type":"\#(type)","isFavorite":false,"isArchived":false,"isTrashed":false,"exifInfo":{"fileSizeInByte":\#(size)}}"#
}

@MainActor
@Suite(.serialized)
struct DeckModelTests {
    let client: ImmichClient
    let store: DecisionStore
    let defaults: UserDefaults
    /// Shared by every model in one test, so a test can reopen a deck and see what the last one saved.
    let listingCache = AssetListCache.temporary()

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingServer.self]
        client = ImmichClient(serverURL: URL(string: "https://photos.example.com")!, apiKey: "KEY", session: URLSession(configuration: configuration), retry: .none)
        store = try DecisionStore.inMemory()
        defaults = UserDefaults(suiteName: "deck-tests-\(UUID().uuidString)")!
    }

    private func makeModel(_ source: DeckSource) -> DeckModel {
        DeckModel(title: "Test", source: source, client: client, userID: "u", decisions: store, shuffleSeed: 1, defaults: defaults, listingCache: listingCache)
    }

    /// Three pages served by cursor, newest first as the server sends them, but shuffled within a page
    /// so sorting is observable.
    private func serveThreePages() {
        RoutingServer.route { path, body in
            switch path {
            case "/api/search/statistics":
                return (200, #"{"total":5}"#)
            case "/api/search/metadata":
                switch body["cursor"] as? String {
                case nil:
                    return (200, #"{"assets":{"items":[\#(assetJSON("d", date: "2024-04")),\#(assetJSON("e", date: "2024-05"))],"total":2,"nextPage":null,"nextCursor":"c2"}}"#)
                case "c2":
                    return (200, #"{"assets":{"items":[\#(assetJSON("c", date: "2024-03")),\#(assetJSON("d", date: "2024-04"))],"total":2,"nextPage":null,"nextCursor":"c3"}}"#)
                default:
                    return (200, #"{"assets":{"items":[\#(assetJSON("a", date: "2024-01")),\#(assetJSON("b", date: "2024-02"))],"total":2,"nextPage":null,"nextCursor":null}}"#)
                }
            default:
                return (404, "{}")
            }
        }
    }

    @Test func loadsEveryPageDedupesAndSorts() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()

        #expect(model.phase == .ready)
        #expect(!model.isLoadingMore)
        #expect(model.serverTotal == 5)
        // Default order is newest first, and "d" appeared on two pages but is listed once.
        #expect(model.deck.assets.map(\.id) == ["e", "d", "c", "b", "a"])
        #expect(model.deck.current?.id == "e")

        let bodies = RoutingServer.searchBodies
        #expect(bodies.count == 3)
        #expect(bodies.map { $0["cursor"] as? String } == [nil, "c2", "c3"])
        // "Include external archives" is on by default, so no visibility is sent: timeline and archive.
        #expect(bodies.allSatisfy { $0["visibility"] == nil && $0["withExif"] as? Bool == true })
    }

    @Test func albumDeckSearchesByAlbumWithoutVisibilityFilter() async {
        serveThreePages()
        await makeModel(.album(id: "alb1")).load()
        let first = RoutingServer.searchBodies.first
        #expect(first?["albumIds"] as? [String] == ["alb1"])
        #expect(first?["visibility"] == nil)
    }

    @Test func excludingArchivesSearchesTheTimelineOnlyWithItsOwnListing() async {
        defaults.set(false, forKey: Setting.Key.includeArchived)
        serveThreePages()
        await makeModel(.all).load()
        #expect(RoutingServer.searchBodies.allSatisfy { $0["visibility"] as? String == "timeline" })
        #expect(await listingCache.assets(userID: "u", albumID: Album.virtualAllID).isEmpty)
        #expect(await listingCache.assets(userID: "u", albumID: "\(Album.virtualAllID)-timeline").count == 5)

        await makeModel(.album(id: "alb1")).load()
        #expect(RoutingServer.searchBodies.last?["visibility"] as? String == "timeline")
    }

    @Test func photosOwnedByOtherUsersAreSkippedAndTheirPendingDecisionsDropped() async throws {
        try store.save(.delete, assetID: "theirs", albumID: "shared", userID: "u", fileSize: 100)
        try store.save(.delete, assetID: "mine", albumID: "shared", userID: "u", fileSize: 100)
        RoutingServer.route { path, _ in
            switch path {
            case "/api/search/statistics":
                return (200, #"{"total":3}"#)
            case "/api/search/metadata":
                return (200, #"{"assets":{"items":[\#(assetJSON("mine", date: "2024-02")),\#(assetJSON("theirs", date: "2024-01", owner: "other")),\#(assetJSON("mine2", date: "2024-03"))],"total":3,"nextPage":null,"nextCursor":null}}"#)
            default:
                return (404, "{}")
            }
        }
        let model = makeModel(.album(id: "shared"))
        await model.load()

        #expect(model.deck.assets.map(\.id) == ["mine2", "mine"])
        #expect(model.serverTotal == 2)
        // The decision on the other user's photo could never be applied, so it is gone. The rest stay.
        let remaining = try store.allDecisions(userID: "u")
        #expect(remaining["theirs"] == nil)
        #expect(remaining["mine"] != nil)
    }

    @Test func anAlbumOfOnlyOtherUsersPhotosIsRecordedAsNothingToSort() async {
        RoutingServer.route { path, _ in
            switch path {
            case "/api/search/statistics": return (200, #"{"total":1}"#)
            case "/api/search/metadata":
                return (200, #"{"assets":{"items":[\#(assetJSON("theirs", date: "2024-01", owner: "other"))],"total":1,"nextPage":null,"nextCursor":null}}"#)
            default: return (404, "{}")
            }
        }
        await makeModel(.album(id: "shared")).load()
        #expect(NothingToSort.ids(userID: "u", defaults: defaults) == ["shared"])

        // Once it has photos of the user's own again, it is back in the normal groups.
        serveThreePages()
        await makeModel(.album(id: "shared")).load()
        #expect(NothingToSort.ids(userID: "u", defaults: defaults).isEmpty)
    }

    @Test func albumPickerHidesAlbumsSharedAsViewer() async throws {
        RoutingServer.route { path, _ in
            guard path == "/api/albums" else { return (404, "{}") }
            return (200, #"""
            [{"id":"own","albumName":"Own","assetCount":1,"ownerId":"u","albumUsers":[]},
             {"id":"edit","albumName":"Edit","assetCount":1,"ownerId":"o","albumUsers":[{"role":"editor","user":{"id":"u"}}]},
             {"id":"view","albumName":"View","assetCount":1,"ownerId":"o","albumUsers":[{"role":"viewer","user":{"id":"u"}}]},
             {"id":"old","albumName":"Old","assetCount":1}]
            """#)
        }
        let albums = try await makeModel(.all).loadAlbums()
        #expect(Set(albums.map(\.id)) == ["own", "edit", "old"])
    }

    @Test func picksUpStoredDecisionsMadeElsewhereAndRestoresUndo() async throws {
        try store.save(.delete, assetID: "e", albumID: Album.virtualAllID, userID: "u", fileSize: 100)
        try store.save(.keep, assetID: "d", albumID: "someAlbum", userID: "u", fileSize: 100)
        try store.markSynced(assetIDs: ["d"], userID: "u")
        serveThreePages()

        let model = makeModel(.album(id: "alb1"))
        await model.load()

        #expect(model.deck.decision(for: "e") == .delete)
        #expect(model.deck.decision(for: "d") == .keep)
        #expect(model.deck.current?.id == "c")
        #expect(model.decidedCount == 2)
        // Only the unsynced decision can be undone.
        #expect(model.deck.history == ["e"])
    }

    @Test func decisionsAndUndoArePersisted() async throws {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()

        model.decide(.delete)
        model.decide(.archive)
        var saved = try store.allDecisions(userID: "u")
        #expect(saved["e"]?.decision == .delete && saved["e"]?.albumID == Album.virtualAllID && saved["e"]?.fileSize == 100)
        #expect(saved["d"]?.decision == .archive)

        model.undo()
        saved = try store.allDecisions(userID: "u")
        #expect(saved["d"] == nil)
        #expect(model.deck.current?.id == "d")
        #expect(model.saveError == nil)
    }

    @Test func changingSortOrderResortsAndIsRemembered() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.decide(.keep) // e

        await model.setSortOrder(.chronologicalAscending)
        #expect(model.deck.assets.map(\.id) == ["a", "b", "c", "d", "e"])
        #expect(model.deck.current?.id == "a")
        #expect(makeModel(.all).sortOrder == .chronologicalAscending)
    }

    /// As on Android, picking the order already in use goes back to the first undecided photo.
    @Test func repickingTheSortOrderGoesBackToTheFirstUndecidedPhoto() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.decide(.keep) // e
        model.move(toAssetID: "b")

        await model.setSortOrder(model.sortOrder)
        #expect(model.deck.current?.id == "d")
        #expect(model.deck.assets.map(\.id) == ["e", "d", "c", "b", "a"])
    }

    @Test func resetForgetsDecisionsForThisDeck() async throws {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.decide(.delete)
        model.decide(.delete)

        model.resetDecisions()
        #expect(model.decidedCount == 0)
        #expect(try store.allDecisions(userID: "u").isEmpty)
    }

    @Test func duplicatesKeepClusterOrderAndIgnoreSorting() async {
        RoutingServer.route { path, _ in
            guard path == "/api/duplicates" else { return (404, "{}") }
            return (200, """
            [{"duplicateId":"small","assets":[\(assetJSON("s1", date: "2024", size: 10)),\(assetJSON("s2", date: "2024", size: 20))]},
             {"duplicateId":"big","assets":[\(assetJSON("b1", date: "2024", size: 5)),\(assetJSON("b2", date: "2024", size: 50)),\(assetJSON("b3", date: "2024", size: 1))]}]
            """)
        }
        let model = makeModel(.duplicates)
        await model.load()
        // Largest cluster first; within a cluster, largest file first.
        #expect(model.deck.assets.map(\.id) == ["b2", "b1", "b3", "s2", "s1"])
        #expect(model.serverTotal == 5)

        await model.setSortOrder(.chronologicalAscending)
        #expect(model.deck.assets.map(\.id) == ["b2", "b1", "b3", "s2", "s1"])
    }

    @Test func favouriteAndRotationStayLocalAndCancelOut() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        let current = try! #require(model.deck.current)

        model.toggleFavoriteForCurrent()
        #expect(model.isFavorite(current))
        #expect(model.favoriteOverrides == [current.id: true])
        model.toggleFavoriteForCurrent()
        // Back to the server value, so there's nothing left to send.
        #expect(model.favoriteOverrides.isEmpty)

        model.rotateCurrent()
        model.rotateCurrent()
        #expect(model.rotation(of: current) == 180)
        model.rotateCurrent()
        model.rotateCurrent()
        #expect(model.rotation(of: current) == 0)
        #expect(model.rotations.isEmpty)
    }

    @Test func favoriteSwipeFavoritesAndKeepsAndUndoTakesItBack() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()

        model.swipe(.favorite) // e
        #expect(model.deck.decision(for: "e") == .keep)
        #expect(model.favoriteOverrides == ["e": true])
        #expect(model.deck.current?.id == "d")

        model.undo()
        #expect(model.deck.current?.id == "e")
        #expect(model.deck.decision(for: "e") == nil)
        #expect(model.favoriteOverrides.isEmpty, "the heart the swipe added goes with it")
    }

    @Test func favoriteSwipeOnAFavoriteLeavesItAlone() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.toggleFavoriteForCurrent() // e was already a favourite before the swipe

        model.swipe(.favorite)
        #expect(model.favoriteOverrides == ["e": true], "sets rather than toggles")
        model.undo()
        #expect(model.favoriteOverrides == ["e": true], "undo doesn't take away a heart the swipe didn't add")
    }

    @Test func favoriteSwipeRemovedFromReviewTakesTheHeartBack() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.swipe(.favorite) // e
        model.removeDecision(for: "e")
        #expect(model.favoriteOverrides.isEmpty)
    }

    @Test func undoAndDetailsSwipesRecordNothing() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.swipe(.archive) // e
        #expect(model.deck.decision(for: "e") == .archive)

        model.swipe(.details)
        #expect(model.deck.current?.id == "d" && model.decidedCount == 1)
        model.swipe(.undo)
        #expect(model.deck.current?.id == "e" && model.decidedCount == 0)
    }

    @Test func aSwipeLandsOnThePhotoItStartedOnEvenIfAnotherBecameCurrent() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        // The card "e" is thrown; while it flies, a page lands and makes "c" current.
        model.move(toAssetID: "c")
        model.swipe(.delete, on: "e")

        #expect(model.deck.decision(for: "e") == .delete)
        #expect(model.deck.decision(for: "c") == nil)
        // The deck carries on after the photo that was swiped, as the card behind it showed.
        #expect(model.deck.current?.id == "d")
    }

    @Test func aSwipeOnAPhotoThatLeftTheDeckDoesNothing() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.swipe(.delete, on: "gone")
        #expect(model.decidedCount == 0)
        #expect(model.deck.current?.id == "e")
    }

    @Test func countsAndStripNavigation() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.decide(.keep)    // e
        model.decide(.archive) // d
        model.decide(.delete)  // c

        #expect(model.keptCount == 2)
        #expect(model.deletedCount == 1)
        #expect(model.remainingCount == 2)

        // Tapping a decided photo in the strip shows it; deciding again replaces the decision.
        model.move(toAssetID: "e")
        #expect(model.deck.current?.id == "e")
        model.decide(.delete)
        #expect(model.deck.decision(for: "e") == .delete)
        #expect(model.deletedCount == 2)
        #expect(model.decidedAssets()[.delete]?.map(\.id).sorted() == ["c", "e"])
    }

    @Test func removingADecisionFromReviewIsPersisted() async throws {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        model.decide(.delete) // e
        model.removeDecision(for: "e")
        #expect(model.deck.decision(for: "e") == nil)
        #expect(try store.allDecisions(userID: "u").isEmpty)
    }

    @Test func immichLinkPointsAtTheWebPhotoPage() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        #expect(model.immichURL(for: model.deck.current!).absoluteString == "https://photos.example.com/photos/e")
    }

    @Test func immichAppLinkUsesTheAssetDeepLink() async {
        serveThreePages()
        let model = makeModel(.all)
        await model.load()
        #expect(model.immichAppURL(for: model.deck.current!).absoluteString == "immich://asset?id=e")
    }

    @Test func addToAlbumTreatsDuplicateAsSuccess() async throws {
        RoutingServer.route { path, body in
            guard path == "/api/albums/alb1/assets" else { return (404, "{}") }
            let ids = body["ids"] as? [String] ?? []
            return (200, ids == ["dup"] ? #"[{"id":"dup","success":false,"error":"duplicate"}]"# : #"[{"id":"x","success":false,"error":"no_permission"}]"#)
        }
        let model = makeModel(.all)
        let album = Album(id: "alb1", albumName: "Trip", assetCount: 0)
        try await model.add(Asset(id: "dup", ownerId: "u", fileCreatedAt: "", type: .image), to: album)
        await #expect(throws: ImmichError.self) {
            try await model.add(Asset(id: "x", ownerId: "u", fileCreatedAt: "", type: .image), to: album)
        }
    }

    @Test func albumsLastAddedToComeFirst() async throws {
        RoutingServer.route { path, body in
            switch path {
            case "/api/albums" where body["albumName"] != nil:
                return (201, #"{"id":"new","albumName":"New","assetCount":1}"#)
            case "/api/albums":
                return (200, #"[{"id":"c","albumName":"Cats","assetCount":0},{"id":"a","albumName":"Art","assetCount":0},{"id":"new","albumName":"New","assetCount":1},{"id":"b","albumName":"Beach","assetCount":0}]"#)
            case "/api/albums/c/assets":
                return (200, #"[{"id":"p","success":true}]"#)
            default:
                return (404, "{}")
            }
        }
        let model = makeModel(.all)
        let asset = Asset(id: "p", ownerId: "u", fileCreatedAt: "", type: .image)
        #expect(try await model.loadAlbums().map(\.id) == ["a", "b", "c", "new"])

        try await model.add(asset, to: Album(id: "c", albumName: "Cats", assetCount: 0))
        _ = try await model.createAlbum(named: "New", with: asset)
        #expect(try await model.loadAlbums().map(\.id) == ["new", "c", "a", "b"])

        // Using an album again moves it back to the front instead of listing it twice.
        try await model.add(asset, to: Album(id: "c", albumName: "Cats", assetCount: 0))
        #expect(defaults.string(forKey: DeckModel.recentAlbumIDsKey) == "c,new")
    }

    @Test func failureBeforeAnyPageIsReported() async {
        RoutingServer.route { _, _ in (500, #"{"message":"boom"}"#) }
        let model = makeModel(.all)
        await model.load()
        guard case .failed = model.phase else {
            Issue.record("expected failure, got \(model.phase)")
            return
        }
    }

    @Test func laterPageFailureKeepsWhatLoaded() async {
        RoutingServer.route { path, body in
            if path == "/api/search/statistics" { return (200, #"{"total":4}"#) }
            if body["cursor"] == nil {
                return (200, #"{"assets":{"items":[\#(assetJSON("a", date: "2024-01"))],"total":1,"nextPage":null,"nextCursor":"next"}}"#)
            }
            return (500, "{}")
        }
        let model = makeModel(.all)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.deck.assets.map(\.id) == ["a"])
        #expect(model.total == 4)
    }

    /// As on Android, a non-date order holds the pages back and adds them all at the end.
    @Test func shuffledSyncAddsEveryPageAtTheEnd() async {
        defaults.set(DeckSortOrder.shuffled.rawValue, forKey: DeckModel.sortOrderKey)
        serveThreePages()
        let model = makeModel(.all)
        await model.load()

        #expect(model.phase == .ready)
        #expect(Set(model.deck.assets.map(\.id)) == ["a", "b", "c", "d", "e"])
        #expect(model.deck.assets.count == 5)
        #expect(model.syncedCount == 5)
        #expect(model.deck.current?.id == model.deck.assets.first?.id)
    }

    @Test func shuffledSyncKeepsHeldPagesWhenALaterPageFails() async {
        defaults.set(DeckSortOrder.shuffled.rawValue, forKey: DeckModel.sortOrderKey)
        RoutingServer.route { path, body in
            if path == "/api/search/statistics" { return (200, #"{"total":4}"#) }
            if body["cursor"] == nil {
                return (200, #"{"assets":{"items":[\#(assetJSON("a", date: "2024-01"))],"total":1,"nextPage":null,"nextCursor":"next"}}"#)
            }
            return (500, "{}")
        }
        let model = makeModel(.all)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.deck.assets.map(\.id) == ["a"])
    }

    // MARK: Saved listing (spec §3.5)

    /// Serves `ids` newest first, two per page, as (id, date) pairs. The detail endpoint marks every photo a favourite.
    private func serveNewestFirst(_ assets: [(String, String)]) {
        RoutingServer.route { path, body in
            switch path {
            case "/api/search/statistics":
                return (200, #"{"total":\#(assets.count)}"#)
            case "/api/search/metadata":
                let page = Int(body["cursor"] as? String ?? "0") ?? 0
                let items = assets.dropFirst(page * 2).prefix(2).map { assetJSON($0.0, date: $0.1) }.joined(separator: ",")
                let next = (page + 1) * 2 < assets.count ? #""\#(page + 1)""# : "null"
                return (200, #"{"assets":{"items":[\#(items)],"total":2,"nextPage":null,"nextCursor":\#(next)}}"#)
            default:
                if let id = path.split(separator: "/").last, path.hasPrefix("/api/assets/") {
                    return (200, assetJSON(String(id), date: assets.first { $0.0 == id }?.1 ?? "").replacingOccurrences(of: #""isFavorite":false"#, with: #""isFavorite":true"#))
                }
                return (404, "{}")
            }
        }
    }

    private let library = [("e", "2024-05"), ("d", "2024-04"), ("c", "2024-03"), ("b", "2024-02"), ("a", "2024-01")]

    @Test func reopeningUsesTheSavedListingWhenItMatchesTheServer() async {
        serveNewestFirst(library)
        await makeModel(.all).load()
        #expect(RoutingServer.searchBodies.count == 3)

        let model = makeModel(.all)
        await model.load()
        // Only the first page was needed to confirm the saved listing is current.
        #expect(RoutingServer.searchBodies.count == 4)
        #expect(model.deck.assets.map(\.id) == ["e", "d", "c", "b", "a"])
        #expect(model.deck.current?.id == "e")
        #expect(!model.isLoadingMore)
    }

    @Test func changedLibraryIsPagedAgainAndDropsRemovedPhotos() async {
        serveNewestFirst(library)
        await makeModel(.all).load()

        // "c" is gone and "f" is new: same total, but the first page has something new.
        serveNewestFirst([("f", "2024-06"), ("e", "2024-05"), ("d", "2024-04"), ("b", "2024-02"), ("a", "2024-01")])
        let model = makeModel(.all)
        await model.load()
        #expect(model.deck.assets.map(\.id) == ["f", "e", "d", "b", "a"])
        #expect(await listingCache.assets(userID: "u", albumID: Album.virtualAllID).map(\.id).sorted() == ["a", "b", "d", "e", "f"])
    }

    @Test func aSavedPhotoWhoseDateChangedMovesToItsNewPlace() async {
        serveNewestFirst(library)
        await makeModel(.all).load()

        // "a" now has a later date, so the server sends it first; the saved copy still has the old one.
        serveNewestFirst([("a", "2024-09"), ("e", "2024-05"), ("d", "2024-04"), ("c", "2024-03"), ("b", "2024-02")])
        let model = makeModel(.all)
        await model.load()
        #expect(model.deck.assets.map(\.id) == ["a", "e", "d", "c", "b"])
    }

    @Test func savedListingIsShownWhenTheServerIsUnreachable() async {
        serveNewestFirst(library)
        await makeModel(.all).load()

        RoutingServer.route { _, _ in (500, #"{"message":"boom"}"#) }
        let model = makeModel(.all)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.deck.assets.map(\.id) == ["e", "d", "c", "b", "a"])
    }

    @Test func savedListingIsKeptPerAlbum() async {
        serveNewestFirst(library)
        await makeModel(.album(id: "alb1")).load()
        #expect(await listingCache.assets(userID: "u", albumID: "alb1").count == 5)
        #expect(await listingCache.assets(userID: "u", albumID: Album.virtualAllID).isEmpty)
    }

    @Test func currentCardPicksUpTheServersLatestDetails() async {
        serveNewestFirst(library)
        let model = makeModel(.all)
        await model.load()
        #expect(model.deck.current?.isFavorite == false)
        await model.loadCurrentDetails()
        #expect(model.deck.current?.id == "e")
        #expect(model.deck.current?.isFavorite == true)
    }
}

extension AssetListCache {
    /// A cache in its own temporary folder, so tests never see each other's listings.
    static func temporary() -> AssetListCache {
        AssetListCache(directory: FileManager.default.temporaryDirectory.appending(path: "listing-\(UUID().uuidString)", directoryHint: .isDirectory))
    }
}
