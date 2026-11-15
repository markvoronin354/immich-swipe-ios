import Foundation

/// The sort menu's two parts, as on Android: what to sort by, and in which order.
/// Every combination maps to one `DeckSortOrder`.
extension DeckSortOrder {
    enum Attribute: CaseIterable, Sendable { case date, size, type }
    enum Direction: CaseIterable, Sendable { case descending, ascending, shuffled }
    enum TypeFirst: CaseIterable, Sendable { case videos, photos }

    var attribute: Attribute {
        switch category {
        case .time: .date
        case .size: .size
        case .type: .type
        }
    }

    var direction: Direction {
        switch self {
        case .chronologicalDescending, .sizeDescending, .videosFirst, .photosFirst: .descending
        case .chronologicalAscending, .sizeAscending, .videosFirstAscending, .photosFirstAscending: .ascending
        case .shuffled, .videosFirstShuffled, .photosFirstShuffled: .shuffled
        }
    }

    var typeFirst: TypeFirst {
        switch self {
        case .photosFirst, .photosFirstAscending, .photosFirstShuffled: .photos
        default: .videos
        }
    }

    /// The order for a combination. Size has no shuffle, so it falls back to largest first.
    init(attribute: Attribute, direction: Direction, typeFirst: TypeFirst = .videos) {
        switch (attribute, direction, typeFirst) {
        case (.date, .descending, _): self = .chronologicalDescending
        case (.date, .ascending, _): self = .chronologicalAscending
        case (.date, .shuffled, _): self = .shuffled
        case (.size, .ascending, _): self = .sizeAscending
        case (.size, _, _): self = .sizeDescending
        case (.type, .descending, .videos): self = .videosFirst
        case (.type, .ascending, .videos): self = .videosFirstAscending
        case (.type, .shuffled, .videos): self = .videosFirstShuffled
        case (.type, .descending, .photos): self = .photosFirst
        case (.type, .ascending, .photos): self = .photosFirstAscending
        case (.type, .shuffled, .photos): self = .photosFirstShuffled
        }
    }

    /// Switching what to sort by keeps the order where it still makes sense.
    func with(attribute: Attribute) -> DeckSortOrder {
        DeckSortOrder(attribute: attribute, direction: direction, typeFirst: typeFirst)
    }

    func with(direction: Direction) -> DeckSortOrder {
        DeckSortOrder(attribute: attribute, direction: direction, typeFirst: typeFirst)
    }

    func with(typeFirst: TypeFirst) -> DeckSortOrder {
        DeckSortOrder(attribute: attribute, direction: direction, typeFirst: typeFirst)
    }

    /// Orders offered for the current attribute.
    var availableDirections: [Direction] {
        attribute == .size ? [.descending, .ascending] : Direction.allCases
    }
}

extension DeckSortOrder.Attribute {
    /// Where the sort popup starts when you switch to this category (Android's `onCategorySelected`).
    var defaultOrder: DeckSortOrder {
        switch self {
        case .date: .chronologicalDescending
        case .size: .sizeDescending
        case .type: .videosFirst
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .date: "Date"
        case .size: "Size"
        case .type: "Type"
        }
    }
}

extension DeckSortOrder.TypeFirst {
    var title: LocalizedStringResource {
        switch self {
        case .videos: "Videos First"
        case .photos: "Photos First"
        }
    }
}

extension DeckSortOrder.Direction {
    func title(for attribute: DeckSortOrder.Attribute) -> LocalizedStringResource {
        switch (self, attribute) {
        case (.descending, .size): "Largest First"
        case (.ascending, .size): "Smallest First"
        case (.descending, _): "Newest First"
        case (.ascending, _): "Oldest First"
        case (.shuffled, _): "Shuffle"
        }
    }

    var systemImage: String {
        switch self {
        case .descending: "arrow.down"
        case .ascending: "arrow.up"
        case .shuffled: "shuffle"
        }
    }
}

extension DeckSortOrder {
    /// The Sort button's icon for this order, matching Android's choice per mode.
    var systemImage: String {
        switch self {
        case .shuffled: "shuffle"
        case .chronologicalAscending: "arrow.up"
        case .chronologicalDescending: "arrow.down"
        case .sizeDescending: "chevron.down"
        case .sizeAscending: "chevron.up"
        case .videosFirst, .videosFirstAscending, .videosFirstShuffled: "video"
        case .photosFirst, .photosFirstAscending, .photosFirstShuffled: "photo"
        }
    }
}
