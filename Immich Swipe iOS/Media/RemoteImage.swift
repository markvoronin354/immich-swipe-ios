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
        }
        .onDisappear { isLoading?.wrappedValue = false }
    }
}

extension ThumbnailLoader {
    /// Starts downloading images the user is about to see, so the next card appears instantly.
    func prefetch(_ requests: [URLRequest], maxPixelSize: Int) {
        for request in requests {
            Task { _ = try? await image(for: request, maxPixelSize: maxPixelSize) }
        }
    }
}
