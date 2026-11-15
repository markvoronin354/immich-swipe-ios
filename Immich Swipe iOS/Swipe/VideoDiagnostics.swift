import AVFoundation
import os

// TEMPORARY: diagnostics for slow video buffering. Delete this file and the `diagnostics` lines in
// DeckVideoPlayer once the cause is known. Every line starts with "[VideoDiag]".

/// Logs what the deck's video player is doing: what the server sends, how many copies of the video the
/// looper downloads, how long playback takes to start, how much is buffered, and every stall.
final class VideoDiagnostics {
    private let logger = Logger(subsystem: "ImmichSwipe", category: "VideoDiag")
    private var assetTag = ""
    private var startedAt = Date()
    private var firstPlayLogged = false
    private var lastStatus: AVPlayer.TimeControlStatus?
    private var lastReason: AVPlayer.WaitingReason?
    private var lastItem: AVPlayerItem?
    private var lastHeartbeat = Date.distantPast
    private var items: [AVPlayerItem] = []
    private var accessLogs: [ObjectIdentifier: AVPlayerItemAccessLog] = [:]
    private var observers: [NSObjectProtocol] = []
    private var probeTask: Task<Void, Never>?

    private func log(_ message: String) {
        let elapsed = Date().timeIntervalSince(startedAt)
        logger.notice("[VideoDiag] \(self.assetTag, privacy: .public) +\(String(format: "%.2f", elapsed), privacy: .public)s \(message, privacy: .public)")
    }

    /// Called right after the looper is made, with how long making it took.
    func start(asset: Asset, urlAsset: AVURLAsset, looper: AVPlayerLooper, looperInitSeconds: Double, headers: [String: String]) {
        stop()
        startedAt = Date().addingTimeInterval(-looperInitSeconds)
        assetTag = String(asset.id.prefix(8))
        firstPlayLogged = false
        lastStatus = nil
        lastReason = nil
        lastItem = nil

        let originalSize = asset.fileSize.map { $0.formatted(.byteCount(style: .file)) } ?? "?"
        let length = asset.durationMilliseconds.map { String(format: "%.0fs", Double($0) / 1000) } ?? "?"
        log("START \(asset.originalFileName ?? "?") original=\(originalSize) length=\(length) url=\(urlAsset.url.path())")
        log("looper init took \(String(format: "%.3f", looperInitSeconds))s on main thread, replicas=\(looper.loopingPlayerItems.count)")

        items = looper.loopingPlayerItems
        for (index, item) in items.enumerated() {
            observe(item, index: index)
        }

        let url = urlAsset.url
        probeTask = Task { [weak self] in
            await self?.probeServer(url: url, headers: headers)
            await self?.probeTracks(urlAsset)
        }
    }

    func stop() {
        guard !assetTag.isEmpty else { return }
        for (index, item) in items.enumerated() {
            log("STOP replica \(index): \(summary(of: item))")
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        items = []
        accessLogs = [:]
        probeTask?.cancel()
        probeTask = nil
        assetTag = ""
    }

    /// Called from the player's poll, four times a second.
    func poll(_ player: AVQueuePlayer) {
        guard !assetTag.isEmpty else { return }
        let status = player.timeControlStatus
        let reason = player.reasonForWaitingToPlay
        let item = player.currentItem

        if status != lastStatus || reason != lastReason {
            log("status=\(Self.name(status)) reason=\(reason?.rawValue ?? "-") \(buffer(of: item, player: player))")
            lastStatus = status
            lastReason = reason
        }
        if status == .playing, !firstPlayLogged {
            firstPlayLogged = true
            log("FIRST PLAY after \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        }
        if item !== lastItem {
            log("current item -> replica \(index(of: item))")
            lastItem = item
        }
        if Date().timeIntervalSince(lastHeartbeat) >= 2 {
            lastHeartbeat = Date()
            let others = items.enumerated()
                .filter { $0.element !== item }
                .map { "r\($0.offset): \(Self.bufferedSeconds($0.element))s buffered, \(bytes($0.element))" }
                .joined(separator: " | ")
            log("tick \(Self.name(status)) t=\(String(format: "%.1f", player.currentTime().seconds)) \(buffer(of: item, player: player)) | other replicas: \(others)")
        }
    }

    // MARK: Observers

    private func observe(_ item: AVPlayerItem, index: Int) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.newAccessLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task { await self?.logAccess(of: item, index: index) }
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("STALL r\(index) \(Self.bufferedSeconds(item))s buffered")
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task {
                    guard let event = await item.errorLog?.events.last else { return }
                    self?.log("ERROR r\(index): \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "")")
                }
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.log("FAILED r\(index): \(error.map { String(describing: $0) } ?? "?")")
            }
        })
    }

    /// Fetches the item's access log, keeps it for the synchronous summaries, and logs its newest entry.
    private func logAccess(of item: AVPlayerItem, index: Int) async {
        guard let accessLog = await item.accessLog else { return }
        accessLogs[ObjectIdentifier(item)] = accessLog
        guard let event = accessLog.events.last else { return }
        log("ACCESS r\(index): uri=\(event.uri ?? "?") indicated=\(Self.mbps(event.indicatedBitrate)) observed=\(Self.mbps(event.observedBitrate)) bytes=\(Int64(event.numberOfBytesTransferred).formatted(.byteCount(style: .file))) transfer=\(String(format: "%.1f", event.transferDuration))s startup=\(String(format: "%.2f", event.startupTime))s stalls=\(event.numberOfStalls) server=\(event.serverAddress ?? "?")")
    }

    // MARK: Probes

    /// Asks for two bytes, to learn what the server sends for playback without downloading it.
    private func probeServer(url: URL, headers: [String: String]) async {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let begin = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request, delegate: APIKeyRedirectGuard.shared)
            guard let http = response as? HTTPURLResponse else { return }
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? "-"
            let total = range.split(separator: "/").last.flatMap { Int64($0) }
            log("SERVER status=\(http.statusCode) type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "-") range=\(range) servedSize=\(total.map { $0.formatted(.byteCount(style: .file)) } ?? "?") acceptRanges=\(http.value(forHTTPHeaderField: "Accept-Ranges") ?? "-") roundTrip=\(String(format: "%.2f", Date().timeIntervalSince(begin)))s")
        } catch {
            log("SERVER probe failed: \(error.localizedDescription)")
        }
    }

    /// Codec, size and data rate of what is being played.
    private func probeTracks(_ asset: AVURLAsset) async {
        let begin = Date()
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            var description = "metadata loaded in \(String(format: "%.2f", Date().timeIntervalSince(begin)))s duration=\(String(format: "%.0f", duration.seconds))s"
            if let track = tracks.first {
                let (rate, size, formats) = try await track.load(.estimatedDataRate, .naturalSize, .formatDescriptions)
                let codec = formats.first.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
                description += " video=\(codec) \(Int(size.width))x\(Int(size.height)) dataRate=\(Self.mbps(Double(rate)))"
            }
            log(description)
        } catch {
            log("metadata load failed: \(error.localizedDescription)")
        }
    }

    // MARK: Formatting

    private func buffer(of item: AVPlayerItem?, player: AVPlayer) -> String {
        guard let item else { return "no item" }
        let now = player.currentTime().seconds
        let ahead = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .first { $0.start.seconds <= now + 0.5 && $0.end.seconds >= now }
            .map { $0.end.seconds - now } ?? 0
        return "replica=\(index(of: item)) ahead=\(String(format: "%.1f", ahead))s likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) bufferEmpty=\(item.isPlaybackBufferEmpty) \(bytes(item))"
    }

    private func index(of item: AVPlayerItem?) -> String {
        guard let item else { return "none" }
        return items.firstIndex { $0 === item }.map(String.init) ?? "?"
    }

    private func summary(of item: AVPlayerItem) -> String {
        guard let event = accessLogs[ObjectIdentifier(item)]?.events.last else { return "no access log, \(Self.bufferedSeconds(item))s buffered" }
        return "bytes=\(Int64(event.numberOfBytesTransferred).formatted(.byteCount(style: .file))) observed=\(Self.mbps(event.observedBitrate)) stalls=\(event.numberOfStalls) watched=\(String(format: "%.1f", event.durationWatched))s"
    }

    private func bytes(_ item: AVPlayerItem) -> String {
        let total = accessLogs[ObjectIdentifier(item)]?.events.reduce(Int64(0)) { $0 + $1.numberOfBytesTransferred } ?? 0
        return "downloaded=\(total.formatted(.byteCount(style: .file)))"
    }

    private static func bufferedSeconds(_ item: AVPlayerItem) -> String {
        let total = item.loadedTimeRanges.map(\.timeRangeValue).reduce(0) { $0 + $1.duration.seconds }
        return String(format: "%.1f", total)
    }

    private static func mbps(_ bitsPerSecond: Double) -> String {
        bitsPerSecond > 0 ? String(format: "%.1fMbps", bitsPerSecond / 1_000_000) : "?"
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    private static func name(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown"
        }
    }
}
