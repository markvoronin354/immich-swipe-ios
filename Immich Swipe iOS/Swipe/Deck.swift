import Foundation

/// The swipe deck's state and rules, independent of the UI and storage (spec §3.3).
///
/// Holds the sorted pile, the decision for each asset, the undo history and the current card.
/// The card shown is always the first undecided one at or after `currentIndex`; when none is left,
/// `currentIndex == assets.count` and the deck is finished.
nonisolated struct Deck: Equatable, Sendable {
    private(set) var assets: [Asset] = []
    private(set) var decisions: [String: SwipeDecision] = [:]
    /// Asset IDs in the order they were decided, for undo. Cleared after "Apply changes".
    private(set) var history: [String] = []
    private(set) var currentIndex = 0
    /// How many assets in the pile have each decision. Kept up to date as decisions and the pile change, so
    /// the counts the deck screen reads after every swipe don't walk a pile of tens of thousands of photos.
    /// `decisions` can also hold assets that have left the pile, which these leave out.
    private var pileCounts: [SwipeDecision: Int] = [:]

    init(assets: [Asset] = [], decisions: [String: SwipeDecision] = [:], history: [String] = []) {
        self.assets = assets
        self.decisions = decisions
        self.history = history.filter { decisions[$0] != nil }
        currentIndex = firstUndecidedIndex(from: 0)
        recountPile()
    }

    // MARK: Reading

    var current: Asset? { assets.indices.contains(currentIndex) ? assets[currentIndex] : nil }
    var isFinished: Bool { !assets.isEmpty && current == nil }
    var canUndo: Bool { !history.isEmpty }

    /// The next few undecided assets after the current one, for preloading and the card behind.
    func upcoming(_ count: Int) -> [Asset] {
        guard currentIndex < assets.count else { return [] }
        return Array(assets[(currentIndex + 1)...].lazy.filter { decisions[$0.id] == nil }.prefix(count))
    }

    func decision(for assetID: String) -> SwipeDecision? { decisions[assetID] }

    func count(of decision: SwipeDecision) -> Int { decisions.values.lazy.filter { $0 == decision }.count }

    /// Total bytes of assets with this decision, where the size is known.
    func bytes(of decision: SwipeDecision) -> Int64 {
        assets.reduce(0) { total, asset in
            decisions[asset.id] == decision ? total + (asset.fileSize ?? 0) : total
        }
    }

    /// Decided assets that are in the pile, so a decision for an asset no longer on the server isn't counted.
    var decidedCount: Int { pileCounts.values.reduce(0, +) }

    /// Assets in the pile with one of these decisions.
    func pileCount(of kinds: Set<SwipeDecision>) -> Int {
        kinds.reduce(0) { $0 + pileCounts[$1, default: 0] }
    }

    /// Shows a specific card, as when tapping the thumbnail strip. It may already be decided;
    /// deciding it again replaces the earlier decision.
    mutating func move(to index: Int) {
        guard assets.indices.contains(index) else { return }
        currentIndex = index
    }

    // MARK: Deciding

    /// Records a decision for the current card and moves to the next undecided one.
    /// Returns the asset decided, or nil if the deck was already finished.
    @discardableResult
    mutating func decideCurrent(_ decision: SwipeDecision) -> Asset? {
        guard let asset = current else { return nil }
        // The current card is always in the pile.
        adjustPileCounts(from: decisions[asset.id], to: decision)
        decisions[asset.id] = decision
        history.removeAll { $0 == asset.id }
        history.append(asset.id)
        currentIndex = nextUndecidedIndex(after: currentIndex)
        return asset
    }

    /// Applies one decision to several assets (bulk mode), then continues after the last of them.
    mutating func decide(_ decision: SwipeDecision, assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }
        let ids = Set(assetIDs)
        for id in assetIDs {
            decisions[id] = decision
            history.removeAll { $0 == id }
            history.append(id)
        }
        let lastIndex = assets.lastIndex { ids.contains($0.id) } ?? currentIndex
        currentIndex = nextUndecidedIndex(after: lastIndex)
        recountPile()
    }

    /// Undoes the most recent decision and shows that asset again. Returns its ID.
    @discardableResult
    mutating func undo() -> String? {
        guard let id = history.popLast() else { return nil }
        let undone = decisions.removeValue(forKey: id)
        if let index = assets.firstIndex(where: { $0.id == id }) {
            adjustPileCounts(from: undone, to: nil)
            currentIndex = index
        }
        return id
    }

    /// Removes one decision without moving the deck, as from the review list.
    mutating func removeDecision(for assetID: String) {
        let removed = decisions.removeValue(forKey: assetID)
        history.removeAll { $0 == assetID }
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        adjustPileCounts(from: removed, to: nil)
        if index < currentIndex {
            // The card is behind the current one, so it would never be reached again without this.
            currentIndex = firstUndecidedIndex(from: 0)
        }
    }

    /// Forgets every decision ("Reset album") and starts from the top.
    mutating func reset() {
        decisions = [:]
        history = []
        pileCounts = [:]
        currentIndex = firstUndecidedIndex(from: 0)
    }

    // MARK: Updating the pile

    /// Replaces the pile, for example when another page loads or the sort order changes.
    ///
    /// With `keepPosition`, the current card stays on screen if it's still in the pile and undecided,
    /// so a page loading in the background never yanks the card away. Otherwise the deck jumps to the
    /// first undecided card.
    mutating func replaceAssets(_ newAssets: [Asset], keepPosition: Bool) {
        let currentID = current?.id
        assets = newAssets
        recountPile()
        if keepPosition, let currentID, let index = assets.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
        } else {
            currentIndex = firstUndecidedIndex(from: 0)
        }
    }

    /// Merges decisions loaded from storage. Decisions already made in memory win.
    mutating func mergeStoredDecisions(_ stored: [String: SwipeDecision], unsyncedHistory: [String]) {
        var added = false
        for (id, decision) in stored where decisions[id] == nil {
            decisions[id] = decision
            added = true
        }
        if added { recountPile() }
        let known = Set(history)
        history = unsyncedHistory.filter { !known.contains($0) && decisions[$0] != nil } + history
        if let current, decisions[current.id] != nil {
            currentIndex = firstUndecidedIndex(from: currentIndex)
        }
    }

    /// Drops assets that are gone from the server (deleted or locked by "Apply changes").
    mutating func removeAssets(_ assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        let currentID = current?.id
        assets.removeAll { assetIDs.contains($0.id) }
        for id in assetIDs { decisions[id] = nil }
        history.removeAll { assetIDs.contains($0) }
        recountPile()
        currentIndex = currentID.flatMap { id in assets.firstIndex { $0.id == id } } ?? firstUndecidedIndex(from: 0)
    }

    /// After "Apply changes" the applied decisions can no longer be undone.
    mutating func clearHistory() { history = [] }

    /// Edits assets in place, for example to show a favourite that has now reached the server.
    /// Decisions and the current card are untouched, so `transform` must not change an asset's ID.
    mutating func updateAssets(_ transform: (inout Asset) -> Void) {
        for index in assets.indices { transform(&assets[index]) }
    }

    // MARK: Helpers

    /// Counts the pile's decisions from scratch, after a change that already walks the pile.
    private mutating func recountPile() {
        var counts: [SwipeDecision: Int] = [:]
        for asset in assets {
            if let decision = decisions[asset.id] { counts[decision, default: 0] += 1 }
        }
        pileCounts = counts
    }

    /// Moves one asset in the pile from one decision's count to another's. Nil is undecided.
    private mutating func adjustPileCounts(from old: SwipeDecision?, to new: SwipeDecision?) {
        if let old { pileCounts[old, default: 0] -= 1 }
        if let new { pileCounts[new, default: 0] += 1 }
    }

    /// The next undecided card after `index`, wrapping to the top. Pages that load mid-session can sort
    /// photos in ahead of the current card; wrapping means those are still reached instead of skipped.
    private func nextUndecidedIndex(after index: Int) -> Int {
        let later = firstUndecidedIndex(from: index + 1)
        return later < assets.count ? later : firstUndecidedIndex(from: 0)
    }

    private func firstUndecidedIndex(from start: Int) -> Int {
        guard start < assets.count else { return assets.count }
        return assets[start...].firstIndex { decisions[$0.id] == nil } ?? assets.count
    }
}
