import Foundation

/// One row on the home screen: a real album or one of the special collections.
nonisolated struct HomeEntry: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable { case all, orphans, duplicates, album }

    var album: Album
    var kind: Kind
    /// Nil when the count couldn't be loaded, so the UI shows a dash instead of a misleading 0.
    var assetCount: Int?
    var progress: AlbumProgress
    /// Every photo in the album belongs to someone else, so there is nothing here for this user to sort.
    var nothingToSort = false

    var id: String { album.id }

    /// Decided count capped at the album size, since an album can shrink after decisions were made.
    var decidedCount: Int {
        guard let assetCount, assetCount > 0 else { return progress.decided }
        return min(progress.decided, assetCount)
    }

    var isCompleted: Bool { (assetCount ?? 0) > 0 && decidedCount >= (assetCount ?? 0) }
}

/// Albums found to hold only other users' photos, remembered between launches as "userID:albumID" so Home
/// can say so without opening them. A deck records the answer once it has loaded from the server.
nonisolated enum NothingToSort {
    static let key = "nothing_to_sort_albums"

    static func ids(userID: String, defaults: UserDefaults = .standard) -> Set<String> {
        let prefix = "\(userID):"
        return Set((defaults.stringArray(forKey: key) ?? []).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    static func set(_ nothingToSort: Bool, albumID: String, userID: String, defaults: UserDefaults = .standard) {
        var entries = Set(defaults.stringArray(forKey: key) ?? [])
        if nothingToSort { entries.insert("\(userID):\(albumID)") } else { entries.remove("\(userID):\(albumID)") }
        defaults.set(entries.sorted(), forKey: key)
    }
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
        nothingToSort: Set<String> = [],
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
            let entry = HomeEntry(album: album, kind: .album, assetCount: album.assetCount, progress: progress[album.id] ?? AlbumProgress(), nothingToSort: nothingToSort.contains(album.id))
            // Nothing for the user to do, so it shouldn't sit under "Not started".
            if entry.isCompleted || entry.nothingToSort {
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
