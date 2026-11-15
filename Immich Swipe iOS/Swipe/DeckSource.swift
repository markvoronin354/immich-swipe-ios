import Foundation

/// Where a deck's photos come from (spec §3.5).
nonisolated enum DeckSource: Hashable, Sendable {
    case all
    case orphans
    case duplicates
    case album(id: String)

    init(_ entry: HomeEntry) {
        switch entry.kind {
        case .all: self = .all
        case .orphans: self = .orphans
        case .duplicates: self = .duplicates
        case .album: self = .album(id: entry.album.id)
        }
    }

    /// The album ID decisions are saved under. Pseudo-albums use their virtual IDs.
    var albumID: String {
        switch self {
        case .all: Album.virtualAllID
        case .orphans: Album.virtualOrphansID
        case .duplicates: Album.virtualDuplicatesID
        case .album(let id): id
        }
    }

    /// Duplicates stay grouped by cluster, so the user's sort order doesn't apply to them.
    var supportsSorting: Bool { self != .duplicates }

    /// The first search request, or nil for duplicates, which come from their own endpoint.
    /// "Include external archives" (spec §3.7 quirk 2, settled here) applies to every deck: with it, no
    /// visibility is sent, so the server returns timeline and archived photos, as Android does for its
    /// counts. Without it, only timeline photos.
    func firstSearch(order: DeckSortOrder, includeArchived: Bool) -> MetadataSearch? {
        let visibility: AssetVisibility? = includeArchived ? nil : .timeline
        return switch self {
        case .all:
            MetadataSearch(visibility: visibility, order: order.searchDirection)
        case .orphans:
            MetadataSearch(isNotInAlbum: true, visibility: visibility, order: order.searchDirection)
        case .album(let id):
            MetadataSearch(albumIds: [id], visibility: visibility, order: order.searchDirection)
        case .duplicates:
            nil
        }
    }

    /// Duplicate clusters flattened in the Android order: biggest clusters first (then most bytes),
    /// and within a cluster, largest file first (then most pixels).
    static func flatten(_ groups: [DuplicateGroup]) -> [Asset] {
        func bytes(_ asset: Asset) -> Int64 { asset.fileSize ?? 0 }
        func pixels(_ asset: Asset) -> Int { (asset.exifInfo?.exifImageWidth ?? 0) * (asset.exifInfo?.exifImageHeight ?? 0) }

        return groups
            .sorted { lhs, rhs in
                if lhs.assets.count != rhs.assets.count { return lhs.assets.count > rhs.assets.count }
                return lhs.assets.reduce(0) { $0 + bytes($1) } > rhs.assets.reduce(0) { $0 + bytes($1) }
            }
            .flatMap { group in
                group.assets.sorted { lhs, rhs in
                    if bytes(lhs) != bytes(rhs) { return bytes(lhs) > bytes(rhs) }
                    return pixels(lhs) > pixels(rhs)
                }
            }
    }
}
