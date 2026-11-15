import Foundation
import Observation

/// Drives the duplicates screen, as on Android (`DuplicatesViewModel.kt`): the server's duplicate groups,
/// a Keep or Delete choice per asset, and deleting the marked ones.
///
/// Choices are saved on the device under the "Duplicates" pseudo-album, like swipe decisions. Unlike
/// the swipe deck, deleting happens here, from the progress pill, not from "Apply changes".
@Observable
final class DuplicatesModel {
    struct Cluster: Identifiable, Hashable {
        let id: String
        var assets: [Asset]
    }

    enum SortOrder: CaseIterable {
        case clusterSize, photosFirst, videosFirst
    }

    /// What the Select menu last applied. Best Shot modes are not ported yet.
    enum AutoSelectMode {
        case keepLargest, keepSmallest
    }

    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var isSyncing = false
    var syncError: String?
    private(set) var clusters: [Cluster] = []
    /// Keep or Delete per asset ID. Covers every asset the user has decided, as on Android; counts only
    /// look at the ones in a group.
    private(set) var decisions: [String: SwipeDecision] = [:]
    /// Favorite changes made on this screen, ahead of the server copy of the asset.
    private(set) var favorites: [String: Bool] = [:]
    private(set) var sortOrder = SortOrder.clusterSize
    private(set) var autoSelectMode: AutoSelectMode?
    /// Groups that still had undecided photos when "Only undecided groups" was turned on; nil while it's off.
    /// A snapshot, as on Android, so a group stays listed once it's sorted.
    private(set) var undecidedOnlyIDs: Set<String>?

    let client: ImmichClient
    private let userID: String
    private let store: DecisionStore

    init(client: ImmichClient, userID: String, decisions: DecisionStore) {
        self.client = client
        self.userID = userID
        self.store = decisions
    }

    // MARK: Counts

    var allAssets: [Asset] { clusters.flatMap(\.assets) }
    var totalCount: Int { clusters.reduce(0) { $0 + $1.assets.count } }
    var keepCount: Int { allAssets.count { decisions[$0.id] == .keep } }
    var deleteCount: Int { assetsToDelete.count }
    var deleteBytes: Int64 { assetsToDelete.reduce(0) { $0 + ($1.fileSize ?? 0) } }
    var remainingCount: Int { max(totalCount - keepCount - deleteCount, 0) }
    var progress: Double { totalCount > 0 ? Double(keepCount + deleteCount) / Double(totalCount) : 0 }

    private var assetsToDelete: [Asset] { allAssets.filter { decisions[$0.id] == .delete } }

    func decision(for asset: Asset) -> SwipeDecision? { decisions[asset.id] }

    func isFavorite(_ asset: Asset) -> Bool { favorites[asset.id] ?? asset.isFavorite }

    /// What the list and the viewer show: every group, or only the filtered ones. Counts cover every group.
    var visibleClusters: [Cluster] {
        guard let undecidedOnlyIDs else { return clusters }
        return clusters.filter { undecidedOnlyIDs.contains($0.id) }
    }

    func hasDecisions(_ cluster: Cluster) -> Bool { cluster.assets.contains { decisions[$0.id] != nil } }
    func hasUndecided(_ cluster: Cluster) -> Bool { cluster.assets.contains { decisions[$0.id] == nil } }

    /// Groups with at least one choice, which auto-select asks about before replacing.
    var decidedClusterCount: Int { clusters.count(where: hasDecisions) }

    /// The first shown group with an asset still to decide, where the list jumps after the sort order changes.
    var firstUndecidedClusterIndex: Int {
        visibleClusters.firstIndex(where: hasUndecided) ?? 0
    }

    // MARK: Loading

    /// Loads the groups from the server. Never cached, as on Android.
    func load() async {
        isLoading = true
        loadError = nil
        reloadDecisions()
        do {
            let groups = try await client.getAssetDuplicates()
            // Android gives every group a fresh random ID; the server's ID is used when there is one.
            let mapped = groups.map { Cluster(id: $0.duplicateId ?? UUID().uuidString, assets: $0.assets) }
            clusters = Self.sorted(mapped, by: sortOrder)
            autoSelectMode = nil
            // Android's group IDs are new on every load, so it turns the filter off; done the same here.
            undecidedOnlyIDs = nil
        } catch is CancellationError {
            return
        } catch {
            AppLog.e("Duplicates", "Failed to load duplicates", error)
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Archive and Lock decisions made elsewhere show as undecided here, as on Android.
    private func reloadDecisions() {
        let stored = (try? store.allDecisions(userID: userID)) ?? [:]
        decisions = stored.compactMapValues { [.keep, .delete].contains($0.decision) ? $0.decision : nil }
    }

    // MARK: Choosing

    /// Tapping a photo cycles undecided → Keep → Delete → undecided.
    func toggle(_ asset: Asset) {
        let next: SwipeDecision? = switch decisions[asset.id] {
        case nil: .keep
        case .keep: .delete
        default: nil
        }
        set([asset], to: next)
    }

    /// The viewer's Keep and Delete buttons, as on Android: pressing the choice the photo already has clears it.
    func choose(_ decision: SwipeDecision, for asset: Asset) {
        set([asset], to: decisions[asset.id] == decision ? nil : decision)
    }

    /// "Keep all" or "Delete all". Pressing it again when the whole group already has that choice clears it.
    func setCluster(_ cluster: Cluster, to decision: SwipeDecision) {
        guard !cluster.assets.isEmpty else { return }
        let allMatch = cluster.assets.allSatisfy { decisions[$0.id] == decision }
        set(cluster.assets, to: allMatch ? nil : decision)
    }

    /// Clears the choices for every asset in a group (the toolbar's reset).
    func reset() {
        let decided = allAssets.filter { decisions[$0.id] != nil }
        autoSelectMode = nil
        set(decided, to: nil)
    }

    /// "Only undecided groups": shows the groups that have undecided photos right now, or every group again.
    func toggleUndecidedOnly() {
        undecidedOnlyIDs = undecidedOnlyIDs == nil ? Set(clusters.filter(hasUndecided).map(\.id)) : nil
    }

    /// Keeps one photo per group, the largest or the smallest, and marks the other photos for deletion.
    /// Videos are left alone and favorites are always kept. With `onlyUndecidedGroups`, groups that
    /// already have a choice are left as they are.
    func autoSelect(keepLargest: Bool, onlyUndecidedGroups: Bool = false) {
        var changes: [String: SwipeDecision] = [:]
        for cluster in clusters where !(onlyUndecidedGroups && hasDecisions(cluster)) {
            let photos = cluster.assets.filter { $0.type != .video }
            guard let keeper = (keepLargest ? Self.largestFirst(photos) : Self.smallestFirst(photos)).first else { continue }
            for asset in photos {
                changes[asset.id] = isFavorite(asset) || asset.id == keeper.id ? .keep : .delete
            }
        }
        autoSelectMode = keepLargest ? .keepLargest : .keepSmallest
        let assets = allAssets.filter { changes[$0.id] != nil }
        for decision in [SwipeDecision.keep, .delete] {
            set(assets.filter { changes[$0.id] == decision }, to: decision)
        }
    }

    func setSortOrder(_ order: SortOrder) {
        sortOrder = order
        clusters = Self.sorted(clusters, by: order)
    }

    /// Saves the choice locally, or forgets it when nil.
    private func set(_ assets: [Asset], to decision: SwipeDecision?) {
        guard !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        for id in ids { decisions[id] = decision }
        // A failed local save leaves the choice on screen for this visit, as Android does.
        if let decision {
            let sizes = Dictionary(assets.map { ($0.id, $0.fileSize) }, uniquingKeysWith: { first, _ in first })
            try? store.save(sizes, decision: decision, albumID: Album.virtualDuplicatesID, userID: userID)
        } else {
            try? store.remove(assetIDs: ids, userID: userID)
        }
    }

    // MARK: Server

    /// Favoriting from the viewer also keeps the asset. The heart flips back if the server refuses.
    func toggleFavorite(_ asset: Asset) async {
        let wasFavorite = isFavorite(asset)
        favorites[asset.id] = !wasFavorite
        if !wasFavorite { set([asset], to: .keep) }
        do {
            try await client.updateAssets(ids: [asset.id], isFavorite: !wasFavorite)
        } catch {
            AppLog.e("Duplicates", "Failed to update favorite status", error)
            favorites[asset.id] = wasFavorite
        }
    }

    /// Moves the assets marked Delete to the Immich trash, marks the kept ones as done and reloads the groups.
    ///
    /// Android sends every Delete decision the user has, including ones made in other albums. Only assets
    /// in a duplicate group are sent here, which is what the confirmation counted.
    func deleteMarked() async {
        let toDelete = assetsToDelete
        let toKeep = allAssets.filter { decisions[$0.id] == .keep }.map(\.id)
        isSyncing = true
        defer { isSyncing = false }
        AppLog.i("Duplicates", "Syncing duplicate resolutions: \(toDelete.count) to delete, \(toKeep.count) to keep")
        do {
            if !toDelete.isEmpty {
                let ids = toDelete.map(\.id)
                try await client.deleteAssets(ids: ids, force: false)
                try? store.remove(assetIDs: ids, userID: userID)
                // Decisions stay after an apply, so only kept photos still waiting are counted, as on Android.
                let stored = (try? store.allDecisions(userID: userID)) ?? [:]
                let newlyKept = toKeep.count { stored[$0]?.isSynced == false }
                if !toKeep.isEmpty { try? store.markSynced(assetIDs: toKeep, userID: userID) }
                try? store.recordSync(
                    userID: userID,
                    deletedCount: toDelete.count,
                    bytesSaved: toDelete.reduce(0) { $0 + ($1.fileSize ?? 0) },
                    keptCount: newlyKept,
                    archivedCount: 0,
                    lockedCount: 0
                )
            } else if !toKeep.isEmpty {
                try? store.markSynced(assetIDs: toKeep, userID: userID)
            }
            AppLog.i("Duplicates", "Successfully synced duplicate deletions")
            await load()
        } catch {
            AppLog.e("Duplicates", "Failed to sync deletions", error)
            syncError = error.localizedDescription
        }
    }

    // MARK: Ordering

    /// Android's orders (`sortClusters`). Groups: by size, with photo or video groups first when asked,
    /// then by total bytes. Inside a group: largest file first, then most pixels, with photos or videos
    /// first when asked.
    static func sorted(_ clusters: [Cluster], by order: SortOrder) -> [Cluster] {
        func isVideo(_ asset: Asset) -> Bool { asset.type == .video }
        func bytes(_ cluster: Cluster) -> Int64 { cluster.assets.reduce(0) { $0 + ($1.fileSize ?? 0) } }

        let clusterKey: (Cluster) -> [Int64] = { cluster in
            let videos = Int64(cluster.assets.count(where: isVideo))
            let photos = Int64(cluster.assets.count) - videos
            let size = Int64(cluster.assets.count)
            switch order {
            case .clusterSize: return [size, bytes(cluster)]
            case .photosFirst: return [photos > 0 ? 1 : 0, photos, size, bytes(cluster)]
            case .videosFirst: return [videos > 0 ? 1 : 0, videos, size, bytes(cluster)]
            }
        }
        let assetKey: (Asset) -> [Int64] = { asset in
            let sizeKeys = [asset.fileSize ?? 0, Int64(pixels(asset))]
            switch order {
            case .clusterSize: return sizeKeys
            case .photosFirst: return [isVideo(asset) ? 0 : 1] + sizeKeys
            case .videosFirst: return [isVideo(asset) ? 1 : 0] + sizeKeys
            }
        }

        // Every key is compared largest first; ties keep their order.
        return clusters
            .map { Cluster(id: $0.id, assets: $0.assets.sorted { assetKey($0).lexicographicallyPrecedes(assetKey($1), by: >) }) }
            .sorted { clusterKey($0).lexicographicallyPrecedes(clusterKey($1), by: >) }
    }

    /// Largest file first, then most pixels.
    static func largestFirst(_ assets: [Asset]) -> [Asset] {
        assets.sorted { ($0.fileSize ?? 0, pixels($0)) > ($1.fileSize ?? 0, pixels($1)) }
    }

    /// Smallest known file first, then the oldest. Unknown sizes go last.
    static func smallestFirst(_ assets: [Asset]) -> [Asset] {
        func size(_ asset: Asset) -> Int64 {
            let size = asset.fileSize ?? 0
            return size == 0 ? .max : size
        }
        return assets.sorted { (size($0), $0.fileCreatedAt) < (size($1), $1.fileCreatedAt) }
    }

    private static func pixels(_ asset: Asset) -> Int {
        (asset.exifInfo?.exifImageWidth ?? 0) * (asset.exifInfo?.exifImageHeight ?? 0)
    }
}
