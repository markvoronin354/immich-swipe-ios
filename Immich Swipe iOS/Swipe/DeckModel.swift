import Foundation
import Observation

/// Drives one swipe deck: loads the photos page by page, keeps them sorted, and saves each decision.
///
/// Decisions are stored locally only. Nothing reaches the server until "Apply changes".
@Observable
final class DeckModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var deck = Deck()
    private(set) var phase = Phase.loading
    /// True while later pages are still arriving. The deck is usable before this finishes.
    private(set) var isLoadingMore = false
    /// Total from the server's statistics, which is accurate even before every page has loaded. Photos
    /// owned by other users are left out of it, as they are left out of the deck.
    private(set) var serverTotal: Int?
    /// Assets fetched so far in this sync, held back or not, for the loader's "x / y".
    private(set) var syncedCount = 0
    /// Set when saving to the local database fails, so the user knows a decision may not stick.
    private(set) var saveError: String?

    private(set) var sortOrder: DeckSortOrder

    let title: String
    let source: DeckSource
    let client: ImmichClient
    private let userID: String
    private let decisions: DecisionStore
    private let shuffleSeed: Int64
    private let photoSaver: PhotoSaving
    private let listingCache: AssetListCache
    private let defaults: UserDefaults

    /// Everything stored for this user, read once when the deck opens.
    private var stored: [String: StoredDecision] = [:]
    /// Every asset loaded so far, in arrival order. The deck holds the sorted copy.
    private var loaded: [Asset] = [] { didSet { pileVersion += 1 } }
    /// Position of each asset in `loaded`.
    private var loadedIndex: [String: Int] = [:]
    /// Bumped whenever the pile changes, so a sort that started before the change is redone.
    private var pileVersion = 0
    /// Photos in this album that belong to other users (shared albums, partner libraries). Immich won't let
    /// this user change them, so they are left out of the deck instead of failing when changes are applied.
    private var foreignIDs: Set<String> = []
    /// The server's own total, which counts those photos too.
    private var reportedTotal = 0
    /// Deleted or locked by "Apply changes". Pages already in flight predate that, so they're filtered out.
    private var removedIDs: Set<String> = []
    /// As on Android: while only the saved listing is showing, or after the sort order changes, the deck
    /// lands on the first undecided card. The first page from the server, or a swipe, ends that. After
    /// that the current card stays put, so a page loading in the background never swaps the photo out.
    private var pendingJump = true

    static let sortOrderKey = "sort_order"
    /// Albums last added to, most recent first, comma-separated as on Android.
    static let recentAlbumIDsKey = "recent_album_ids"
    private static let maxRecentAlbums = 50
    /// Android stops paging past this many assets.
    private static let maxListingSize = 500_000

    init(title: String, source: DeckSource, client: ImmichClient, userID: String, decisions: DecisionStore, shuffleSeed: Int64, defaults: UserDefaults = .standard, photoSaver: PhotoSaving? = nil, listingCache: AssetListCache = .shared) {
        self.title = title
        self.source = source
        self.client = client
        self.userID = userID
        self.decisions = decisions
        self.shuffleSeed = shuffleSeed
        self.photoSaver = photoSaver ?? PhotoLibrarySaver()
        self.listingCache = listingCache
        self.defaults = defaults
        sortOrder = defaults.string(forKey: Self.sortOrderKey).flatMap(DeckSortOrder.init(rawValue:)) ?? .default
        includeArchived = defaults.object(forKey: Setting.Key.includeArchived) as? Bool ?? Setting.Default.includeArchived
    }

    /// "Include external archives", read when the deck opens.
    private let includeArchived: Bool

    /// The saved listing for this deck. Timeline-only listings are kept apart, so turning the setting
    /// on or off never starts from a listing with the wrong photos in it.
    private var listingID: String { includeArchived ? source.albumID : "\(source.albumID)-timeline" }

    // MARK: Counts

    /// The best known size of the deck: the server's total, or what has loaded if that's larger.
    var total: Int { max(serverTotal ?? 0, deck.assets.count) }
    var decidedCount: Int { deck.decidedCount }
    var progress: Double { total > 0 ? Double(min(decidedCount, total)) / Double(total) : 0 }

    // MARK: Loading

    /// Loads the deck. Call from `.task`, so leaving the screen cancels paging.
    func load() async {
        phase = .loading
        pendingJump = true
        syncedCount = 0
        foreignIDs = []
        // The saved listing and the stored decisions both take a while with a large library, so they're
        // read side by side, off the main actor. Duplicates have no saved listing; that read finds no file.
        let (cache, user, listing) = (listingCache, userID, listingID)
        async let savedListing = cache.assets(userID: user, albumID: listing)
        stored = (try? await decisions.allDecisionsInBackground(userID: userID)) ?? [:]
        syncedIDs = Set(stored.filter { $0.value.isSynced }.keys)

        do {
            if let first = source.firstSearch(order: sortOrder, includeArchived: includeArchived) {
                try await loadListing(startingWith: first, cached: await savedListing)
                dropPendingDecisionsOnForeignPhotos()
                recordNothingToSort()
            } else {
                let groups = try await client.getAssetDuplicates()
                let assets = DeckSource.flatten(groups)
                serverTotal = assets.count
                await receive(assets, fromServer: true)
            }
            phase = .ready
        } catch is CancellationError {
            // Left the screen; nothing to report.
        } catch {
            AppLog.e("Swipe", "Error loading album", error)
            if deck.assets.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                // A later page failed. Keep what loaded so the user can carry on.
                phase = .ready
            }
        }
        isLoadingMore = false
        lastSort = nil
    }

    /// Port of Android's `AssetRepository.getAssetsByAlbum` (spec §3.5).
    /// `cached` is the listing saved last time, already read by `load()`.
    private func loadListing(startingWith first: MetadataSearch, cached: [Asset]) async throws {
        // 1. Show the listing saved last time right away, sorted. The server may still change it.
        if !cached.isEmpty {
            isLoadingMore = true
            await receive(cached, fromServer: false)
        }

        // 2. The statistics total is more reliable than the search total, so the larger one wins.
        async let statistics = try? client.searchAssetStatistics(first.statistics)
        let firstPage = try await client.searchAssets(first)
        try Task.checkCancellation()
        reportedTotal = max(await statistics ?? 0, firstPage.total)
        let firstItems = owned(firstPage.items)
        let total = max(reportedTotal - foreignIDs.count, 0)
        serverTotal = total

        // 3. With several pages, a saved listing that matches the server's total and first page is
        //    up to date, so the other pages aren't fetched again.
        if first.next(after: firstPage) != nil, Self.isComplete(cached, total: total, firstPage: firstItems, order: first.order) {
            await receive(firstItems, fromServer: true)
            return
        }

        // 4. Otherwise page through everything. Saved assets the server no longer returned are dropped
        //    only after a complete pass: a partial one just hasn't reached them yet.
        do {
            if let fetched = try await syncPages(startingWith: first, firstPage: firstPage) {
                if fetched.count < total {
                    AppLog.w("AssetRepo", "Sync finished but only fetched \(fetched.count) / \(total). Server might be hiding some items.")
                }
                let stale = Set(loaded.map(\.id)).subtracting(fetched)
                if !stale.isEmpty {
                    removeFromPile(stale)
                    await resort()
                }
            }
        } catch {
            await listingCache.save(loaded, userID: userID, albumID: listingID)
            throw error
        }
        await listingCache.save(loaded, userID: userID, albumID: listingID)
    }

    /// Pages through the search, sorting each page into the deck as it lands. As on Android, that only
    /// happens for a date order: pages arrive by date, so for any other order each one would reshuffle
    /// the deck. Those pages are held back and added together at the end, or when a page fails.
    /// Returns the IDs the server sent after a complete pass, or nil if it stopped early.
    private func syncPages(startingWith first: MetadataSearch, firstPage: SearchPage) async throws -> Set<String>? {
        var request = first
        var page = firstPage
        var fetched: Set<String> = []
        var held: [Asset] = []
        var heldIDs: Set<String> = []
        // Held assets the pile doesn't have yet; the rest replace a saved copy.
        var heldNewCount = 0

        /// Adds this page, and any held back before it, to the deck.
        func receiveHeld(and items: [Asset]) async {
            await receive(held + items, fromServer: true)
            held = []
            heldIDs = []
            heldNewCount = 0
            syncedCount = loaded.count
        }

        do {
            while true {
                let items = owned(page.items)
                fetched.formUnion(items.map(\.id))
                var next = request.next(after: page)
                if next != nil, request.order != sortOrder.searchDirection, let restart = source.firstSearch(order: sortOrder, includeArchived: includeArchived) {
                    // The sort direction changed mid-load. Like Android, start over so the photos that now
                    // come first arrive first. Loaded photos are kept, and the new pass must be complete on its own.
                    next = restart
                    fetched = []
                }
                isLoadingMore = next != nil
                guard let next else {
                    await receiveHeld(and: items)
                    return fetched
                }
                // The next page downloads while this one is sorted in.
                async let following = client.searchAssets(next)
                if Self.showsPagesAsTheyLand(sortOrder) {
                    await receiveHeld(and: items)
                } else {
                    for asset in items where heldIDs.insert(asset.id).inserted {
                        held.append(asset)
                        if loadedIndex[asset.id] == nil { heldNewCount += 1 }
                    }
                }
                syncedCount = loaded.count + heldNewCount
                guard syncedCount <= Self.maxListingSize else {
                    await receiveHeld(and: [])
                    return nil
                }
                request = next
                page = try await following
                try Task.checkCancellation()
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            // Android stops at a failed page and still shows everything fetched before it.
            AppLog.e("AssetRepo", "Error page sync: \(error.localizedDescription)")
            await receiveHeld(and: [])
            throw error
        }
    }

    /// The photos this user owns. The others are remembered, and take themselves off the deck's total.
    private func owned(_ assets: [Asset]) -> [Asset] {
        let user = userID
        let mine = assets.filter { $0.ownerId == user }
        if mine.count != assets.count {
            foreignIDs.formUnion(assets.filter { $0.ownerId != user }.map(\.id))
            serverTotal = max(reportedTotal - foreignIDs.count, 0)
        }
        return mine
    }

    /// Home lists an album with none of this user's photos as having nothing to sort. Only a finished load
    /// from the server can say so, so a failed or cancelled one leaves the last answer alone.
    private func recordNothingToSort() {
        guard case .album(let id) = source else { return }
        if deck.assets.isEmpty, !foreignIDs.isEmpty {
            NothingToSort.set(true, albumID: id, userID: userID, defaults: defaults)
        } else if !deck.assets.isEmpty {
            NothingToSort.set(false, albumID: id, userID: userID, defaults: defaults)
        }
    }

    /// A decision made on another user's photo before it was skipped could never be applied, so it would
    /// stay pending for good.
    private func dropPendingDecisionsOnForeignPhotos() {
        guard !foreignIDs.isEmpty else { return }
        AppLog.i("AssetRepo", "Skipped \(foreignIDs.count) assets owned by other users in \(source.albumID)")
        let stuck = foreignIDs.filter { stored[$0]?.isSynced == false }
        guard !stuck.isEmpty else { return }
        do {
            try decisions.remove(assetIDs: stuck, userID: userID)
        } catch {
            AppLog.w("SwipeViewModel", "Could not drop pending decisions on skipped photos: \(error.localizedDescription)")
        }
    }

    /// Only the date orders match the order pages come from the server in.
    private nonisolated static func showsPagesAsTheyLand(_ order: DeckSortOrder) -> Bool {
        order == .chronologicalDescending || order == .chronologicalAscending
    }

    /// Spec §3.5 step 5: the saved listing has the server's total, and the first page has nothing
    /// new or missing. The page is compared with the saved assets that come before its last one in
    /// the server's own order (creation date), so the check holds whatever order the deck is sorted in.
    private nonisolated static func isComplete(_ cached: [Asset], total: Int, firstPage: [Asset], order: MetadataSearch.SortDirection?) -> Bool {
        guard total > 0, cached.count == total, let last = firstPage.last?.fileCreatedAt else { return false }
        let pageIDs = Set(firstPage.map(\.id))
        guard pageIDs.isSubset(of: cached.map(\.id)) else { return false }
        return cached.allSatisfy { asset in
            let isAhead = order == .asc ? asset.fileCreatedAt < last : asset.fileCreatedAt > last
            return !isAhead || pageIDs.contains(asset.id)
        }
    }

    /// Adds assets to the pile, re-sorts all of it, and picks up stored decisions for the new ones.
    /// An asset already in the pile is replaced, so one from the saved listing gets the server's latest.
    private func receive(_ items: [Asset], fromServer: Bool) async {
        var change = PileChange(since: pileVersion)
        // Where each asset new to the pile sits in `change.added`, for an asset sent twice in one batch.
        var addedPositions: [String: Int] = [:]
        for asset in items where !removedIDs.contains(asset.id) {
            if let index = loadedIndex[asset.id] {
                if let position = addedPositions[asset.id] {
                    change.added[position] = asset
                } else {
                    // A photo that moves in the order can't be merged; the whole pile is sorted again instead.
                    if loaded[index].effectiveDate != asset.effectiveDate { change.keepsOrder = false }
                    change.replaced[asset.id] = asset
                }
                loaded[index] = asset
            } else {
                loadedIndex[asset.id] = loaded.count
                loaded.append(asset)
                addedPositions[asset.id] = change.added.count
                change.added.append(asset)
            }
        }
        await resort(change)
        if fromServer { pendingJump = false }
        mergeStoredDecisions(for: change.added.map(\.id))
    }

    /// What one `receive` did to the pile, so its assets can be merged into the last sort.
    private nonisolated struct PileChange: Sendable {
        /// `pileVersion` before the change.
        let since: Int
        /// New to the pile, in the order they arrived.
        var added: [Asset] = []
        /// Already in the pile, replaced by the server's copy.
        var replaced: [String: Asset] = [:]
        /// False once a replaced asset's date changed, which can move it in the order.
        var keepsOrder = true
    }

    /// The pile as last sorted while loading, with the `pileVersion` and order it was sorted at. Kept only
    /// during a load, so the deck doesn't hold a second copy of a large pile once it's done.
    private var lastSort: (version: Int, order: DeckSortOrder, assets: [Asset])?

    /// Sorts the whole pile and shows it. A sort that the pile or the order changed under is redone,
    /// as Android cancels an outdated sort, so a stale result never overwrites a newer one.
    ///
    /// With `change`, when the last sort is of the pile just before it and nothing in it moves, the change
    /// is merged into that sort instead. The order is the same; the time is a fraction, which matters when
    /// a large library's pages are each sorted in as they land.
    private func resort(_ change: PileChange? = nil) async {
        var change = change
        while true {
            let version = pileVersion
            let order = sortOrder
            let ordered: [Asset]
            if !source.supportsSorting {
                ordered = loaded
            } else if let change, change.keepsOrder, let last = lastSort, last.version == change.since, last.order == order,
                      let merged = await Self.merged(change, into: last.assets, by: order, seed: shuffleSeed) {
                ordered = merged
            } else {
                ordered = await Self.sorted(loaded, by: order, seed: shuffleSeed)
            }
            guard version == pileVersion, order == sortOrder else {
                // The pile changed again while this ran, so the change no longer describes it.
                change = nil
                continue
            }
            lastSort = phase == .loading && source.supportsSorting ? (version, order, ordered) : nil
            deck.replaceAssets(ordered, keepPosition: !pendingJump)
            return
        }
    }

    private func removeFromPile(_ ids: Set<String>) {
        loaded.removeAll { ids.contains($0.id) }
        loadedIndex = Dictionary(uniqueKeysWithValues: loaded.enumerated().map { ($1.id, $0) })
    }

    /// Fetches the current card's full details, as Android does, so a photo from the saved listing
    /// shows the server's latest state. Failures are ignored; the card just keeps what it has.
    func loadCurrentDetails() async {
        guard let id = deck.current?.id,
              let detail = try? await client.getAssetInfo(id: id),
              detail.id == id,
              let index = loadedIndex[id],
              loaded[index] != detail else { return }
        loaded[index] = detail
        deck.updateAssets { if $0.id == id { $0 = detail } }
    }

    /// Saves the description on the server, then shows it on the card, as on Android (`saveDescription`).
    func saveDescription(_ description: String, for assetID: String) async throws {
        do {
            try await client.updateAsset(id: assetID, description: description)
        } catch {
            AppLog.e("AssetRepo", "Failed to update description of asset \(assetID): \(error.localizedDescription)", error)
            throw error
        }
        let apply: (inout Asset) -> Void = { asset in
            guard asset.id == assetID else { return }
            var exif = asset.exifInfo ?? ExifInfo()
            exif.description = description
            asset.exifInfo = exif
        }
        if let index = loadedIndex[assetID] { apply(&loaded[index]) }
        deck.updateAssets(apply)
    }

    /// Stored decisions that apply here: made for an asset in this deck, wherever they were made.
    private func mergeStoredDecisions(for assetIDs: [String]) {
        var relevant: [String: SwipeDecision] = [:]
        var unsynced: [(id: String, at: Date)] = []
        for id in assetIDs {
            guard let decision = stored[id] else { continue }
            relevant[id] = decision.decision
            if !decision.isSynced { unsynced.append((id, decision.createdAt)) }
        }
        guard !relevant.isEmpty else { return }
        // Unsynced decisions from earlier sessions can still be undone, oldest first.
        deck.mergeStoredDecisions(relevant, unsyncedHistory: unsynced.sorted { $0.at < $1.at }.map(\.id))
    }

    /// Sorting runs off the main actor so the UI stays responsive with large libraries.
    @concurrent
    private nonisolated static func sorted(_ assets: [Asset], by order: DeckSortOrder, seed: Int64) async -> [Asset] {
        order.sorted(assets, seed: seed)
    }

    /// The last sort with the server's copies of replaced assets swapped in and the new ones merged, off the
    /// main actor. Nil for an order that can't merge.
    @concurrent
    private nonisolated static func merged(_ change: PileChange, into sorted: [Asset], by order: DeckSortOrder, seed: Int64) async -> [Asset]? {
        let refreshed = change.replaced.isEmpty ? sorted : sorted.map { change.replaced[$0.id] ?? $0 }
        return order.merging(change.added, into: refreshed, seed: seed)
    }

    // MARK: Sorting

    func setSortOrder(_ order: DeckSortOrder, defaults: UserDefaults = .standard) async {
        if order == sortOrder || !source.supportsSorting {
            // Re-picking the current order jumps back to the first undecided card.
            deck.replaceAssets(deck.assets, keepPosition: false)
            return
        }
        sortOrder = order
        defaults.set(order.rawValue, forKey: Self.sortOrderKey)
        // The deck jumps to the first undecided card now, and again when the next page lands.
        pendingJump = true
        await resort()
    }

    // MARK: Deciding

    func decide(_ decision: SwipeDecision) {
        guard let asset = deck.decideCurrent(decision) else { return }
        AppLog.d("SwipeViewModel", "Swiped asset \(asset.id): \(decision)")
        swipeFavorites[asset.id] = nil
        pendingJump = false
        lastOutcome = nil
        syncedIDs.remove(asset.id) // a new decision is waiting to be applied, even if the old one was
        persist {
            try decisions.save(decision, assetID: asset.id, albumID: source.albumID, userID: userID, fileSize: asset.fileSize)
        }
    }

    /// Carries out what a swipe is set to do (Android's `performSwipeAction`).
    func swipe(_ action: SwipeAction) {
        switch action {
        case .keep, .delete, .archive, .lock:
            if let decision = action.decision { decide(decision) }
        case .undo:
            undo()
        case .details:
            // The panel belongs to the card, which opens it itself.
            break
        case .favorite:
            guard let asset = deck.current else { return }
            // Sets rather than toggles, so swiping a photo that is already a favourite doesn't take it away.
            let newlyFavorited = !isFavorite(asset)
            let before = favoriteOverrides[asset.id]
            if newlyFavorited { toggleFavoriteForCurrent() }
            decide(.keep)
            if newlyFavorited { swipeFavorites[asset.id] = .some(before) }
        }
    }

    /// Carries out a swipe on the photo it was started on. A page landing while the card flies off can
    /// make another photo current (say, a newer one sorted in ahead), and the swipe must not land on that
    /// one instead. Does nothing if the photo has left the deck meanwhile.
    func swipe(_ action: SwipeAction, on assetID: String) {
        if deck.current?.id != assetID {
            guard let index = deck.assets.firstIndex(where: { $0.id == assetID }) else { return }
            deck.move(to: index)
        }
        swipe(action)
    }

    func undo() {
        guard let assetID = deck.undo() else { return }
        lastOutcome = nil
        undoSwipeFavorite(assetID)
        persist { try decisions.remove(assetIDs: [assetID], userID: userID) }
    }

    /// Photos a Favorite swipe favourited, with the favourite override they had before (nil: none), so undoing
    /// the swipe can take the heart back, as on Android.
    private var swipeFavorites: [String: Bool?] = [:]

    private func undoSwipeFavorite(_ assetID: String) {
        guard let before = swipeFavorites.removeValue(forKey: assetID) else { return }
        favoriteOverrides[assetID] = before
    }

    /// Forgets every decision for the photos in this deck.
    func resetDecisions() {
        let ids = Set(deck.assets.map(\.id))
        deck.reset()
        swipeFavorites = [:]
        lastOutcome = nil
        persist { try decisions.removeAll(userID: userID, albumID: source.albumID, albumAssetIDs: ids) }
        for id in ids { stored[id] = nil }
        syncedIDs.subtract(ids)
    }

    private func persist(_ write: () throws -> Void) {
        do {
            try write()
            saveError = nil
        } catch {
            AppLog.e("SwipeViewModel", "Error saving decisions", error)
            saveError = error.localizedDescription
        }
    }

    // MARK: Favourites, rotation and navigation

    /// Favourite and rotation changes stay on the device until "Apply changes", like decisions.
    private(set) var favoriteOverrides: [String: Bool] = [:]
    private(set) var rotations: [String: Int] = [:]

    func isFavorite(_ asset: Asset) -> Bool { favoriteOverrides[asset.id] ?? asset.isFavorite }

    func toggleFavoriteForCurrent() {
        guard let asset = deck.current else { return }
        let newValue = !isFavorite(asset)
        lastOutcome = nil
        // Setting it back to what the server has means there's nothing to send.
        favoriteOverrides[asset.id] = newValue == asset.isFavorite ? nil : newValue
    }

    func rotation(of asset: Asset) -> Int { rotations[asset.id] ?? 0 }

    func rotateCurrent() {
        guard let asset = deck.current else { return }
        let next = (rotation(of: asset) + 90) % 360
        lastOutcome = nil
        rotations[asset.id] = next == 0 ? nil : next
    }

    func move(to index: Int) { deck.move(to: index) }

    func move(toAssetID id: String) {
        if let index = deck.assets.firstIndex(where: { $0.id == id }) { deck.move(to: index) }
    }

    /// Removes one decision from the review list without moving the deck.
    func removeDecision(for assetID: String) {
        deck.removeDecision(for: assetID)
        undoSwipeFavorite(assetID)
        lastOutcome = nil
        persist { try decisions.remove(assetIDs: [assetID], userID: userID) }
    }

    /// Decided assets in the pile, grouped by decision, for the review list.
    func decidedAssets() -> [SwipeDecision: [Asset]] {
        Dictionary(grouping: deck.assets.filter { deck.decision(for: $0.id) != nil }) { deck.decision(for: $0.id)! }
    }

    /// Kept in the broad sense, as on Android: kept, archived or locked.
    var keptCount: Int { deck.pileCount(of: [.keep, .archive, .lock]) }
    var deletedCount: Int { deck.pileCount(of: [.delete]) }
    var remainingCount: Int { max(total - decidedCount, 0) }

    /// The asset's page in the Immich web app, which the Immich app also opens if installed.
    func immichURL(for asset: Asset) -> URL {
        client.serverURL.appending(path: "photos").appending(path: asset.id)
    }

    /// Deep link into the Immich iOS app. Only works if that app is installed.
    func immichAppURL(for asset: Asset) -> URL {
        URL(string: "immich://asset?id=\(asset.id)")!
    }

    // MARK: Albums

    /// Real albums for the "Add to album" sheet: the ones last added to first, as on Android, then the rest
    /// alphabetically.
    func loadAlbums() async throws -> [Album] {
        let recentRank = Dictionary(recentAlbumIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return try await client.getAllAlbums()
            // Albums shared with you as a viewer would reject the add.
            .filter { !$0.isVirtual && $0.canAddAssets(userID: userID) }
            .sorted {
                let lhs = recentRank[$0.id] ?? .max, rhs = recentRank[$1.id] ?? .max
                if lhs != rhs { return lhs < rhs }
                return $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending
            }
    }

    private var recentAlbumIDs: [String] {
        (defaults.string(forKey: Self.recentAlbumIDsKey) ?? "").split(separator: ",").map(String.init)
    }

    /// Moves the album to the front of the recent list, keeping the newest 50.
    private func rememberRecentAlbum(_ id: String) {
        let ids = [id] + recentAlbumIDs.filter { $0 != id }
        defaults.set(ids.prefix(Self.maxRecentAlbums).joined(separator: ","), forKey: Self.recentAlbumIDsKey)
    }

    /// Names of the real albums holding the photo, for the metadata panel. Empty if the request fails, as on Android.
    func albumNames(containing asset: Asset) async -> [String] {
        let albums: [Album]
        do {
            albums = try await client.getAllAlbums(containing: asset.id)
        } catch {
            AppLog.e("SwipeViewModel", "Error loading albums for asset", error)
            return []
        }
        return albums.filter { !$0.isVirtual }.map(\.albumName)
    }

    /// Adds the photo to an album on the server right away, as on Android. Unlike decisions this
    /// isn't deferred: it only adds, never removes, so there's nothing to review first.
    func add(_ asset: Asset, to album: Album) async throws {
        do {
            let results = try await client.addAssetsToAlbum(id: album.id, assetIDs: [asset.id])
            if let failure = results.first(where: { !$0.success }), failure.error != "duplicate" {
                throw ImmichError.http(status: 400, message: failure.error)
            }
            rememberRecentAlbum(album.id)
        } catch {
            AppLog.e("SwipeViewModel", "Error adding asset to album \(album.albumName)", error)
            throw error
        }
    }

    func createAlbum(named name: String, with asset: Asset) async throws -> Album {
        do {
            let album = try await client.createAlbum(name: name, assetIDs: [asset.id])
            rememberRecentAlbum(album.id)
            return album
        } catch {
            AppLog.e("SwipeViewModel", "Error creating album \(name)", error)
            throw error
        }
    }

    // MARK: Applying changes

    /// Decisions already sent to the server, from earlier sessions or an earlier apply.
    private var syncedIDs: Set<String> = []
    private(set) var isApplying = false
    private(set) var lastOutcome: ApplyOutcome?

    /// What applying would do right now.
    var plan: ApplyPlan {
        ApplyPlan.make(deck: deck, pending: Set(deck.decisions.keys).subtracting(syncedIDs), favorites: favoriteOverrides, rotations: rotations)
    }

    /// Sends the pending changes to the server, then brings the deck in line with what happened.
    ///
    /// Run from a `Task` that isn't tied to a view, so closing the sheet part-way doesn't leave a
    /// half-finished apply.
    func apply() async {
        guard !isApplying else { return }
        isApplying = true
        lastOutcome = nil
        let outcome = await ApplyChanges(client: client, decisions: decisions, userID: userID).run(plan)
        integrate(outcome)
        lastOutcome = outcome
        isApplying = false
    }

    private func integrate(_ outcome: ApplyOutcome) {
        // Deleted photos are in the Immich trash and locked ones left the library, so neither belongs in the deck.
        let gone = Set(outcome.removedIDs)
        if !gone.isEmpty {
            removeFromPile(gone)
            removedIDs.formUnion(gone)
            Task { [listingCache, userID] in await listingCache.remove(assetIDs: gone, userID: userID) }
            for id in gone {
                stored[id] = nil
                syncedIDs.remove(id)
                favoriteOverrides[id] = nil
                rotations[id] = nil
            }
            if let serverTotal { self.serverTotal = max(serverTotal - gone.count, 0) }
            deck.removeAssets(gone)
        }

        syncedIDs.formUnion(outcome.syncedIDs)

        // Favourites now live on the server, so the photo itself should say so.
        let favorites = outcome.favoritesApplied
        if !favorites.isEmpty {
            for id in favorites.keys { favoriteOverrides[id] = nil }
            let applyFavorites: (inout Asset) -> Void = { asset in
                if let value = favorites[asset.id] { asset.isFavorite = value }
            }
            for index in loaded.indices { applyFavorites(&loaded[index]) }
            deck.updateAssets(applyFavorites)
        }

        // Rotated photos are now edited on the server, and their old images are out of date.
        let rotated = Set(outcome.rotatedIDs)
        if !rotated.isEmpty {
            for id in rotated { rotations[id] = nil }
            let markEdited: (inout Asset) -> Void = { asset in
                if rotated.contains(asset.id) { asset.isEdited = true }
            }
            for index in loaded.indices { markEdited(&loaded[index]) }
            deck.updateAssets(markEdited)
            let stale = rotated.flatMap { [client.authorizedRequest(for: .preview(assetID: $0)), client.authorizedRequest(for: .thumbnail(assetID: $0))] }
            Task { await ThumbnailLoader.shared.invalidate(stale) }
        }

        // Applied decisions can't be undone, and the deck returns to the first photo still to sort.
        deck.clearHistory()
        swipeFavorites = [:]
        deck.replaceAssets(deck.assets, keepPosition: false)
    }

    // MARK: Full resolution

    private(set) var fullResolutionOn = false
    private(set) var fullResolutionAssetID: String?

    /// Whether the card shows the original. It stays on while swiping only if the user asked for that.
    /// Videos never use it, since they play instead.
    func usesFullResolution(_ asset: Asset, keepWhileSwiping: Bool) -> Bool {
        asset.type != .video && fullResolutionOn && (keepWhileSwiping || fullResolutionAssetID == asset.id)
    }

    func toggleFullResolution(keepWhileSwiping: Bool) {
        guard let asset = deck.current else { return }
        if usesFullResolution(asset, keepWhileSwiping: keepWhileSwiping) {
            fullResolutionOn = false
        } else {
            fullResolutionOn = true
            fullResolutionAssetID = asset.id
        }
    }

    // MARK: Download and share

    enum Transfer: Equatable {
        case saved
        case failed(String)
    }

    private(set) var downloadingAssetID: String?
    /// The result of the last download, shown briefly and then cleared.
    private(set) var transfer: Transfer?

    func clearTransfer() { transfer = nil }

    /// Downloads the current photo's original and adds it to the Photos library.
    func downloadCurrent() async {
        guard let asset = deck.current, downloadingAssetID == nil else { return }
        downloadingAssetID = asset.id
        transfer = nil
        defer { downloadingAssetID = nil }

        var file: URL?
        do {
            let downloaded = try await client.downloadOriginal(of: asset)
            file = downloaded
            try await photoSaver.save(fileAt: downloaded, isVideo: asset.type == .video)
            transfer = .saved
        } catch {
            AppLog.e("Download", "Error saving downloaded file", error)
            transfer = .failed(error.localizedDescription)
        }
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }

    func shareable(_ asset: Asset) -> ShareableAsset { ShareableAsset(client: client, asset: asset) }

    // MARK: Media

    func thumbnailRequest(for asset: Asset) -> URLRequest {
        client.authorizedRequest(for: .thumbnail(assetID: asset.id))
    }

    func originalRequest(for asset: Asset) -> URLRequest {
        client.authorizedRequest(for: .original(assetID: asset.id))
    }

    func previewRequest(for asset: Asset) -> URLRequest {
        // GIFs only animate from the original; everything else uses the server's preview size.
        client.authorizedRequest(for: asset.isGIF ? .original(assetID: asset.id) : .preview(assetID: asset.id))
    }
}
