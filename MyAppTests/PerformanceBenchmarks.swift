import Foundation
import Testing
@testable import Immich_Swipe_iOS

/// Timings for the work the app does with a large library: 100,000 photos, 30,000 of them decided.
/// These measure rather than check, so they always pass. Run them on their own, so other suites don't
/// compete for the CPU. They take a couple of minutes, so they're skipped unless `RUN_BENCHMARKS` is set
/// (xcodebuild passes `TEST_RUNNER_`-prefixed variables on). The test host's standard output doesn't reach
/// the xcodebuild log, so the results are added to `/tmp/immich-swipe-bench.txt` on the Mac (simulator
/// only). For optimised timings, build MyApp the same way first:
///
/// `TEST_RUNNER_RUN_BENCHMARKS=1 xcodebuild test -scheme MyAppTests -configuration Release ENABLE_TESTABILITY=YES -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MyAppTests/PerformanceBenchmarks`
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] != nil))
struct PerformanceBenchmarks {
    static let assetCount = 100_000
    static let decided = 30_000
    static let host = "bench.example.com"

    /// Newest first, as the server sends them; every tenth is a video.
    static let assets: [Asset] = {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<assetCount).map { index in
            Asset(
                id: String(format: "asset-%06d", index),
                ownerId: "u",
                fileCreatedAt: start.addingTimeInterval(Double(-index) * 600).ISO8601Format(),
                type: index % 10 == 0 ? .video : .image,
                exifInfo: ExifInfo(fileSizeInByte: Int64(1_000_000 + index * 7 % 5_000_000))
            )
        }
    }()

    /// Every third photo decided, cycling through the four decisions, until `decided` are.
    static let decisions: [String: SwipeDecision] = {
        let kinds = SwipeDecision.allCases
        return Dictionary(uniqueKeysWithValues: stride(from: 0, to: decided * 3, by: 3).enumerated().map { step, index in
            (assets[index].id, kinds[step % kinds.count])
        })
    }()

    // MARK: Deck logic

    @Test func perSwipeHeaderCounts() {
        let deck = Deck(assets: Self.assets, decisions: Self.decisions)
        measure("Deck.decidedCount, once") { deck.decidedCount }
        // What one refresh of the deck screen reads: remaining, progress, the reset button and the haptic
        // each read decidedCount, plus the kept and deleted counts.
        measure("Deck header counts, one screen refresh (6 passes)") {
            (0..<4).reduce(0) { total, _ in total + deck.decidedCount }
                + deck.pileCount(of: [.keep, .archive, .lock]) + deck.pileCount(of: [.delete])
        }
    }

    @Test func decidingOneCard() {
        var deck = Deck(assets: Self.assets, decisions: Self.decisions)
        measure("Deck.decideCurrent") { deck.decideCurrent(.keep) }
    }

    @Test func buildingTheApplyPlan() {
        let deck = Deck(assets: Self.assets, decisions: Self.decisions)
        measure("ApplyPlan.make") {
            ApplyPlan.make(deck: deck, pending: Set(Self.decisions.keys), favorites: [:], rotations: [:])
        }
    }

    @Test func reviewListGrouping() {
        let deck = Deck(assets: Self.assets, decisions: Self.decisions)
        measure("Review list grouping (decidedAssets)") {
            Dictionary(grouping: deck.assets.filter { deck.decision(for: $0.id) != nil }) { deck.decision(for: $0.id)! }
        }
    }

    @Test func sorting() {
        for order in [DeckSortOrder.chronologicalDescending, .sizeDescending, .shuffled, .videosFirst] {
            measure("Sort \(order.rawValue)", runs: 3) { order.sorted(Self.assets, seed: 1) }
        }
    }

    // MARK: Database

    @Test func database() async throws {
        // A tenth of the rows, to see whether the cost of a bulk save grows linearly or faster.
        let small = try DecisionStore.inMemory()
        let tenth = Dictionary(uniqueKeysWithValues: Self.decisions.keys.prefix(Self.decided / 10).map { ($0, Int64?(1_000_000)) })
        measure("DecisionStore: save 3,000 decisions in one call", runs: 1) {
            try? small.save(tenth, decision: .keep, albumID: Album.virtualAllID, userID: "u")
        }

        let store = try DecisionStore.inMemory()
        // On an empty store this is only the batched lookup that every bulk write starts with.
        measure("DecisionStore: look up 30,000 IDs in batches of 500 (empty store)", runs: 1) {
            try? store.remove(assetIDs: Array(Self.decisions.keys), userID: "u")
        }
        measure("DecisionStore: save 30,000 decisions in one call", runs: 1) {
            try? store.save(Self.decisions.mapValues { _ in Int64(1_000_000) }, decision: .keep, albumID: Album.virtualAllID, userID: "u")
        }
        measure("DecisionStore.markSynced 30,000 (Apply changes)", runs: 1) {
            try? store.markSynced(assetIDs: Array(Self.decisions.keys), userID: "u")
        }
        measure("DecisionStore.allDecisions, on the main actor") { try? store.allDecisions(userID: "u") }
        measure("DecisionStore.progressByAlbum + totals, on the main actor") {
            (try? store.progressByAlbum(userID: "u"), try? store.totals(userID: "u"))
        }
        // What the deck and Home now use: the same reads, with the main actor free while they run.
        await measureAsync("DecisionStore.allDecisionsInBackground (deck opens)", runs: 5) {
            _ = try? await store.allDecisionsInBackground(userID: "u")
        }
        await measureAsync("DecisionStore.progressByAlbumInBackground (Home appears)", runs: 5) {
            _ = try? await store.progressByAlbumInBackground(userID: "u")
        }
        var index = 0
        measure("DecisionStore.save one decision (each swipe)", runs: 11) {
            index += 1
            try? store.save(.delete, assetID: Self.assets[index * 3 + 1].id, albumID: Album.virtualAllID, userID: "u", fileSize: 1)
        }
    }

    // MARK: Whole deck

    @Test func openingAndSwipingADeck() async throws {
        Self.serveLibrary()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingServer.self]
        let client = ImmichClient(serverURL: URL(string: "https://\(Self.host)")!, apiKey: "KEY", session: URLSession(configuration: configuration), retry: .none)
        let store = try DecisionStore.inMemory()
        for (decision, ids) in Dictionary(grouping: Self.decisions.keys, by: { Self.decisions[$0]! }) {
            try store.save(Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(1_000_000)) }), decision: decision, albumID: Album.virtualAllID, userID: "u")
        }
        let defaults = UserDefaults(suiteName: "bench-\(UUID().uuidString)")!
        let cache = AssetListCache.temporary()
        func makeModel() -> DeckModel {
            DeckModel(title: "Bench", source: .all, client: client, userID: "u", decisions: store, shuffleSeed: 1, defaults: defaults, listingCache: cache)
        }

        var model = makeModel()
        await measureAsync("DeckModel.load, first open (200 pages, sorted as they land)", runs: 1) { await model.load() }
        #expect(model.deck.assets.count == Self.assetCount)
        await measureAsync("DeckModel.load, reopen (saved listing matches the server)", runs: 3) {
            model = makeModel()
            await model.load()
        }

        // One swipe as the main thread sees it, minus SwiftUI: the decision and its save, then what the
        // deck screen reads to redraw.
        measure("One swipe: DeckModel.decide + header reads", runs: 11) {
            model.decide(.keep)
            return model.remainingCount + model.deletedCount + model.keptCount + Int(model.progress) + model.decidedCount * 2
        }
        measure("DeckModel.plan (finished view, review sheet)") { model.plan }
    }

    /// The library in pages of 500 by cursor, as a v3.2+ server sends it.
    private static func serveLibrary() {
        let pageSize = 500
        let pages: [String] = stride(from: 0, to: assetCount, by: pageSize).map { start in
            let items = assets[start..<min(start + pageSize, assetCount)]
            let json = String(decoding: try! JSONEncoder().encode(Array(items)), as: UTF8.self)
            let next = start + pageSize < assetCount ? "\"p\(start / pageSize + 1)\"" : "null"
            return #"{"assets":{"items":\#(json),"total":\#(items.count),"nextPage":null,"nextCursor":\#(next)}}"#
        }
        let statistics = #"{"total":\#(assetCount)}"#
        RoutingServer.route(host: host) { path, body in
            switch path {
            case "/api/search/statistics":
                return (200, statistics)
            case "/api/search/metadata":
                let page = (body["cursor"] as? String).flatMap { Int($0.dropFirst()) } ?? 0
                return (200, pages[page])
            default:
                return (404, "{}")
            }
        }
    }

    // MARK: Timing

    /// Runs `work` several times and logs the median.
    private func measure<T>(_ label: String, runs: Int = 5, _ work: () -> T) {
        report(label, (0..<runs).map { _ in
            let start = ContinuousClock.now
            blackHole(work())
            return ContinuousClock.now - start
        })
    }

    private func measureAsync(_ label: String, runs: Int, _ work: () async -> Void) async {
        var times: [Duration] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            await work()
            times.append(ContinuousClock.now - start)
        }
        report(label, times)
    }

    private func report(_ label: String, _ times: [Duration]) {
        let median = times.sorted()[times.count / 2]
        let milliseconds = Double(median.components.seconds) * 1000 + Double(median.components.attoseconds) / 1e15
        let line = "\(label): \(String(format: "%.2f", milliseconds)) ms\n"
        let url = URL(filePath: "/tmp/immich-swipe-bench.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Keeps the optimiser from dropping work whose result is unused.
@inline(never)
private func blackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}
