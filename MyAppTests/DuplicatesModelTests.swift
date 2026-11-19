import Foundation
import Testing
@testable import Immich_Swipe_iOS

private let host = "duplicates.example.com"

private func assetJSON(_ id: String, size: Int? = 100, width: Int = 10, height: Int = 10, type: String = "IMAGE", favorite: Bool = false, created: String = "2024") -> String {
    let sizeField = size.map { #""fileSizeInByte":\#($0),"# } ?? ""
    return #"{"id":"\#(id)","ownerId":"u","fileCreatedAt":"\#(created)","type":"\#(type)","isFavorite":\#(favorite),"isArchived":false,"isTrashed":false,"exifInfo":{\#(sizeField)"exifImageWidth":\#(width),"exifImageHeight":\#(height)}}"#
}

private func asset(_ id: String, size: Int64? = 100, type: AssetType = .image, created: String = "2024") -> Asset {
    Asset(id: id, ownerId: "u", fileCreatedAt: created, type: type, exifInfo: ExifInfo(fileSizeInByte: size, exifImageWidth: 10, exifImageHeight: 10))
}

@MainActor
@Suite(.serialized)
struct DuplicatesModelTests {
    let client: ImmichClient
    let store: DecisionStore
    let listingCache = AssetListCache.temporary()

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingServer.self]
        client = ImmichClient(serverURL: URL(string: "https://\(host)")!, apiKey: "KEY", session: URLSession(configuration: configuration), retry: .none)
        store = try DecisionStore.inMemory()
    }

    private func makeModel() -> DuplicatesModel {
        DuplicatesModel(client: client, userID: "u", decisions: store, listingCache: listingCache)
    }

    /// A pair of photos and a group of three, one of them a video and one a favorite.
    private func serveGroups() {
        RoutingServer.route(host: host) { method, path, _ in
            switch (method, path) {
            case ("GET", "/api/duplicates"):
                return (200, """
                [{"duplicateId":"pair","assets":[\(assetJSON("p1", size: 10)),\(assetJSON("p2", size: 20))]},
                 {"duplicateId":"trio","assets":[\(assetJSON("t1", size: 5)),\(assetJSON("t2", size: 50, type: "VIDEO")),\(assetJSON("t3", size: 1, favorite: true))]}]
                """)
            case ("DELETE", "/api/assets"), ("PUT", "/api/assets"):
                return (204, "")
            default:
                return (404, "{}")
            }
        }
    }

    @Test func loadsGroupsBiggestFirstWithLargestFileFirst() async {
        serveGroups()
        let model = makeModel()
        await model.load()

        #expect(!model.isLoading)
        #expect(model.clusters.map(\.id) == ["trio", "pair"])
        #expect(model.clusters[0].assets.map(\.id) == ["t2", "t1", "t3"])
        #expect(model.clusters[1].assets.map(\.id) == ["p2", "p1"])
        #expect(model.totalCount == 5)
        #expect(model.remainingCount == 5)
    }

    @Test func sortOrdersPutPhotoOrVideoGroupsFirst() {
        let photos = DuplicatesModel.Cluster(id: "photos", assets: [asset("a"), asset("b")])
        let mixed = DuplicatesModel.Cluster(id: "mixed", assets: [asset("c", size: 1), asset("v", size: 999, type: .video), asset("d", size: 2)])
        let videos = DuplicatesModel.Cluster(id: "videos", assets: [asset("w", type: .video), asset("x", type: .video)])

        let bySize = DuplicatesModel.sorted([photos, videos, mixed], by: .clusterSize)
        #expect(bySize.first?.id == "mixed")

        let photosFirst = DuplicatesModel.sorted([videos, mixed, photos], by: .photosFirst)
        // Same photo count, so the bigger group wins.
        #expect(photosFirst.map(\.id) == ["mixed", "photos", "videos"])
        #expect(photosFirst[0].assets.map(\.id) == ["d", "c", "v"])

        let videosFirst = DuplicatesModel.sorted([photos, mixed, videos], by: .videosFirst)
        #expect(videosFirst.map(\.id) == ["videos", "mixed", "photos"])
        #expect(videosFirst[1].assets.first?.id == "v")
    }

    @Test func tapCyclesKeepDeleteNoneAndIsSaved() async throws {
        serveGroups()
        let model = makeModel()
        await model.load()
        let p1 = try #require(model.allAssets.first { $0.id == "p1" })

        model.toggle(p1)
        #expect(model.decision(for: p1) == .keep)
        #expect(try store.allDecisions(userID: "u")["p1"]?.albumID == Album.virtualDuplicatesID)

        model.toggle(p1)
        #expect(model.decision(for: p1) == .delete)
        #expect(try store.allDecisions(userID: "u")["p1"]?.decision == .delete)

        model.toggle(p1)
        #expect(model.decision(for: p1) == nil)
        #expect(try store.allDecisions(userID: "u")["p1"] == nil)
    }

    @Test func groupButtonClearsWhenAlreadyApplied() async throws {
        serveGroups()
        let model = makeModel()
        await model.load()
        let pair = try #require(model.clusters.first { $0.id == "pair" })

        model.setCluster(pair, to: .delete)
        #expect(pair.assets.allSatisfy { model.decision(for: $0) == .delete })
        #expect(model.deleteCount == 2)
        #expect(model.deleteBytes == 30)

        model.setCluster(pair, to: .delete)
        #expect(pair.assets.allSatisfy { model.decision(for: $0) == nil })
    }

    @Test func keepLargestSkipsVideosAndKeepsFavorites() async {
        serveGroups()
        let model = makeModel()
        await model.load()
        model.autoSelect(keepLargest: true)

        let decisions = Dictionary(uniqueKeysWithValues: model.allAssets.map { ($0.id, model.decision(for: $0)) })
        #expect(decisions["p2"] == .keep)
        #expect(decisions["p1"] == .delete)
        #expect(decisions["t1"] == .keep)
        #expect(decisions["t3"] == .keep) // favorite
        #expect(decisions["t2"] == .some(nil)) // video left alone
        #expect(model.autoSelectMode == .keepLargest)
    }

    @Test func autoSelectOnlyUnsortedLeavesDecidedGroupsAlone() async throws {
        serveGroups()
        let model = makeModel()
        await model.load()
        let pair = try #require(model.clusters.first { $0.id == "pair" })
        model.setCluster(pair, to: .delete)
        #expect(model.decidedClusterCount == 1)

        model.autoSelect(keepLargest: true, onlyUndecidedGroups: true)
        #expect(pair.assets.allSatisfy { model.decision(for: $0) == .delete })
        #expect(model.allAssets.first { $0.id == "t1" }.flatMap(model.decision(for:)) == .keep)
        #expect(model.decidedClusterCount == 2)

        model.autoSelect(keepLargest: true)
        #expect(model.allAssets.first { $0.id == "p2" }.flatMap(model.decision(for:)) == .keep)
    }

    @Test func undecidedOnlyFilterIsASnapshotUntilToggledOff() async throws {
        serveGroups()
        let model = makeModel()
        await model.load()
        let pair = try #require(model.clusters.first { $0.id == "pair" })
        model.setCluster(pair, to: .keep)

        model.toggleUndecidedOnly()
        #expect(model.visibleClusters.map(\.id) == ["trio"])

        // Sorting the shown group keeps it listed.
        let trio = try #require(model.clusters.first { $0.id == "trio" })
        model.setCluster(trio, to: .keep)
        #expect(model.visibleClusters.map(\.id) == ["trio"])

        model.toggleUndecidedOnly()
        #expect(model.visibleClusters.map(\.id) == ["trio", "pair"])

        // A reload turns the filter off.
        model.toggleUndecidedOnly()
        await model.load()
        #expect(model.undecidedOnlyIDs == nil)
    }

    @Test func smallestPutsUnknownSizesLast() {
        let ordered = DuplicatesModel.smallestFirst([asset("unknown", size: nil), asset("big", size: 50), asset("small", size: 5)])
        #expect(ordered.map(\.id) == ["small", "big", "unknown"])
    }

    @Test func resetClearsOnlyGroupAssets() async throws {
        serveGroups()
        try store.save(.delete, assetID: "elsewhere", albumID: "album", userID: "u", fileSize: 1)
        let model = makeModel()
        await model.load()
        model.autoSelect(keepLargest: true)
        model.reset()

        #expect(model.keepCount + model.deleteCount == 0)
        #expect(model.autoSelectMode == nil)
        #expect(try store.allDecisions(userID: "u").keys.sorted() == ["elsewhere"])
    }

    @Test func deletingSendsOnlyGroupAssetsAndRecordsHistory() async throws {
        serveGroups()
        try store.save(.delete, assetID: "elsewhere", albumID: "album", userID: "u", fileSize: 1)
        let model = makeModel()
        await model.load()
        let assets = Dictionary(uniqueKeysWithValues: model.allAssets.map { ($0.id, $0) })
        model.toggle(try #require(assets["p2"]))                    // keep
        model.toggle(try #require(assets["p1"])); model.toggle(try #require(assets["p1"])) // delete

        await model.deleteMarked()

        let delete = RoutingServer.requests(host: host).first { $0.method == "DELETE" }
        #expect(delete?.body["ids"] as? [String] == ["p1"])
        #expect(delete?.body["force"] as? Bool == false)
        let stored = try store.allDecisions(userID: "u")
        #expect(stored["p1"] == nil)
        #expect(stored["p2"]?.isSynced == true)
        #expect(stored["elsewhere"]?.decision == .delete)
        let history = try store.syncHistory(userID: "u")
        #expect(history.first?.deletedCount == 1 && history.first?.bytesSaved == 10 && history.first?.keptCount == 1)
        #expect(!model.isSyncing && model.syncError == nil)
    }

    @Test func deletedAssetsLeaveTheDecksSavedListings() async throws {
        serveGroups()
        let saved = ["p1", "p2", "other"].map { Asset(id: $0, ownerId: "u", fileCreatedAt: "2024", type: .image) }
        await listingCache.save(saved, userID: "u", albumID: Album.virtualAllID)
        let model = makeModel()
        await model.load()
        let p1 = try #require(model.allAssets.first { $0.id == "p1" })
        model.toggle(p1); model.toggle(p1) // delete

        await model.deleteMarked()

        #expect(await listingCache.assets(userID: "u", albumID: Album.virtualAllID).map(\.id) == ["p2", "other"])
    }

    @Test func alreadySyncedKeptAssetsAreNotCountedAgain() async throws {
        serveGroups()
        let model = makeModel()
        await model.load()
        let assets = Dictionary(uniqueKeysWithValues: model.allAssets.map { ($0.id, $0) })
        model.toggle(try #require(assets["p2"]))                    // keep, applied by an earlier sync
        try store.markSynced(assetIDs: ["p2"], userID: "u")
        model.toggle(try #require(assets["p1"])); model.toggle(try #require(assets["p1"])) // delete

        await model.deleteMarked()

        let history = try store.syncHistory(userID: "u")
        #expect(history.first?.deletedCount == 1 && history.first?.keptCount == 0)
    }

    @Test func favoritingKeepsTheAsset() async throws {
        serveGroups()
        let model = makeModel()
        await model.load()
        let p1 = try #require(model.allAssets.first { $0.id == "p1" })

        await model.toggleFavorite(p1)

        #expect(model.isFavorite(p1))
        #expect(model.decision(for: p1) == .keep)
        let update = RoutingServer.requests(host: host).first { $0.method == "PUT" }
        #expect(update?.body["isFavorite"] as? Bool == true)
    }

    @Test func formatsLikeAndroid() {
        #expect(DuplicateFormat.size(512 * 1024) == "512 KB")
        #expect(DuplicateFormat.size(3 * 1024 * 1024 + 512 * 1024) == "3.50 MB")
        #expect(DuplicateFormat.size(2 * 1024 * 1024 * 1024) == "2.00 GB")

        #expect(DuplicateFormat.middleEllipsis("short.jpg") == "short.jpg")
        #expect(DuplicateFormat.middleEllipsis("IMG_20240101_123456_HDR.jpg") == "IMG_…01_123456_HDR.jpg")
        #expect(DuplicateFormat.middleEllipsis("IMG_20240101_123456_HDR.jpg").count == 22)
    }
}
