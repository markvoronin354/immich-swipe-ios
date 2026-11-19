import SwiftUI

/// A square, authenticated Immich thumbnail with a placeholder while it loads or if it fails.
struct RemoteThumbnail: View {
    let request: URLRequest?
    var size: CGFloat = 56
    /// Defaults to a proportion of the size. Set it to match a clip drawn around the thumbnail.
    var cornerRadius: CGFloat?
    /// Changing it reloads the image even though the request is the same.
    var revision = 0
    /// For a video: where to take a frame from when the server has no thumbnail.
    var videoFallback: URLRequest?

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private var radius: CGFloat { cornerRadius ?? size * 0.18 }

    private struct ReloadKey: Equatable {
        let url: URL?
        let revision: Int
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: radius))
            .task(id: ReloadKey(url: request?.url, revision: revision)) {
                image = nil
                guard let request else { return }
                // The limit applies to the longest side, so allow 2× to keep the short side sharp when filled.
                let maxPixelSize = Int(size * displayScale * 2)
                image = try? await ThumbnailLoader.shared.image(for: request, maxPixelSize: maxPixelSize)
                if image == nil, let videoFallback {
                    image = try? await ThumbnailLoader.shared.videoFrame(for: videoFallback, maxPixelSize: maxPixelSize)
                }
            }
    }
}
