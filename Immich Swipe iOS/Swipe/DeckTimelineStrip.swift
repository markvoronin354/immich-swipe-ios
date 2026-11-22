import SwiftUI

/// The row of thumbnails above the card, centred on the current photo. Decided photos carry a
/// badge for their decision; tapping any thumbnail shows that photo.
struct DeckTimelineStrip: View {
    let model: DeckModel

    @State private var hasPositioned = false

    var body: some View {
        let currentID = model.deck.current?.id
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(model.deck.assets) { asset in
                        TimelineThumb(
                            request: model.thumbnailRequest(for: asset),
                            revision: model.imageRevision,
                            videoFallback: asset.type == .video ? model.client.authorizedRequest(for: .videoPlayback(assetID: asset.id)) : nil,
                            decision: model.deck.decision(for: asset.id),
                            isCurrent: asset.id == currentID,
                            isVideo: asset.type == .video,
                            isGIF: asset.isGIF,
                            isLivePhoto: asset.isLivePhoto,
                            isFavorite: model.isFavorite(asset),
                            isArchived: asset.isArchived,
                            isLocked: asset.isLocked,
                            rotation: model.rotation(of: asset)
                        )
                        .onTapGesture { model.move(toAssetID: asset.id) }
                        .id(asset.id)
                    }
                }
                .padding(.vertical, 6)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .frame(height: 76)
            .onChange(of: currentID, initial: true) { _, id in
                guard let id else { return }
                // The first scroll, when the strip appears, jumps straight to the photo instead of
                // sweeping there from the start of the row.
                var transaction = Transaction(animation: .snappy)
                transaction.disablesAnimations = !hasPositioned
                withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
                hasPositioned = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo strip")
    }
}

private struct TimelineThumb: View {
    let request: URLRequest
    let revision: Int
    let videoFallback: URLRequest?
    let decision: SwipeDecision?
    let isCurrent: Bool
    let isVideo: Bool
    let isGIF: Bool
    let isLivePhoto: Bool
    let isFavorite: Bool
    let isArchived: Bool
    let isLocked: Bool
    let rotation: Int

    var body: some View {
        // Already archived or locked on the server, without a matching decision this session.
        let showArchive = isArchived && decision != .archive
        let showLock = isLocked && decision != .lock
        RemoteThumbnail(request: request, size: 58, revision: revision, videoFallback: videoFallback, rotation: rotation)
            .overlay(alignment: .bottomLeading) {
                if isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                } else if isGIF {
                    Text("GIF")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                } else if isLivePhoto {
                    Image(systemName: "livephoto")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(4)
                }
            }
            .padding(3)
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.blue, lineWidth: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let decision {
                    DecisionBadge(decision: decision)
                        .offset(x: 4, y: -4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showArchive || showLock {
                    HStack(spacing: 2) {
                        if showArchive { StatusBadge(symbol: "archivebox") }
                        if showLock { StatusBadge(symbol: "lock") }
                    }
                    .offset(x: 4, y: 4)
                }
            }
    }
}

/// Grey badge for a photo that is already archived or locked on the server, as on the Android strip.
private struct StatusBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.primary)
            .frame(width: 20, height: 20)
            .background(.regularMaterial, in: .circle)
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
    }
}

/// Small coloured badge for a decision, as on the Android strip.
struct DecisionBadge: View {
    let decision: SwipeDecision

    var body: some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color, in: .circle)
            // A ring in the screen's background colour, so the badge looks cut out of the thumbnail.
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
    }

    private var symbol: String {
        switch decision {
        case .keep: "checkmark"
        case .delete: "trash"
        case .archive: "archivebox"
        case .lock: "lock"
        }
    }

    private var color: Color {
        switch decision {
        case .keep: .green
        case .delete: .red
        case .archive: .blue
        case .lock: .gray
        }
    }
}
