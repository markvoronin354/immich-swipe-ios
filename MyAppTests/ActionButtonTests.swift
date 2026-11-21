import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Immich_Swipe_iOS

private func assetJSON(_ id: String, date: String, name: String? = nil, type: String = "IMAGE") -> String {
    let file = name.map { #","originalFileName":"\#($0)""# } ?? ""
    return #"{"id":"\#(id)","ownerId":"u","fileCreatedAt":"\#(date)","type":"\#(type)","isFavorite":false,"isArchived":false,"isTrashed":false,"isEdited":false\#(file)}"#
}

@MainActor
final class FakePhotoSaver: PhotoSaving {
    struct Saved: Equatable { var name: String; var contents: String; var isVideo: Bool }
    var saved: [Saved] = []
    var error: Error?

    func save(fileAt url: URL, isVideo: Bool) async throws {
        if let error { throw error }
        // The file must exist and be complete at the moment Photos is asked to copy it.
        let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        saved.append(Saved(name: url.lastPathComponent, contents: contents, isVideo: isVideo))
    }
}

struct FileNameTests {
    @Test(arguments: [
        ("IMG_0001.HEIC", "IMG_0001.HEIC"),
        ("../../etc/passwd", "passwd"),
        ("C:\\Users\\me\\photo.jpg", "photo.jpg"),
        ("IMG:1.jpg", "IMG_1.jpg"),
        ("  spaced.png  ", "spaced.png"),
    ] as [(String, String)])
    func keepsOnlyASafeFileName(raw: String, expected: String) {
        #expect(ImmichClient.safeFileName(raw, fallback: "fallback") == expected)
    }

    @Test(arguments: [nil, "", "   ", "/", "..", "."] as [String?])
    func fallsBackWhenThereIsNoUsableName(raw: String?) {
        #expect(ImmichClient.safeFileName(raw, fallback: "asset-id") == "asset-id")
    }
}

@MainActor
struct DownloadAndFullResolutionTests {
    let host = "buttons-\(UUID().uuidString.prefix(8).lowercased()).example.com"
    let store: DecisionStore
    let defaults: UserDefaults
    let saver = FakePhotoSaver()

    init() throws {
        store = try DecisionStore.inMemory()
        defaults = UserDefaults(suiteName: "button-tests-\(UUID().uuidString)")!
    }

    private func makeClient() -> ImmichClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingServer.self]
        return ImmichClient(serverURL: URL(string: "https://\(host)")!, apiKey: "KEY", session: URLSession(configuration: configuration), retry: .none)
    }

    /// Two photos and a video, plus their originals.
    private func serve(originalStatus: Int = 200) {
        let items = [
            assetJSON("photo", date: "2024-03", name: "IMG_0001.JPG"),
            assetJSON("other", date: "2024-02", name: "IMG_0002.JPG"),
            assetJSON("clip", date: "2024-01", name: "clip.MOV", type: "VIDEO"),
        ].joined(separator: ",")
        RoutingServer.route(host: host) { method, path, _ in
            switch (method, path) {
            case ("POST", "/api/search/statistics"): return (200, #"{"total":3}"#)
            case ("POST", "/api/search/metadata"): return (200, #"{"assets":{"items":[\#(items)],"total":3,"nextPage":null,"nextCursor":null}}"#)
            case ("GET", "/api/assets/photo/original"): return (originalStatus, originalStatus == 200 ? "PHOTO-BYTES" : #"{"message":"nope"}"#)
            case ("GET", "/api/assets/clip/original"): return (200, "VIDEO-BYTES")
            default: return (404, "{}")
            }
        }
    }

    private func loadedModel() async -> DeckModel {
        serve()
        let model = DeckModel(title: "T", source: .all, client: makeClient(), userID: "u", decisions: store, shuffleSeed: 1, defaults: defaults, photoSaver: saver, listingCache: .temporary())
        await model.load()
        return model
    }

    // MARK: Download to the client

    @Test func downloadsTheOriginalUnderItsOwnName() async throws {
        serve()
        let asset = try JSONDecoder().decode(Asset.self, from: Data(assetJSON("photo", date: "2024", name: "IMG_0001.JPG").utf8))
        let file = try await makeClient().downloadOriginal(of: asset)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(file.lastPathComponent == "IMG_0001.JPG")
        #expect(file.deletingLastPathComponent().lastPathComponent == "photo", "one folder per asset")
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "PHOTO-BYTES")
        let request = try #require(RoutingServer.requests(host: host).last)
        #expect(request.path == "/api/assets/photo/original")
    }

    @Test func aFailedDownloadThrowsAndLeavesNothingBehind() async throws {
        serve(originalStatus: 404)
        let asset = try JSONDecoder().decode(Asset.self, from: Data(assetJSON("photo", date: "2024", name: "IMG_0001.JPG").utf8))
        await #expect(throws: ImmichError.self) { _ = try await makeClient().downloadOriginal(of: asset) }
        let leftover = FileManager.default.temporaryDirectory.appending(path: "immich-downloads/photo/IMG_0001.JPG")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: Download to Photos

    @Test func savesTheOriginalToPhotosAndCleansUp() async throws {
        let model = await loadedModel()
        await model.downloadCurrent()

        #expect(model.transfer == .saved)
        #expect(saver.saved == [.init(name: "IMG_0001.JPG", contents: "PHOTO-BYTES", isVideo: false)])
        #expect(model.downloadingAssetID == nil)
        let folder = FileManager.default.temporaryDirectory.appending(path: "immich-downloads/photo")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the temporary copy is deleted once Photos has its own")
    }

    @Test func aVideoIsSavedAsAVideo() async {
        let model = await loadedModel()
        model.move(toAssetID: "clip")
        await model.downloadCurrent()
        #expect(saver.saved == [.init(name: "clip.MOV", contents: "VIDEO-BYTES", isVideo: true)])
    }

    @Test func aRefusedPhotoLibraryIsReportedWithAReason() async {
        let model = await loadedModel()
        saver.error = PhotoLibraryAccessDenied()
        await model.downloadCurrent()

        guard case .failed(let message) = model.transfer else {
            Issue.record("expected a failure, got \(String(describing: model.transfer))")
            return
        }
        #expect(message.contains("Photos"))
        #expect(model.downloadingAssetID == nil)
        model.clearTransfer()
        #expect(model.transfer == nil)
    }

    @Test func aServerErrorIsReportedAndNothingIsSaved() async {
        let model = await loadedModel()
        serve(originalStatus: 404)
        await model.downloadCurrent()
        #expect(saver.saved.isEmpty)
        if case .failed = model.transfer {} else { Issue.record("expected a failure") }
    }

    // MARK: Full resolution

    @Test func fullResolutionAppliesToOnePhotoUnlessKeptWhileSwiping() async throws {
        let model = await loadedModel()
        let photo = try #require(model.deck.current)
        #expect(!model.usesFullResolution(photo, keepWhileSwiping: false))

        model.toggleFullResolution(keepWhileSwiping: false)
        #expect(model.usesFullResolution(photo, keepWhileSwiping: false))

        model.decide(.keep)
        let next = try #require(model.deck.current)
        #expect(!model.usesFullResolution(next, keepWhileSwiping: false), "back to the preview on the next photo")
        #expect(model.usesFullResolution(next, keepWhileSwiping: true), "unless it should stay on")
    }

    @Test func togglingOnTheNextPhotoTurnsItOnInsteadOfOff() async throws {
        let model = await loadedModel()
        model.toggleFullResolution(keepWhileSwiping: false) // on for the first photo
        model.decide(.keep)
        model.toggleFullResolution(keepWhileSwiping: false) // second photo: should switch ON
        let second = try #require(model.deck.current)
        #expect(model.usesFullResolution(second, keepWhileSwiping: false))
        model.toggleFullResolution(keepWhileSwiping: false)
        #expect(!model.usesFullResolution(second, keepWhileSwiping: false))
    }

    @Test func videosNeverUseFullResolution() async throws {
        let model = await loadedModel()
        model.toggleFullResolution(keepWhileSwiping: true)
        let clip = try #require(model.deck.assets.first { $0.id == "clip" })
        #expect(!model.usesFullResolution(clip, keepWhileSwiping: true))
    }

    @Test func theShareItemCarriesTheOriginalFileName() async throws {
        let model = await loadedModel()
        let item = model.shareable(try #require(model.deck.current))
        #expect(item.fileName == "IMG_0001.JPG")
    }
}

@MainActor
struct DeckVideoPlayerTests {
    private func video() throws -> Asset {
        try JSONDecoder().decode(Asset.self, from: Data(assetJSON("clip", date: "2024", type: "VIDEO").utf8))
    }

    private func client() -> ImmichClient {
        ImmichClient(serverURL: URL(string: "https://videos.example.com")!, apiKey: "KEY")
    }

    @Test func playsTheServersPlaybackURL() throws {
        let asset = DeckVideoPlayer.makeAsset(for: try video(), using: client())
        #expect(asset.url.absoluteString == "https://videos.example.com/api/assets/clip/video/playback")
    }

    @Test func muteCarriesToTheNextVideo() throws {
        let player = DeckVideoPlayer()
        #expect(!player.isMuted && !player.player.isMuted)
        player.toggleMute()
        #expect(player.isMuted && player.player.isMuted)

        player.play(try video(), using: client())
        #expect(player.assetID == "clip")
        #expect(player.player.isMuted, "a new video starts muted if the last one was")
        player.stop()
        #expect(player.assetID == nil)

        player.toggleMute()
        #expect(!player.isMuted && !player.player.isMuted)
    }
}

/// The swipe badge keeps clear of the card buttons in its corner.
struct IntentStampPlacementTests {
    private func layout(_ corner: IconPosition, _ orientation: ButtonStackOrientation) -> CardButtonLayout {
        var layout = CardButtonLayout.default
        layout.show = Dictionary(uniqueKeysWithValues: CardButton.allCases.map { ($0, $0 == .fullscreen || $0 == .download) })
        layout.position = Dictionary(uniqueKeysWithValues: CardButton.allCases.map { ($0, corner) })
        layout.orientation = orientation
        return layout
    }

    @Test func emptyCornerUsesAndroidsInsets() {
        let insets = IntentStamp.cardInsets(for: SwipeIntent(action: .delete, edge: .leading), layout: layout(.topLeft, .vertical), isVideo: false)
        #expect(insets.top == 60 && insets.side == 60)
    }

    @Test func columnInItsCornerPushesTheBadgeInFromTheSide() {
        let insets = IntentStamp.cardInsets(for: SwipeIntent(action: .delete, edge: .leading), layout: layout(.topRight, .vertical), isVideo: false)
        #expect(insets.top == 60 && insets.side == 76)
    }

    @Test func rowInItsCornerPushesTheBadgeDown() {
        let insets = IntentStamp.cardInsets(for: SwipeIntent(action: .keep, edge: .trailing), layout: layout(.topLeft, .horizontal), isVideo: false)
        #expect(insets.top == 76 && insets.side == 60)
    }

    @Test func rowInTheOtherTopCornerStillPushesTheBadgeDown() {
        // A long top-right row reaches across to where Keep sits.
        let insets = IntentStamp.cardInsets(for: SwipeIntent(action: .keep, edge: .trailing), layout: layout(.topRight, .horizontal), isVideo: false)
        #expect(insets.top == 76 && insets.side == 60)
    }

    @Test func columnInTheOtherCornerLeavesTheBadgeAlone() {
        let insets = IntentStamp.cardInsets(for: SwipeIntent(action: .keep, edge: .trailing), layout: layout(.topRight, .vertical), isVideo: false)
        #expect(insets.top == 60 && insets.side == 60)
    }

    @Test func undoOnlyMovesForARowAlongTheTop() {
        #expect(IntentStamp.cardInsets(for: SwipeIntent(action: .undo, edge: .bottom), layout: layout(.topRight, .vertical), isVideo: false).top == 60)
        #expect(IntentStamp.cardInsets(for: SwipeIntent(action: .undo, edge: .bottom), layout: layout(.topRight, .horizontal), isVideo: false).top == 76)
    }
}

/// Which tile of the strip a card dragged down is over, and how the strip scrolls for it (Android's `AlbumDropStateTest`).
@MainActor
struct DropStripStateTests {
    private func state() -> DropStripState {
        let state = DropStripState()
        state.tileFrames["a"] = CGRect(x: 0, y: 1000, width: 100, height: 100)
        state.tileFrames["b"] = CGRect(x: 120, y: 1000, width: 100, height: 100)
        return state
    }

    @Test func aFingerAboveTheStripIsOverNothing() {
        let state = state()
        state.move(to: CGPoint(x: 160, y: 400))
        #expect(state.hoveredID == nil)
    }

    @Test func aFingerInTheStripIsOverTheNearestTile() {
        let state = state()
        state.move(to: CGPoint(x: 180, y: 1050))
        #expect(state.hoveredID == "b")
    }

    @Test func aFingerJustAboveTheStripAlreadyPicksATile() {
        let state = state()
        state.move(to: CGPoint(x: 30, y: 950))
        #expect(state.hoveredID == "a")
    }

    @Test func aFingerMidwayBetweenTwoTilesPicksTheLeftOne() {
        let state = state()
        state.move(to: CGPoint(x: 110, y: 1050))
        #expect(state.hoveredID == "a")
    }

    @Test func aStripWithNoTilesYetIsOverNothing() {
        let state = DropStripState()
        state.move(to: CGPoint(x: 100, y: 1050))
        #expect(state.isActive && state.hoveredID == nil)
    }

    @Test func endingTheDragClearsTheHover() {
        let state = state()
        state.move(to: CGPoint(x: 30, y: 1050))
        #expect(state.hoveredID == "a")
        state.end()
        #expect(!state.isActive)
        #expect(state.hoveredID == nil)
    }

    /// Where a point of the card ends up on screen: shrunk and moved as the card is, then turned about its middle.
    private func screenPoint(of point: CGPoint, scale: CGFloat, offset: CGSize, angle: Double) -> CGPoint {
        let (x, y) = (scale * point.x + offset.width, scale * point.y + offset.height)
        return CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }

    @Test func theShrunkenCardStaysUnderTheFingerWhateverTheDragAndLean() {
        let anchor = CGPoint(x: 70, y: -120)
        for (drag, degrees) in [(CGSize(width: 0, height: 60), 0.0), (CGSize(width: 35, height: 140), 1.4), (CGSize(width: -90, height: 300), -3.6)] {
            let angle = degrees * .pi / 180
            let shift = DropStripState.thumbnailShift(anchor: anchor, drag: drag, angle: angle, scale: 0.4)
            let shown = screenPoint(of: anchor, scale: 0.4, offset: CGSize(width: drag.width + shift.width, height: drag.height + shift.height), angle: angle)
            // The finger is where it took hold of the card, moved by the drag.
            #expect(abs(shown.x - (anchor.x + drag.width)) < 0.001 && abs(shown.y - (anchor.y + drag.height)) < 0.001)
        }
    }

    @Test func withoutALeanTheShrunkenCardIsMovedByTheGapItLeavesAtTheGrabbedPoint() {
        let shift = DropStripState.thumbnailShift(anchor: CGPoint(x: 50, y: -100), drag: CGSize(width: 10, height: 80), angle: 0, scale: 0.4)
        #expect(abs(shift.width - 30) < 0.001 && abs(shift.height - -60) < 0.001)
    }

    private let row = CGRect(x: 0, y: 1000, width: 400, height: 120)

    @Test func theStripScrollsTowardsAnEdgeTheFingerNears_FasterTheCloser() {
        func direction(_ x: CGFloat) -> CGFloat { DropStripState.autoScrollDirection(pointer: CGPoint(x: x, y: 1050), bounds: row, edge: 64) }
        #expect(direction(-20) == -1)
        #expect(direction(32) == -0.5)
        #expect(direction(368) == 0.5)
        #expect(direction(400) == 1)
    }

    @Test func theStripStaysPutMidRowOverMoreAndWhileTheFingerIsFarAbove() {
        func direction(_ x: CGFloat, _ y: CGFloat) -> CGFloat { DropStripState.autoScrollDirection(pointer: CGPoint(x: x, y: y), bounds: row, edge: 64) }
        #expect(direction(200, 1050) == 0)
        #expect(direction(450, 1050) == 0)
        #expect(direction(10, 300) == 0)
    }
}
