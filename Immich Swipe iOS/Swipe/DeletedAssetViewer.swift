import AVFoundation
import SwiftUI

/// A photo or video marked for deletion, full screen, with a button to take the decision back, as on
/// Android (`SummaryFullscreenPreviewDialog`).
///
/// Swipe sideways for the next or previous one and down to close. Pinch or double-tap to zoom. Restoring
/// moves on to the next one, and closes after the last.
///
/// Android's distances are pixels; they are divided by 2.5 here, as in the other viewers.
struct DeletedAssetViewer: View {
    let model: DeckModel

    @Environment(\.dismiss) private var dismiss
    @State private var videoPlayer = DeckVideoPlayer()
    @State private var index: Int
    @State private var isZoomed = false
    @State private var dragAxis: Axis?
    /// How far the page has been pulled down to close.
    @State private var dismissOffset: CGFloat = 0
    @State private var isClosing = false
    /// How far the pages have been dragged sideways. The neighbours sit one screen width either side.
    @State private var pageOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    @State private var isPaging = false

    /// 100 px: a sideways swipe past this changes the asset.
    private static let swipeDistance: CGFloat = 40
    /// 150 px: a pull down past this closes.
    private static let closeDistance: CGFloat = 60
    /// 600 px: the backdrop is gone once pulled this far.
    private static let fadeDistance: CGFloat = 240

    init(model: DeckModel, startingAt assetID: String) {
        self.model = model
        let assets = model.decidedAssets()[.delete] ?? []
        _index = State(initialValue: assets.firstIndex { $0.id == assetID } ?? 0)
    }

    /// Read live, so a restored asset drops out of the pager.
    private var assets: [Asset] { model.decidedAssets()[.delete] ?? [] }

    var body: some View {
        let assets = assets
        let current = assets.indices.contains(index) ? assets[index] : assets.first
        ZStack {
            // Opaque at rest, so the review sheet never shows through; it only appears while pulling down to close.
            Color.black
                .opacity(min(max(1 - dismissOffset / Self.fadeDistance, 0), 1))
                .ignoresSafeArea()

            if let current {
                // The previous and next pictures wait either side, so a swipe slides one in as the other leaves.
                // Each keeps its place in the list as it moves to the middle, so nothing reloads.
                ZStack {
                    ForEach(window(of: assets), id: \.asset.id) { slot, asset in
                        DeletedAssetMedia(
                            asset: asset,
                            client: model.client,
                            videoPlayer: videoPlayer,
                            isCurrent: slot == 0,
                            isZoomed: $isZoomed,
                            onDrag: handle
                        )
                        .offset(x: CGFloat(slot) * pageWidth + pageOffset)
                        .allowsHitTesting(slot == 0)
                        .accessibilityHidden(slot != 0)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
                .ignoresSafeArea()
                .offset(y: dismissOffset)

                VStack {
                    topBar(current, count: assets.count)
                    Spacer(minLength: 0)
                    restoreButton(current, count: assets.count)
                }
                // The controls fade away as the picture is pulled down.
                .opacity(min(max(1 - dismissOffset / Self.closeDistance, 0), 1))
            }
        }
        .environment(\.colorScheme, .dark)
        .presentationBackground(.clear)
        .task(id: current?.id) {
            isZoomed = false
            if let current, current.type == .video {
                videoPlayer.play(current, using: model.client)
            } else {
                videoPlayer.stop()
            }
        }
        .onDisappear { videoPlayer.stop() }
        .onChange(of: assets.isEmpty) { _, isEmpty in if isEmpty { dismiss() } }
    }

    // MARK: Controls

    /// The size and position in glass pills on the left, and Close on the right.
    private func topBar(_ asset: Asset, count: Int) -> some View {
        HStack(spacing: 8) {
            if let size = asset.fileSize {
                Text(size, format: .byteCount(style: .file))
                    .pill()
            }
            if count > 1 {
                Text(verbatim: "\(index + 1) / \(count)")
                    .pill()
            }
            Spacer()
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func restoreButton(_ asset: Asset, count: Int) -> some View {
        Button {
            restore(asset, count: count)
        } label: {
            Label("Restore Asset", systemImage: "arrow.uturn.backward")
                .font(.headline)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(model.isApplying)
        .padding(.bottom, 24)
    }

    /// Takes the decision back and shows the one that moves into its place, or the last one when this was
    /// the last; the viewer closes when none are left.
    private func restore(_ asset: Asset, count: Int) {
        model.removeDecision(for: asset.id)
        if count <= 1 {
            dismiss()
        } else {
            index = min(index, count - 2)
        }
    }

    // MARK: Gestures

    /// The pictures on screen: the current one (slot 0) and its neighbours (-1 and 1), where there are any.
    private func window(of assets: [Asset]) -> [(slot: Int, asset: Asset)] {
        (-1...1).compactMap { slot in
            assets.indices.contains(index + slot) ? (slot, assets[index + slot]) : nil
        }
    }

    private func handle(_ drag: ViewerDrag) {
        guard !isClosing, !isPaging else { return }
        switch drag {
        case .changed(let translation):
            if dragAxis == nil {
                if abs(translation.width) > abs(translation.height) {
                    dragAxis = .horizontal
                } else if translation.height > 0 {
                    dragAxis = .vertical
                }
            }
            switch dragAxis {
            case .horizontal:
                // Past the first or last picture the page resists, as a scroll view does at its end.
                let hasPage = translation.width < 0 ? index < assets.count - 1 : index > 0
                pageOffset = hasPage ? translation.width : translation.width / 3
            case .vertical:
                dismissOffset = max(translation.height, 0)
            case nil:
                break
            }
        case .ended(let translation):
            let axis = dragAxis
            dragAxis = nil
            if axis == .vertical {
                if dismissOffset > Self.closeDistance {
                    close()
                } else {
                    withAnimation(.bouncy) { dismissOffset = 0 }
                }
            } else if axis == .horizontal {
                if translation.width < -Self.swipeDistance, index < assets.count - 1 {
                    step(1)
                } else if translation.width > Self.swipeDistance, index > 0 {
                    step(-1)
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.25)) { pageOffset = 0 }
                }
            }
        case .cancelled:
            dragAxis = nil
            withAnimation(.smooth) {
                dismissOffset = 0
                pageOffset = 0
            }
        }
    }

    /// Slides the next or previous picture in from where the finger left it. Once it is in the middle the
    /// index moves on and the offset resets with no animation, which looks like nothing happening.
    private func step(_ direction: Int) {
        guard assets.indices.contains(index + direction) else {
            withAnimation(.smooth) { pageOffset = 0 }
            return
        }
        isPaging = true
        withAnimation(.smooth(duration: 0.28)) {
            pageOffset = CGFloat(-direction) * pageWidth
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                index += direction
                pageOffset = 0
            }
            isPaging = false
        }
    }

    /// Carries the pull on in one motion, as in the other viewers: the picture keeps sliding down and the
    /// backdrop fades out, and only then is the cover removed, without its own slide.
    private func close() {
        isClosing = true
        withAnimation(.easeOut(duration: 0.22)) {
            dismissOffset = 1000
        }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

private extension View {
    func pill() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }
}

/// The picture or video, fitted, with zoom. Photos show the preview, and GIFs the original so they move.
/// A tap plays or pauses a video.
private struct DeletedAssetMedia: View {
    let asset: Asset
    let client: ImmichClient
    let videoPlayer: DeckVideoPlayer
    /// A neighbour waiting beside the current one is only a picture: no touches, no video, no original.
    let isCurrent: Bool
    @Binding var isZoomed: Bool
    let onDrag: (ViewerDrag) -> Void

    @State private var aspectRatio: CGFloat?
    @State private var mediaFrame: CGRect?

    private var isVideo: Bool { asset.type == .video }
    private var player: AVPlayer? { isCurrent && videoPlayer.assetID == asset.id ? videoPlayer.player : nil }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let frame = mediaFrame ?? CGRect(origin: .zero, size: geometry.size)
                ZStack {
                    RemoteImage(
                        request: client.authorizedRequest(for: isCurrent && asset.isGIF ? .original(assetID: asset.id) : .preview(assetID: asset.id)),
                        animates: isCurrent && asset.isGIF
                    ) { size in
                        guard size.width > 0, size.height > 0 else { return }
                        aspectRatio = size.width / size.height
                    }
                    if let player {
                        PlayerSurface(player: player)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }
            .allowsHitTesting(false)
            .overlay {
                if isCurrent, isVideo, videoPlayer.hasFailed {
                    ContentUnavailableView("Error playing video", systemImage: "video.slash")
                        .background(.black.opacity(0.6))
                }
            }

            if isCurrent {
                ZoomSurface(
                    aspectRatio: aspectRatio,
                    mediaFrame: $mediaFrame,
                    isZoomed: $isZoomed,
                    onTap: { _, _ in false },
                    onConfirmedTap: {
                        guard isVideo, videoPlayer.assetID == asset.id else { return }
                        videoPlayer.togglePlayPause()
                    },
                    onHold: { _ in },
                    onDrag: onDrag
                )
                .accessibilityElement()
                .accessibilityLabel(isVideo ? "Video" : "Photo")
            }
        }
    }
}
