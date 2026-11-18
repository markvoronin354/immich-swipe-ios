import Foundation
import Testing
@testable import Immich_Swipe_iOS

struct HomeSectionsTests {
    private let albums = [
        Album(id: "a", albumName: "Holidays", description: "Summer trip", assetCount: 10),
        Album(id: "b", albumName: "Pets", assetCount: 4),
        Album(id: "c", albumName: "Receipts", assetCount: 0),
        Album(id: "skip", albumName: "SKIP", assetCount: 3),
    ]

    private func make(
        counts: HomeSections.CollectionCounts = .init(all: 100, orphans: 5, duplicates: 0),
        progress: [String: AlbumProgress] = [:],
        query: String = ""
    ) -> HomeSections {
        HomeSections.make(albums: albums, counts: counts, progress: progress, totalProgress: AlbumProgress(decided: 7, unsynced: 2), names: HomeModel.name(for:), query: query)
    }

    @Test func albumsWithNothingToSortGoUnderCompleted() {
        let sections = HomeSections.make(albums: albums, counts: .init(all: 1, orphans: 0, duplicates: 0), progress: [:], totalProgress: AlbumProgress(), nothingToSort: ["a"], names: HomeModel.name(for:))
        #expect(sections.completed.map(\.id) == ["a"])
        #expect(sections.completed.first?.nothingToSort == true)
        #expect(!sections.notStarted.contains { $0.id == "a" })
    }

    @Test func nothingToSortIsRememberedPerAccount() {
        let defaults = UserDefaults(suiteName: "nothing-to-sort-\(UUID().uuidString)")!
        NothingToSort.set(true, albumID: "a", userID: "me", defaults: defaults)
        NothingToSort.set(true, albumID: "b", userID: "other", defaults: defaults)
        #expect(NothingToSort.ids(userID: "me", defaults: defaults) == ["a"])
        NothingToSort.set(false, albumID: "a", userID: "me", defaults: defaults)
        #expect(NothingToSort.ids(userID: "me", defaults: defaults).isEmpty)
        #expect(NothingToSort.ids(userID: "other", defaults: defaults) == ["b"])
    }

    @Test func groupsAlbumsByProgressKeepingServerOrder() {
        let sections = make(progress: ["a": AlbumProgress(decided: 3, unsynced: 1), "b": AlbumProgress(decided: 4, unsynced: 0)])
        #expect(sections.inProgress.map(\.id) == ["a"])
        #expect(sections.completed.map(\.id) == ["b"])
        #expect(sections.notStarted.map(\.id) == ["c"])
    }

    @Test func hidesSkipAlbumAndEmptyCollectionsButKeepsFailedCounts() {
        let sections = make(counts: .init(all: 100, orphans: nil, duplicates: 0))
        #expect(sections.collections.map(\.kind) == [.all, .orphans])
        #expect(sections.collections[1].assetCount == nil)
        #expect(!sections.notStarted.contains { $0.id == "skip" })
    }

    @Test func allPhotosUsesGlobalProgress() {
        let all = make().collections.first { $0.kind == .all }
        #expect(all?.progress == AlbumProgress(decided: 7, unsynced: 2))
    }

    @Test func decidedCountIsCappedAtAlbumSize() {
        // An album can shrink after decisions were made in it.
        let sections = make(progress: ["b": AlbumProgress(decided: 9, unsynced: 0)])
        let pets = sections.completed.first { $0.id == "b" }
        #expect(pets?.decidedCount == 4)
    }

    @Test func emptyAlbumIsNeverCompleted() {
        #expect(make(progress: ["c": AlbumProgress(decided: 0, unsynced: 0)]).notStarted.contains { $0.id == "c" })
    }

    @Test func searchMatchesNameOrDescriptionIgnoringCase() {
        #expect(make(query: "pets").notStarted.map(\.id) == ["b"])
        #expect(make(query: "summer").notStarted.map(\.id) == ["a"])
        #expect(make(query: "zzz").isEmpty)
        #expect(make(query: "  ").notStarted.count == 3)
    }
}

@MainActor
struct DecisionProgressTests {
    @Test func countsDecidedAndUnsyncedPerAlbum() throws {
        let store = try DecisionStore.inMemory()
        try store.save(.keep, assetID: "1", albumID: "a", userID: "u", fileSize: nil)
        try store.save(.delete, assetID: "2", albumID: "a", userID: "u", fileSize: nil)
        try store.save(.keep, assetID: "3", albumID: "b", userID: "u", fileSize: nil)
        try store.save(.keep, assetID: "4", albumID: "a", userID: "other", fileSize: nil)
        try store.markSynced(assetIDs: ["1"], userID: "u")

        let progress = try store.progressByAlbum(userID: "u")
        #expect(progress["a"] == AlbumProgress(decided: 2, unsynced: 1))
        #expect(progress["b"] == AlbumProgress(decided: 1, unsynced: 1))
        #expect(progress.count == 2)
    }
}

/// "Include external archives" on the home screen: what the collection and album counts include.
@MainActor
@Suite(.serialized)
struct HomeModelArchiveCountTests {
    private static let host = "home.example.com"
    let defaults = UserDefaults(suiteName: "home-tests-\(UUID().uuidString)")!

    private func makeModel() throws -> HomeModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingServer.self]
        let client = ImmichClient(serverURL: URL(string: "https://\(Self.host)")!, apiKey: "KEY", session: URLSession(configuration: configuration), retry: .none)
        return HomeModel(client: client, userID: "u", decisions: try DecisionStore.inMemory(), defaults: defaults)
    }

    /// 100 timeline and 7 archived photos, 20 and 3 of them in no album; album "a" has 10, 4 archived.
    private func serve() {
        RoutingServer.route(host: Self.host) { path, body in
            switch path {
            case "/api/albums":
                return (200, #"[{"id":"a","albumName":"A","assetCount":10}]"#)
            case "/api/search/statistics":
                let archived = body["visibility"] as? String == "archive"
                if body["albumIds"] != nil { return (200, #"{"total":\#(archived ? 4 : 6)}"#) }
                if body["isNotInAlbum"] as? Bool == true { return (200, #"{"total":\#(archived ? 3 : 20)}"#) }
                return (200, #"{"total":\#(archived ? 7 : 100)}"#)
            case "/api/duplicates":
                return (200, "[]")
            default:
                return (404, "{}")
            }
        }
    }

    @Test func includingArchivesAddsThemToTheCounts() async throws {
        serve()
        let model = try makeModel()
        await model.load()
        #expect(model.counts.all == 107)
        #expect(model.counts.orphans == 23)
        #expect(model.albums.first?.assetCount == 10)
    }

    @Test func excludingArchivesCountsTheTimelineAndRefinesAlbums() async throws {
        defaults.set(false, forKey: Setting.Key.includeArchived)
        serve()
        let model = try makeModel()
        await model.load()
        #expect(model.counts.all == 100)
        #expect(model.counts.orphans == 20)
        #expect(model.albums.first?.assetCount == 6)
    }
}
