import SwiftUI

/// A square, authenticated Immich thumbnail with a placeholder while it loads or if it fails.
struct RemoteThumbnail: View {
    let request: URLRequest?
    var size: CGFloat = 56
    /// Defaults to a proportion of the size. Set it to match a clip drawn around the thumbnail.
    var cornerRadius: CGFloat?

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private var radius: CGFloat { cornerRadius ?? size * 0.18 }

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
            .task(id: request?.url) {
                image = nil
                guard let request else { return }
                // The limit applies to the longest side, so allow 2× to keep the short side sharp when filled.
                image = try? await ThumbnailLoader.shared.image(for: request, maxPixelSize: Int(size * displayScale * 2))
            }
    }
}
