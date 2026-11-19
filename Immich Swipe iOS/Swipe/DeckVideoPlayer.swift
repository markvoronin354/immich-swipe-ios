import AVFoundation
import Observation

/// Plays the current video card on a loop. One player is shared by the whole deck, and the mute
/// choice carries from one video to the next, as on Android.
@Observable
final class DeckVideoPlayer {
    let player = AVQueuePlayer()
    /// The asset whose video is loaded, or nil when nothing is playing.
    private(set) var assetID: String?
    private(set) var isMuted = false
    /// Playback state for the fullscreen controls, polled like Android's 500 ms loop (`SharedVideoPlayer`).
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// True while playing or waiting to play, so Pause shows while the video buffers.
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var hasFailed = false

    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Seeks started but not yet finished; while any are, the polled time is stale.
    @ObservationIgnored private var pendingSeeks = 0
    #if DEBUG
    // TEMPORARY: buffering diagnostics, see VideoDiagnostics.swift. Debug builds only, so a release build
    // doesn't send its extra request for every video or log four times a second.
    @ObservationIgnored private let diagnostics = VideoDiagnostics()
    #endif

    /// The asset for a video, signed with the account's API key.
    ///
    /// Immich needs the `x-api-key` header on video requests, and a plain URL can't carry it. The
    /// header option below is not in Apple's documentation (only the user-agent option is), but it
    /// has long been honoured by AVFoundation and is what apps use for authenticated streams.
    static func makeAsset(for asset: Asset, using client: ImmichClient) -> AVURLAsset {
        AVURLAsset(
            url: client.url(for: .videoPlayback(assetID: asset.id)),
            options: ["AVURLAssetHTTPHeaderFieldsKey": client.authorizationHeaders]
        )
    }

    func play(_ asset: Asset, using client: ImmichClient) {
        if assetID == asset.id {
            player.play()
            isPlaying = true
            return
        }
        stop()
        let urlAsset = Self.makeAsset(for: asset, using: client)
        let item = AVPlayerItem(asset: urlAsset)
        #if DEBUG
        let looperStart = Date()
        #endif
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        #if DEBUG
        diagnostics.start(
            asset: asset,
            urlAsset: urlAsset,
            looper: looper,
            looperInitSeconds: Date().timeIntervalSince(looperStart),
            headers: client.authorizationHeaders
        )
        #endif
        player.isMuted = isMuted
        assetID = asset.id
        Self.activateAudioSession()
        player.play()
        // Set now rather than at the first poll, so the fullscreen Paused badge doesn't flash.
        isPlaying = true
        startPolling()
    }

    func stop() {
        #if DEBUG
        diagnostics.stop()
        #endif
        pollTask?.cancel()
        pollTask = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        assetID = nil
        pendingSeeks = 0
        currentTime = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        hasFailed = false
    }

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.timeControlStatus != .paused
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func resume() {
        player.play()
        isPlaying = true
    }

    /// Jumps to a point in the video, exactly, so the picture follows the seek bar.
    func seek(to seconds: Double) {
        currentTime = seconds
        // Until the seek lands the player still reports the old position, so the poll must not write it
        // back: that made the seek bar thumb jump to its old place when released.
        pendingSeeks += 1
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pendingSeeks = max((self?.pendingSeeks ?? 1) - 1, 0) }
        }
    }

    /// Reads the player's state four times a second. Only changed values are written, so views that
    /// watch the player aren't redrawn for nothing.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func poll() {
        #if DEBUG
        diagnostics.poll(player)
        #endif
        let item = player.currentItem
        let time = player.currentTime().seconds
        let length = item?.duration.seconds ?? 0
        let playing = player.timeControlStatus != .paused
        let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let failed = item?.status == .failed || looper?.status == .failed
        if pendingSeeks == 0, time.isFinite, time != currentTime { currentTime = time }
        if length.isFinite, length != duration { duration = length }
        if playing != isPlaying { isPlaying = playing }
        if buffering != isBuffering { isBuffering = buffering }
        if failed != hasFailed {
            hasFailed = failed
            if failed {
                let error = item?.error ?? looper?.error
                AppLog.e("VideoPlayer", "Playback error for asset=\(assetID ?? "?"): \(error?.localizedDescription ?? "unknown")", error)
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// Playback category, so the video's sound plays even with the silent switch on. Other audio pauses,
    /// matching the Android default ("Pause others"), unless "Play over others" is chosen: then it mixes.
    ///
    /// The category is set when it changes, and the session is switched on, off the main thread:
    /// AVAudioSession can block for a while, which would freeze the swipe screen when a video card comes up.
    private static func activateAudioSession() {
        #if !os(macOS)
        let behavior = UserDefaults.standard.string(forKey: Setting.Key.playbackBehavior).flatMap(PlaybackBehavior.init(rawValue:)) ?? Setting.Default.playbackBehavior
        let options: AVAudioSession.CategoryOptions = behavior == .playOverOthers ? [.mixWithOthers] : []
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || session.categoryOptions != options {
                try? session.setCategory(.playback, mode: .moviePlayback, options: options)
            }
            try? session.setActive(true)
        }
        #endif
    }
}
