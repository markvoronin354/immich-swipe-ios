import Foundation
import Observation

/// Loads everything the home screen shows: albums, collection counts, local progress and the server version.
@Observable
final class HomeModel {
    private(set) var albums: [Album] = []
    private(set) var counts = HomeSections.CollectionCounts()
    private(set) var progress: [String: AlbumProgress] = [:]
    private(set) var totalProgress = AlbumProgress()
    /// Albums that hold only other users' photos.
    private(set) var nothingToSort: Set<String> = []
    private(set) var serverVersion: ServerVersion?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Set when the album list itself failed. Count failures only blank out that count.
    private(set) var errorMessage: String?

    let client: ImmichClient
    let userID: String
    let decisions: DecisionStore
    private let defaults: UserDefaults

    init(client: ImmichClient, userID: String, decisions: DecisionStore, defaults: UserDefaults = .standard) {
        self.client = client
        self.userID = userID
        self.decisions = decisions
        self.defaults = defaults
    }

    /// Fetches albums, counts and version from the server in parallel, then refreshes local progress.
    func load() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }

        AppLog.d("Home", "Loading user data and albums")
        let client = client
        // Counts match what the decks show (spec §3.7 quirk 2): with "Include external archives", "All"
        // and "Orphans" add the archived total, as on Android. Without it they count the timeline only.
        let includeArchived = defaults.object(forKey: Setting.Key.includeArchived) as? Bool ?? Setting.Default.includeArchived
        async let albumsResult = Result { try await client.getAllAlbums() }
        async let allResult = Result { try await Self.count(StatisticsSearch(), includeArchived: includeArchived, client: client) }
        async let orphansResult = Result { try await Self.count(StatisticsSearch(isNotInAlbum: true), includeArchived: includeArchived, client: client) }
        async let duplicatesResult = Result { try await client.getAssetDuplicates().reduce(0) { $0 + $1.assets.count } }
        async let versionResult = Result { try await client.getServerVersion() }

        switch await albumsResult {
        case .success(let loaded):
            AppLog.i("Home", "Raw album list retrieved: \(loaded.count)")
            albums = loaded
            errorMessage = nil
        case .failure(let error):
            AppLog.e("Home", "Error during initial loading", error)
            errorMessage = await Self.message(for: error, client: client)
        }
        counts = HomeSections.CollectionCounts(
            all: Self.value(of: await allResult, failure: "Could not load the total asset count"),
            orphans: Self.value(of: await orphansResult, failure: "Could not load the orphans count"),
            duplicates: Self.value(of: await duplicatesResult, failure: "Could not load the duplicates count")
        )
        serverVersion = try? await versionResult.get()
        await refreshProgress()

        // An album's count includes its archived photos, which its deck leaves out without the setting.
        if !includeArchived, !albums.isEmpty {
            albums = await Self.withoutArchived(albums, client: client)
        }
    }

    /// A 403 means the API key lacks a permission: name the missing ones instead of showing "HTTP 403".
    private static func message(for error: Error, client: ImmichClient) async -> String {
        guard case ImmichError.http(status: 403, _) = error else { return error.localizedDescription }
        let missing = await client.missingPermissions()
        guard !missing.isEmpty else { return error.localizedDescription }
        return String(localized: "Your API key is missing these permissions: \(missing.formatted()). Add them to the key in Immich, then tap Try Again.")
    }

    /// The count, or nil with a warning logged, as Android's `AssetRepository` does.
    private static func value(of result: Result<Int, Error>, failure: String) -> Int? {
        switch result {
        case .success(let count): return count
        case .failure(let error):
            AppLog.w("AssetRepo", "\(failure): \(error.localizedDescription)")
            return nil
        }
    }

    /// Timeline photos matching `search`, plus archived ones when they're included (Android:
    /// `getTotalAssetCount`, `getOrphansCount`).
    private nonisolated static func count(_ search: StatisticsSearch, includeArchived: Bool, client: ImmichClient) async throws -> Int {
        let timeline: StatisticsSearch = {
            var timeline = search
            timeline.visibility = .timeline
            return timeline
        }()
        guard includeArchived else { return try await client.searchAssetStatistics(timeline) }
        let archive: StatisticsSearch = {
            var archive = search
            archive.visibility = .archive
            return archive
        }()
        async let timelineCount = client.searchAssetStatistics(timeline)
        async let archiveCount = client.searchAssetStatistics(archive)
        return try await timelineCount + archiveCount
    }

    /// Android's `refineAlbumCounts`: each album's count less its archived photos, 15 requests at a time.
    /// An album whose archive count can't be fetched keeps its count.
    private nonisolated static func withoutArchived(_ albums: [Album], client: ImmichClient) async -> [Album] {
        await withTaskGroup(of: (Int, Int).self) { group in
            var refined = albums
            var next = 0
            func addNext() {
                guard next < albums.count else { return }
                let index = next
                let id = albums[index].id
                next += 1
                group.addTask {
                    let archived = (try? await client.searchAssetStatistics(StatisticsSearch(albumIds: [id], visibility: .archive))) ?? 0
                    return (index, archived)
                }
            }
            for _ in 0..<15 { addNext() }
            for await (index, archived) in group {
                refined[index].assetCount = max(refined[index].assetCount - archived, 0)
                addNext()
            }
            return refined
        }
    }

    /// Re-reads local decision counts whenever the home screen reappears. The read runs off the main actor:
    /// with tens of thousands of decisions it takes about half a second.
    func refreshProgress() async {
        nothingToSort = NothingToSort.ids(userID: userID, defaults: defaults)
        guard let byAlbum = try? await decisions.progressByAlbumInBackground(userID: userID) else { return }
        progress = byAlbum
        // Every decision belongs to exactly one album, so the albums add up to the totals.
        totalProgress = byAlbum.values.reduce(into: AlbumProgress()) { total, album in
            total.decided += album.decided
            total.unsynced += album.unsynced
        }
    }

    nonisolated static func message(for result: AndroidBackup.Result, userID: String) -> String {
        let mine = result.decisionsByUser[userID] ?? 0
        let others = result.totalDecisions - mine
        var lines = [String(localized: "Imported \(mine) decisions for this account.")]
        if others > 0 {
            lines.append(String(localized: "\(others) more belong to other accounts and will appear when you sign in to them."))
        }
        if mine == 0, others > 0 {
            lines.append(String(localized: "None were for this account. Check you're signed in to the same server and user as on Android."))
        }
        if result.historyImported > 0 {
            lines.append(String(localized: "Added \(result.historyImported) past apply sessions to your history."))
        }
        if result.unreadableDecisions > 0 {
            lines.append(String(localized: "Skipped \(result.unreadableDecisions) rows that couldn't be read."))
        }
        return lines.joined(separator: "\n")
    }

    func sections(query: String) -> HomeSections {
        HomeSections.make(albums: albums, counts: counts, progress: progress, totalProgress: totalProgress, nothingToSort: nothingToSort, names: Self.name(for:), query: query)
    }

    nonisolated static func name(for kind: HomeEntry.Kind) -> String {
        switch kind {
        case .all: String(localized: "All Photos")
        case .orphans: String(localized: "Not in Any Album")
        case .duplicates: String(localized: "Duplicates")
        case .album: ""
        }
    }
}

private extension Result where Failure == Error {
    /// `Result(catching:)` for async work, so parallel `async let` calls can fail independently.
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
