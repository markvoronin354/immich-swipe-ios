import AVFoundation
import Observation

/// Plays a Live Photo's clip once, muted, when the LIVE pill is tapped. The card draws it over the
/// still, which shows again when the clip ends. Separate from `DeckVideoPlayer`, which loops and has controls.
@Observable
final class LivePhotoPlayer {
    let player = AVPlayer()
    /// The photo whose clip is loaded, or nil when nothing is playing.
    private(set) var assetID: String?

    @ObservationIgnored private var endTask: Task<Void, Never>?

    init() { player.isMuted = true }

    /// Plays the photo's clip, or stops it while it plays, like Android's pill.
    func toggle(_ asset: Asset, using client: ImmichClient) {
        if assetID == asset.id { stop() } else { play(asset, using: client) }
    }

    private func play(_ asset: Asset, using client: ImmichClient) {
        guard let clipID = asset.livePhotoVideoId else { return }
        stop()
        let urlAsset = AVURLAsset(
            url: client.url(for: .videoPlayback(assetID: clipID)),
            options: ["AVURLAssetHTTPHeaderFieldsKey": client.authorizationHeaders]
        )
        let item = AVPlayerItem(asset: urlAsset)
        player.replaceCurrentItem(with: item)
        assetID = asset.id
        player.play()
        // Back to the still when the clip ends or can't be played.
        endTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
                    group.addTask { for await _ in NotificationCenter.default.notifications(named: name, object: item) { return } }
                }
                await group.next()
                group.cancelAll()
            }
            self?.finish(asset.id)
        }
    }

    func stop() {
        endTask?.cancel()
        endTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        assetID = nil
    }

    private func finish(_ id: String) {
        if assetID == id { stop() }
    }
}
