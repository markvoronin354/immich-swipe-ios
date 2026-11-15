import Foundation

/// One row on the home screen: a real album or one of the special collections.
nonisolated struct HomeEntry: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable { case all, orphans, duplicates, album }

    var album: Album
    var kind: Kind
    /// Nil when the count couldn't be loaded, so the UI shows a dash instead of a misleading 0.
    var assetCount: Int?
    var progress: AlbumProgress

    var id: String { album.id }

    /// Decided count capped at the album size, since an album can shrink after decisions were made.
    var decidedCount: Int {
        guard let assetCount, assetCount > 0 else { return progress.decided }
        return min(progress.decided, assetCount)
    }

    var isCompleted: Bool { (assetCount ?? 0) > 0 && decidedCount >= (assetCount ?? 0) }
}

/// The home screen's groups, in display order (spec: Special collections, In progress, Not started, Completed).
nonisolated struct HomeSections: Equatable, Sendable {
    var collections: [HomeEntry] = []
    var inProgress: [HomeEntry] = []
    var notStarted: [HomeEntry] = []
    var completed: [HomeEntry] = []

    var isEmpty: Bool { collections.isEmpty && inProgress.isEmpty && notStarted.isEmpty && completed.isEmpty }

    struct CollectionCounts: Equatable, Sendable {
        var all: Int?
        var orphans: Int?
        var duplicates: Int?
    }

    /// Builds the sections. Albums keep the server's order within each group.
    /// Special collections with a count of zero are hidden, like on Android; ones whose count failed are kept.
    static func make(
        albums: [Album],
        counts: CollectionCounts,
        progress: [String: AlbumProgress],
        totalProgress: AlbumProgress,
        names: (HomeEntry.Kind) -> String,
        query: String = ""
    ) -> HomeSections {
        var sections = HomeSections()

        let specials: [(HomeEntry.Kind, String, Int?, AlbumProgress)] = [
            (.all, Album.virtualAllID, counts.all, totalProgress),
            (.orphans, Album.virtualOrphansID, counts.orphans, progress[Album.virtualOrphansID] ?? AlbumProgress()),
            (.duplicates, Album.virtualDuplicatesID, counts.duplicates, progress[Album.virtualDuplicatesID] ?? AlbumProgress()),
        ]
        for (kind, id, count, albumProgress) in specials where count != 0 {
            let album = Album(id: id, albumName: names(kind), assetCount: count ?? 0)
            sections.collections.append(HomeEntry(album: album, kind: kind, assetCount: count, progress: albumProgress))
        }

        for album in albums where !album.isVirtual {
            let entry = HomeEntry(album: album, kind: .album, assetCount: album.assetCount, progress: progress[album.id] ?? AlbumProgress())
            if entry.isCompleted {
                sections.completed.append(entry)
            } else if entry.decidedCount > 0 {
                sections.inProgress.append(entry)
            } else {
                sections.notStarted.append(entry)
            }
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sections }
        func matches(_ entry: HomeEntry) -> Bool {
            entry.album.albumName.localizedStandardContains(trimmed)
                || (entry.album.description?.localizedStandardContains(trimmed) ?? false)
        }
        sections.collections = sections.collections.filter(matches)
        sections.inProgress = sections.inProgress.filter(matches)
        sections.notStarted = sections.notStarted.filter(matches)
        sections.completed = sections.completed.filter(matches)
        return sections
    }
}
