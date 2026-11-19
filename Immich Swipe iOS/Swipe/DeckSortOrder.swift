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
            stableSorted(assets, by: Self.newerFirst)
        case .chronologicalAscending:
            stableSorted(assets, by: Self.olderFirst)
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

    /// `sorted`, an earlier result of `sorted(_:seed:)`, with `added` put in: the same as sorting all of them
    /// again with `added` after the others, so among equal dates the photos already there stay first.
    /// Only the date orders sort each page in as it lands, and only they can merge; the others return nil.
    ///
    /// Each added photo is placed by binary search, so a page of 500 goes into a pile of 100,000 in a small
    /// fraction of what sorting the whole pile again costs.
    func merging(_ added: [Asset], into sorted: [Asset], seed: Int64) -> [Asset]? {
        let goesBefore: (Asset, Asset) -> Bool
        switch self {
        case .chronologicalDescending: goesBefore = Self.newerFirst
        case .chronologicalAscending: goesBefore = Self.olderFirst
        default: return nil
        }
        var result: [Asset] = []
        result.reserveCapacity(sorted.count + added.count)
        var rest = sorted[...]
        for asset in self.sorted(added, seed: seed) {
            // The photos it goes before start where the pile stops going before or level with it.
            var low = rest.startIndex, high = rest.endIndex
            while low < high {
                let middle = low + (high - low) / 2
                if goesBefore(asset, rest[middle]) { high = middle } else { low = middle + 1 }
            }
            result.append(contentsOf: rest[..<low])
            result.append(asset)
            rest = rest[low...]
        }
        result.append(contentsOf: rest)
        return result
    }

    private static func newerFirst(_ lhs: Asset, _ rhs: Asset) -> Bool { lhs.effectiveDate > rhs.effectiveDate }
    private static func olderFirst(_ lhs: Asset, _ rhs: Asset) -> Bool { lhs.effectiveDate < rhs.effectiveDate }

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
