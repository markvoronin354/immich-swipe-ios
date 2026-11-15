import Foundation
import Testing
@testable import Immich_Swipe_iOS

struct ModelCodingTests {
    private func decodeAsset(_ json: String) throws -> Asset {
        try JSONDecoder().decode(Asset.self, from: Data(json.utf8))
    }

    @Test func decodesCurrentServerAsset() throws {
        let asset = try decodeAsset("""
        {"id":"a","ownerId":"u","fileCreatedAt":"2024-01-02T03:04:05.000Z","type":"VIDEO","duration":5250,
         "isFavorite":true,"isArchived":false,"isTrashed":false,"isEdited":true,"visibility":"locked",
         "originalFileName":"clip.MOV","exifInfo":{"fileSizeInByte":1234,"dateTimeOriginal":"2023-12-31T23:00:00.000Z","description":"At the beach"}}
        """)
        #expect(asset.type == .video)
        #expect(asset.exifInfo?.description == "At the beach")
        #expect(asset.durationMilliseconds == 5250)
        #expect(asset.isLocked)
        #expect(asset.isEdited)
        #expect(asset.fileSize == 1234)
        #expect(asset.effectiveDate == "2023-12-31T23:00:00.000Z")
        #expect(!asset.isGIF)
    }

    @Test func decodesLegacyServerAsset() throws {
        let asset = try decodeAsset("""
        {"id":"b","ownerId":"u","fileCreatedAt":"2024-01-02T03:04:05.000Z","type":"IMAGE",
         "duration":"0:01:02.500000","isFavorite":false,"isArchived":true,"isTrashed":false,"originalFileName":"cat.GIF"}
        """)
        #expect(asset.durationMilliseconds == 62_500)
        #expect(asset.isArchived)
        #expect(asset.visibility == nil)
        #expect(asset.isGIF)
        #expect(asset.effectiveDate == "2024-01-02T03:04:05.000Z")
    }

    @Test func toleratesUnknownEnumValuesAndMissingFields() throws {
        let asset = try decodeAsset("""
        {"id":"c","ownerId":"u","fileCreatedAt":"x","type":"PANORAMA","duration":null,"visibility":"somethingNew"}
        """)
        #expect(asset.type == .other)
        #expect(asset.visibility == nil)
        #expect(asset.durationMilliseconds == nil)
        #expect(!asset.isFavorite)
    }

    @Test func blankEXIFDateFallsBackToFileDate() throws {
        let asset = try decodeAsset("""
        {"id":"d","ownerId":"u","fileCreatedAt":"2024-05-05","type":"IMAGE","exifInfo":{"dateTimeOriginal":""}}
        """)
        #expect(asset.effectiveDate == "2024-05-05")
    }

    @Test func searchBodyLeavesOutNilFields() throws {
        let body = String(decoding: try JSONEncoder().encode(MetadataSearch(isNotInAlbum: true, visibility: .timeline, order: .desc)), as: UTF8.self)
        #expect(body.contains(#""isNotInAlbum":true"#))
        #expect(body.contains(#""visibility":"timeline""#))
        #expect(!body.contains("albumIds"))
        #expect(!body.contains("cursor"))
        #expect(!body.contains("page"))
    }

    @Test func virtualAndSkipAlbumsAreVirtual() {
        #expect(Album(id: Album.virtualAllID, albumName: "All", assetCount: 0).isVirtual)
        #expect(Album(id: "x", albumName: "skip", assetCount: 0).isVirtual)
        #expect(!Album(id: "x", albumName: "Holidays", assetCount: 0).isVirtual)
    }
}

struct PagingTests {
    private let base = MetadataSearch()

    @Test func prefersCursorWhenServerSendsOne() {
        let next = base.next(after: SearchPage(items: [], total: 0, nextPage: "2", nextCursor: "abc"))
        #expect(next?.cursor == "abc")
        #expect(next?.page == nil)
    }

    @Test func fallsBackToPageNumbers() {
        let next = base.next(after: SearchPage(items: [], total: 0, nextPage: "2", nextCursor: nil))
        #expect(next?.page == 2)
        #expect(next?.cursor == nil)
    }

    @Test func stopsOnLastPage() {
        #expect(base.next(after: SearchPage(items: [], total: 0, nextPage: nil, nextCursor: nil)) == nil)
    }
}
