import SwiftUI

/// A full-size authenticated Immich image, fitted inside its frame, with a spinner while it loads.
struct RemoteImage: View {
    let request: URLRequest
    /// Longest side to decode to, in pixels. The server's preview size is 1440.
    var maxPixelSize = 1440
    /// For an image drawn over another: no spinner while it loads and nothing if it fails, so the image
    /// underneath stays visible.
    var isOverlay = false
    /// Set while the image is downloading, so the screen can show progress somewhere other than the image.
    var isLoading: Binding<Bool>?
    /// Plays the image if it's animated, as the Android app's GIF decoder does. Its first frame shows until the
    /// file is in; a still image is unaffected. The animation runs until the view goes away.
    var animates = false
    /// Told the image's pixel size once it has loaded, for views that lay out around the picture.
    var onLoad: ((CGSize) -> Void)?

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        // A cached image is drawn on the first frame; waiting for the task would flash the spinner.
        let shown = image ?? ThumbnailLoader.shared.cachedImage(for: request, maxPixelSize: maxPixelSize)
        ZStack {
            if let shown {
                Image(decorative: shown, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                if !isOverlay { ContentUnavailableView("Couldn't load this photo", systemImage: "exclamationmark.triangle") }
            } else if !isOverlay {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request.url) {
            image = nil
            failed = false
            isLoading?.wrappedValue = true
            defer { if !Task.isCancelled { isLoading?.wrappedValue = false } }
            do {
                let loaded = try await ThumbnailLoader.shared.image(for: request, maxPixelSize: maxPixelSize)
                image = loaded
                onLoad?(CGSize(width: loaded.width, height: loaded.height))
            } catch is CancellationError {
                // The card went away before the image arrived.
            } catch {
                failed = true
            }
            if animates, !failed, let data = try? await ThumbnailLoader.shared.animationData(for: request) {
                await play(data)
            }
        }
        .onDisappear { isLoading?.wrappedValue = false }
    }

    /// Shows each frame as ImageIO hands it over, at the file's own timing, until this view's task is cancelled.
    private func play(_ data: Data) async {
        let stop = AnimationStop()
        // ImageIO calls this on the main queue, one decoded frame at a time.
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { _, frame, shouldStop in
            if stop.isRequested {
                shouldStop.pointee = true
            } else {
                MainActor.assumeIsolated { image = frame }
            }
        }
        guard status == noErr else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        stop.isRequested = true
    }
}

/// Tells a running animation to stop at its next frame. Only touched on the main thread: by the task that
/// started the animation, and by ImageIO's frame block, which runs on the main queue.
private nonisolated final class AnimationStop: @unchecked Sendable {
    var isRequested = false
}

extension ThumbnailLoader {
    /// Starts downloading images the user is about to see, so the next card appears instantly.
    func prefetch(_ requests: [URLRequest], maxPixelSize: Int) {
        for request in requests {
            Task { _ = try? await image(for: request, maxPixelSize: maxPixelSize) }
        }
    }
}
