import Foundation
import Testing
@testable import Immich_Swipe_iOS

struct DeckSortOrderTests {
    private func asset(_ id: String, _ date: String, _ type: AssetType = .image, size: Int64? = nil) -> Asset {
        Asset(id: id, ownerId: "u", fileCreatedAt: date, type: type, exifInfo: size.map { ExifInfo(fileSizeInByte: $0) })
    }

    private var pile: [Asset] {
        [
            asset("p1", "2024-03", size: 10),
            asset("v1", "2024-01", .video, size: 50),
            asset("p2", "2024-02"),
            asset("v2", "2024-03", .video, size: 50),
        ]
    }

    private func ids(_ order: DeckSortOrder) -> [String] { order.sorted(pile, seed: 42).map(\.id) }

    /// Expected values come from the Kotlin `getShuffleHash`, so shuffled decks match the Android app.
    @Test(arguments: [
        ("a1b2c3d4-0000-4000-8000-000000000001", Int64(1_657_547_346_078_948_075)),
        ("ffffffff-ffff-4fff-bfff-ffffffffffff", Int64(-9_196_012_254_468_081_634)),
        ("é", Int64(7_505_033_314_976_657_345)),
    ])
    func shuffleHashMatchesKotlin(id: String, expected: Int64) {
        #expect(DeckSortOrder.shuffleHash(id, seed: 1_730_460_000_000) == expected)
    }

    @Test func chronologicalOrdersKeepTiesInInputOrder() {
        #expect(ids(.chronologicalDescending) == ["p1", "v2", "p2", "v1"])
        #expect(ids(.chronologicalAscending) == ["v1", "p2", "p1", "v2"])
    }

    @Test func sizeOrdersTreatMissingSizeAsZero() {
        #expect(ids(.sizeDescending) == ["v1", "v2", "p1", "p2"])
        #expect(ids(.sizeAscending) == ["p2", "p1", "v1", "v2"])
    }

    @Test func typeOrdersGroupThenSortByDate() {
        #expect(ids(.videosFirst) == ["v2", "v1", "p1", "p2"])
        #expect(ids(.photosFirst) == ["p1", "p2", "v2", "v1"])
        #expect(ids(.videosFirstAscending) == ["v1", "v2", "p2", "p1"])
        #expect(ids(.photosFirstAscending) == ["p2", "p1", "v1", "v2"])
    }

    @Test func shuffledOrdersAreStablePerSeedAndKeepTypeGroups() {
        #expect(ids(.shuffled) == ids(.shuffled))
        #expect(Set(ids(.videosFirstShuffled).prefix(2)) == ["v1", "v2"])
        #expect(Set(ids(.photosFirstShuffled).prefix(2)) == ["p1", "p2"])
    }

    @Test func everyOrderRoundTripsThroughTheTwoPartMenu() {
        for order in DeckSortOrder.allCases {
            #expect(DeckSortOrder(attribute: order.attribute, direction: order.direction, typeFirst: order.typeFirst) == order)
        }
    }

    @Test func switchingAttributeKeepsTheOrderWherePossible() {
        #expect(DeckSortOrder.chronologicalAscending.with(attribute: .size) == .sizeAscending)
        #expect(DeckSortOrder.shuffled.with(attribute: .size) == .sizeDescending)
        #expect(DeckSortOrder.shuffled.with(attribute: .type) == .videosFirstShuffled)
        #expect(DeckSortOrder.sizeAscending.with(attribute: .type) == .videosFirstAscending)
    }

    @Test func typeToggleKeepsOrder() {
        // Android picks Photos-first shuffled here even for videos; this keeps the user's choice.
        #expect(DeckSortOrder.videosFirst.with(direction: .shuffled) == .videosFirstShuffled)
        #expect(DeckSortOrder.videosFirstShuffled.with(typeFirst: .photos) == .photosFirstShuffled)
        #expect(DeckSortOrder.photosFirstAscending.with(typeFirst: .videos) == .videosFirstAscending)
    }

    @Test func sizeOffersNoShuffle() {
        #expect(DeckSortOrder.sizeDescending.availableDirections == [.descending, .ascending])
        #expect(DeckSortOrder.videosFirst.availableDirections.count == 3)
    }

    @Test func rawValuesMatchAndroid() {
        #expect(DeckSortOrder(rawValue: "TYPE_PHOTO_FIRST_SHUFFLED") == .photosFirstShuffled)
        #expect(DeckSortOrder.default.rawValue == "CHRONOLOGICAL_DESC")
        #expect(DeckSortOrder.allCases.count == 11)
    }
}
