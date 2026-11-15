import Foundation

/// What "Apply changes" is about to do, worked out from the deck and shown for confirmation first.
///
/// Only decisions that haven't been applied yet are included, so applying twice never repeats work
/// or counts the same photos twice in the history.
nonisolated struct ApplyPlan: Equatable, Sendable {
    struct Rotation: Equatable, Sendable {
        var assetID: String
        var angle: Int
    }

    var delete: [Asset] = []
    var archive: [Asset] = []
    var lock: [Asset] = []
    /// Kept photos need no server call; applying just records them as done.
    var keep: [Asset] = []
    var favoritesOn: [String] = []
    var favoritesOff: [String] = []
    var rotations: [Rotation] = []
    /// Rotated photos that Immich already has edits for. Sending a rotation replaces the edit list,
    /// which would drop a crop, so these are left alone.
    var skippedRotationIDs: [String] = []

    var bytesToFree: Int64 { delete.reduce(0) { $0 + ($1.fileSize ?? 0) } }

    var isEmpty: Bool {
        delete.isEmpty && archive.isEmpty && lock.isEmpty && keep.isEmpty
            && favoritesOn.isEmpty && favoritesOff.isEmpty && rotations.isEmpty
    }

    /// Changes that reach the server.
    var serverChangeCount: Int {
        delete.count + archive.count + lock.count + favoritesOn.count + favoritesOff.count + rotations.count
    }

    /// Everything waiting, including kept photos.
    var pendingCount: Int { serverChangeCount + keep.count }

    /// - Parameters:
    ///   - pending: IDs of decisions not yet applied.
    ///   - favorites: Local favourite changes, by asset ID.
    ///   - rotations: Local rotations in degrees, by asset ID.
    static func make(deck: Deck, pending: Set<String>, favorites: [String: Bool], rotations: [String: Int]) -> ApplyPlan {
        var plan = ApplyPlan()
        for asset in deck.assets {
            var isBeingDeleted = false
            if pending.contains(asset.id), let decision = deck.decision(for: asset.id) {
                switch decision {
                case .keep: plan.keep.append(asset)
                case .delete:
                    plan.delete.append(asset)
                    isBeingDeleted = true
                case .archive: plan.archive.append(asset)
                case .lock: plan.lock.append(asset)
                }
            }
            // Favouriting or rotating a photo that's about to be trashed would be wasted calls.
            guard !isBeingDeleted else { continue }

            if let favorite = favorites[asset.id] {
                if favorite { plan.favoritesOn.append(asset.id) } else { plan.favoritesOff.append(asset.id) }
            }
            if let angle = rotations[asset.id], angle % 360 != 0 {
                if asset.isEdited {
                    plan.skippedRotationIDs.append(asset.id)
                } else {
                    plan.rotations.append(Rotation(assetID: asset.id, angle: angle))
                }
            }
        }
        return plan
    }
}
