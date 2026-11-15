import Foundation

/// Deck orderings, grouped into Time, Size and Type in the sort menu (spec §3.4).
/// Raw values match the Android names so exported settings stay compatible.
nonisolated enum DeckSortOrder: String, CaseIterable, Codable, Sendable {
    case chronologicalDescending = "CHRONOLOGICAL_DESC"
    case chronologicalAscending = "CHRONOLOGICAL_ASC"
    case shuffled = "SHUFFLED"
    case sizeDescending = "SIZE_DESC"
    case sizeAscending = "SIZE_ASC"
    case videosFirst = "TYPE_VIDEO_FIRST"
    case photosFirst = "TYPE_PHOTO_FIRST"
    case videosFirstAscending = "TYPE_VIDEO_FIRST_ASC"
    case photosFirstAscending = "TYPE_PHOTO_FIRST_ASC"
    case videosFirstShuffled = "TYPE_VIDEO_FIRST_SHUFFLED"
    case photosFirstShuffled = "TYPE_PHOTO_FIRST_SHUFFLED"

    static let `default` = DeckSortOrder.chronologicalDescending

    enum Category: Sendable { case time, size, type }

    var category: Category {
        switch self {
        case .chronologicalDescending, .chronologicalAscending, .shuffled: .time
        case .sizeDescending, .sizeAscending: .size
        default: .type
        }
    }

    /// Server-side order hint for `POST /search/metadata`, so the first page arrives roughly sorted.
    var searchDirection: MetadataSearch.SortDirection {
        switch self {
        case .chronologicalAscending, .sizeAscending, .videosFirstAscending, .photosFirstAscending: .asc
        default: .desc
        }
    }

    /// Returns `assets` in this order. Ties keep their input order, like Kotlin's stable sorts.
    /// `seed` drives the shuffled orders; the app uses one per launch so shuffles stay put within a session.
    func sorted(_ assets: [Asset], seed: Int64) -> [Asset] {
        switch self {
        case .chronologicalDescending:
            stableSorted(assets) { $0.effectiveDate > $1.effectiveDate }
        case .chronologicalAscending:
            stableSorted(assets) { $0.effectiveDate < $1.effectiveDate }
        case .sizeDescending:
            stableSorted(assets) { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeAscending:
            stableSorted(assets) { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        case .shuffled:
            Self.shuffled(assets, seed: seed)
        case .videosFirst, .videosFirstAscending, .videosFirstShuffled,
             .photosFirst, .photosFirstAscending, .photosFirstShuffled:
            typeSorted(assets, seed: seed)
        }
    }

    private func typeSorted(_ assets: [Asset], seed: Int64) -> [Asset] {
        let target: AssetType = [.videosFirst, .videosFirstAscending, .videosFirstShuffled].contains(self) ? .video : .image
        let primary = assets.filter { $0.type == target }
        let secondary = assets.filter { $0.type != target }

        switch self {
        case .videosFirstShuffled, .photosFirstShuffled:
            return Self.shuffled(primary, seed: seed) + Self.shuffled(secondary, seed: seed)
        case .videosFirstAscending, .photosFirstAscending:
            return stableSorted(primary) { $0.effectiveDate < $1.effectiveDate }
                + stableSorted(secondary) { $0.effectiveDate < $1.effectiveDate }
        default:
            return stableSorted(primary) { $0.effectiveDate > $1.effectiveDate }
                + stableSorted(secondary) { $0.effectiveDate > $1.effectiveDate }
        }
    }

    private static func shuffled(_ assets: [Asset], seed: Int64) -> [Asset] {
        stableSorted(assets.map { (hash: shuffleHash($0.id, seed: seed), asset: $0) }) { $0.hash < $1.hash }.map(\.asset)
    }

    /// Port of the Android `getShuffleHash`: a Java-style string hash finished with MurmurHash3's fmix64.
    /// Uses wrapping 64-bit arithmetic and UTF-16 code units so results match the Kotlin original exactly.
    static func shuffleHash(_ id: String, seed: Int64) -> Int64 {
        func mix(_ x: Int64) -> Int64 { x ^ Int64(bitPattern: UInt64(bitPattern: x) >> 33) }
        var h = seed ^ 0x5DEECE66D
        for unit in id.utf16 { h = h &* 31 &+ Int64(unit) }
        h = mix(h)
        h = h &* Int64(bitPattern: 0xff51afd7ed558ccd)
        h = mix(h)
        h = h &* Int64(bitPattern: 0xc4ceb9fe1a85ec53)
        return mix(h)
    }
}

/// Sorts with ties broken by original position, so equal keys never swap between re-sorts.
private nonisolated func stableSorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
    items.enumerated()
        .sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) { return true }
            if areInIncreasingOrder(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
}
