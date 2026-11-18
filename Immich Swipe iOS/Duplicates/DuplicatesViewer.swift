import AVFoundation
import SwiftUI

/// Fullscreen comparison of a duplicate group, as on Android (`FullScreenPreviewModal.kt`).
///
/// The Delete and Keep buttons are the only way to change the choice; pressing the active one clears it.
/// Tapping the picture does nothing. Swipe sideways for the next asset; past the first or last one the
/// swipe moves to the neighbouring group. Swipe down to close. Pinch or double-tap to zoom.
///
/// Laid out like Android: the picture only has the room between the top bar and the bottom panel, and
/// nothing overlaps it. The bars use glass controls. At the top, Close, the file name and size, Favorite and Info; at the bottom,
/// the group's position, a strip of its assets, and the group arrows either side of the choice. A video's
/// own controls sit over its bottom edge, as on Android.
///
/// Android's distances are pixels; they are divided by 2.5 here, as in the swipe viewer.
struct DuplicatesViewer: View {
    let model: DuplicatesModel
    @Binding var activeClusterIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var videoPlayer = DeckVideoPlayer()
    @State private var clusterIndex: Int
    @State private var selectedIndex: Int
    @State private var isZoomed = false
    /// The zoom carries from one photo to the next, and from one video to the next, as on Android, so
    /// duplicates can be compared at the same spot. Android keeps one zoom for photos and one for videos,
    /// and loses each when the other kind is shown.
    @State private var photoZoom = ZoomMemory()
    @State private var videoZoom = ZoomMemory()
    @State private var isNameExpanded = false
    @State private var isShowingInfo = false
    /// A video's controls, shown again for each asset. A tap on the video toggles them, and while it plays
    /// they hide after 3 s untouched, as on Android.
    @State private var videoControlsVisible = true
    @State private var isScrubbing = false

    /// How far the page has been pulled down to close.
    @State private var dismissOffset: CGFloat = 0
    /// How far the page has been pulled sideways past the first or last asset, towards another group.
    @State private var boundaryOffset: CGFloat = 0
    @State private var dragAxis: Axis?
    /// Set once a pull down has closed the viewer, so touches during the slide away are ignored.
    @State private var isClosing = false
    /// Set while a pull towards another group slides on to it, so a second swipe can't start.
    @State private var isSettling = false
    /// +1 or -1 right after moving to the next or previous group, easing to 0.
    @State private var clusterSlide: CGFloat = 0

    /// 100 px: a sideways swipe past this changes the asset.
    private static let swipeDistance: CGFloat = 40
    /// 200 px: a pull down past this closes.
    private static let closeDistance: CGFloat = 80
    /// 800 px: the backdrop is gone once pulled this far.
    private static let fadeDistance: CGFloat = 320

    init(model: DuplicatesModel, clusterIndex: Int, assetIndex: Int, activeClusterIndex: Binding<Int>) {
        self.model = model
        _activeClusterIndex = activeClusterIndex
        _clusterIndex = State(initialValue: clusterIndex)
        _selectedIndex = State(initialValue: assetIndex)
    }

    /// The groups the list shows, so "Only undecided groups" applies here too, as on Android.
    private var clusters: [DuplicatesModel.Cluster] { model.visibleClusters }
    private var assets: [Asset] { clusters.indices.contains(clusterIndex) ? clusters[clusterIndex].assets : [] }
    private var controlsOpacity: Double { min(max(1 - dismissOffset / Self.closeDistance, 0), 1) }
    private var current: Asset? { assets.indices.contains(selectedIndex) ? assets[selectedIndex] : assets.first }

    /// What restarts the controls' hide timer: a new asset, showing them, or using them.
    private struct AutoHide: Equatable {
        let asset: String?
        let visible: Bool
        let playing: Bool
        let muted: Bool
        let scrubbing: Bool
    }

    var body: some View {
        ZStack {
            // Opaque at rest, so the list never shows through; it only appears while pulling down to close.
            Color.black
                .opacity(min(max(1 - dismissOffset / Self.fadeDistance, 0), 1))
                .ignoresSafeArea()

            if let current {
                // As on Android, the picture only has the room between the top bar and the bottom panel;
                // nothing overlaps it, and zooming stays inside that window.
                VStack(spacing: 0) {
                    topBar(current)
                        // The controls fade away as the picture is pulled down.
                        .opacity(controlsOpacity)
                    media(current)
                        .offset(y: dismissOffset)
                    bottomPanel(current)
                        .opacity(controlsOpacity)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .presentationBackground(.clear)
        .sheet(isPresented: $isShowingInfo) {
            if let current {
                DuplicateInfoSheet(asset: current, client: model.client)
            }
        }
        .onChange(of: clusterIndex, initial: true) { activeClusterIndex = clusterIndex }
        .task(id: current?.id) {
            // The new surface reports its own zoom, which may have carried over.
            if let current { (current.type == .video ? photoZoom : videoZoom).viewport = nil }
            isNameExpanded = false
            videoControlsVisible = true
            updateVideo()
            prefetchNeighbours()
        }
        .task(id: AutoHide(asset: current?.id, visible: videoControlsVisible, playing: videoPlayer.isPlaying, muted: videoPlayer.isMuted, scrubbing: isScrubbing)) {
            guard current?.type == .video, videoControlsVisible, videoPlayer.isPlaying, !isScrubbing else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { videoControlsVisible = false }
        }
        .onDisappear { videoPlayer.stop() }
        // The groups were reloaded under the viewer (for example after a delete elsewhere).
        .onChange(of: clusters.isEmpty) { _, isEmpty in if isEmpty { dismiss() } }
    }

    // MARK: Top bar

    /// Close, then the file name (shortened in the middle until tapped) and size, then Favorite and Info.
    private func topBar(_ asset: Asset) -> some View {
        HStack(spacing: 12) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)

            VStack(spacing: 1) {
                let name = asset.originalFileName ?? String(localized: "Photo")
                Text(isNameExpanded ? name : DuplicateFormat.middleEllipsis(name))
                    .font(.headline)
                    .lineLimit(isNameExpanded ? nil : 1)
                if let size = asset.fileSize {
                    Text(DuplicateFormat.size(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { isNameExpanded.toggle() }

            let isFavorite = model.isFavorite(asset)
            GlassEffectContainer {
                HStack(spacing: 8) {
                    Button {
                        Task { await model.toggleFavorite(asset) }
                    } label: {
                        Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(isFavorite ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            .symbolEffect(.bounce, value: isFavorite)
                    }
                    Button("Asset info", systemImage: "info") { isShowingInfo = true }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: Media

    private func media(_ asset: Asset) -> some View {
        GeometryReader { geometry in
            let progress = min(max(abs(boundaryOffset) / max(geometry.size.width, 1), 0), 1)
            ZStack {
                // The neighbouring group's entry photo, sliding in from the side as this one leaves, as on Android.
                if let peek = peekAsset {
                    RemoteImage(request: model.client.authorizedRequest(for: .preview(assetID: peek.id)))
                        .scaleEffect(0.9 + 0.1 * progress)
                        .opacity(progress)
                        .offset(x: boundaryOffset + (boundaryOffset < 0 ? 1 : -1) * geometry.size.width)
                        .allowsHitTesting(false)
                }

                DuplicateViewerMedia(
                    asset: asset,
                    client: model.client,
                    videoPlayer: videoPlayer,
                    isZoomed: $isZoomed,
                    zoomMemory: asset.type == .video ? videoZoom : photoZoom,
                    onConfirmedTap: {
                        guard asset.type == .video else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { videoControlsVisible.toggle() }
                    },
                    onDrag: { handle($0, width: geometry.size.width) }
                )
                // As on Android, a video's controls sit over the bottom of the video.
                .overlay(alignment: .bottom) {
                    if asset.type == .video {
                        DuplicateVideoControls(asset: asset, player: videoPlayer.assetID == asset.id ? videoPlayer : nil, isScrubbing: $isScrubbing)
                            .opacity(videoControlsVisible ? 1 : 0)
                            .allowsHitTesting(videoControlsVisible)
                    }
                }
                .id(asset.id)
                .scaleEffect(1 - 0.1 * progress)
                .offset(x: boundaryOffset + clusterSlide * geometry.size.width * 0.25)
                .opacity((1 - abs(clusterSlide)) * (1 - progress))
            }
        }
        .clipped()
    }

    /// While pulled past the first or last asset: the next group's first photo, or the previous group's last.
    private var peekAsset: Asset? {
        if boundaryOffset < 0 { return clusters[safe: clusterIndex + 1]?.assets.first }
        if boundaryOffset > 0 { return clusters[safe: clusterIndex - 1]?.assets.last }
        return nil
    }

    private func handle(_ drag: ViewerDrag, width: CGFloat) {
        guard !isClosing, !isSettling else { return }
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
                let pullingNext = translation.width < 0 && selectedIndex == assets.count - 1 && clusterIndex < clusters.count - 1
                let pullingPrevious = translation.width > 0 && selectedIndex == 0 && clusterIndex > 0
                boundaryOffset = pullingNext || pullingPrevious ? translation.width : 0
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
                let direction = translation.width < -Self.swipeDistance ? 1 : translation.width > Self.swipeDistance ? -1 : 0
                if boundaryOffset != 0, direction == (boundaryOffset < 0 ? 1 : -1) {
                    // Slide the rest of the way to the neighbouring group, then switch without a second slide.
                    isSettling = true
                    withAnimation(.smooth) {
                        boundaryOffset = CGFloat(-direction) * width
                    } completion: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            changeCluster(by: direction, startAtLast: direction < 0, slides: false)
                            isSettling = false
                        }
                    }
                    return
                }
                withAnimation(.smooth) { boundaryOffset = 0 }
                if direction != 0 { step(direction) }
            }
        case .cancelled:
            dragAxis = nil
            withAnimation(.smooth) {
                dismissOffset = 0
                boundaryOffset = 0
            }
        }
    }

    /// Carries the pull on in one motion, as in the swipe screen's viewer: the picture keeps sliding down
    /// and the backdrop fades out, and only then is the cover removed, without its own slide. Otherwise
    /// the cover would slide down a second time after the picture had already been pulled.
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

    /// The next or previous asset, crossing into the neighbouring group at either end. Going back into a
    /// group starts on its last asset.
    private func step(_ direction: Int) {
        let target = selectedIndex + direction
        if assets.indices.contains(target) {
            selectedIndex = target
        } else {
            changeCluster(by: direction, startAtLast: direction < 0)
        }
    }

    /// `slides: false` is for a swipe, whose pull has already brought the new group's photo in.
    private func changeCluster(by direction: Int, startAtLast: Bool = false, slides: Bool = true) {
        let target = clusterIndex + direction
        guard clusters.indices.contains(target) else { return }
        clusterIndex = target
        selectedIndex = startAtLast ? clusters[target].assets.count - 1 : 0
        boundaryOffset = 0
        guard slides else { return }
        clusterSlide = CGFloat(direction.signum())
        withAnimation(.linear(duration: 0.25)) { clusterSlide = 0 }
    }

    // MARK: Bottom panel

    private func bottomPanel(_ asset: Asset) -> some View {
        VStack(spacing: 12) {
            // "Group 2 of 9" (or "1 / 3" with only one group) and the close hint.
            VStack(spacing: 2) {
                Group {
                    if clusters.count > 1 {
                        Text("Group \(clusterIndex + 1, format: .number) of \(clusters.count, format: .number)")
                    } else {
                        Text(verbatim: "\(selectedIndex + 1) / \(assets.count)")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()

                Text("Swipe down to dismiss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DuplicateViewerStrip(assets: assets, model: model, selectedIndex: $selectedIndex)
                .id(clusters.indices.contains(clusterIndex) ? clusters[clusterIndex].id : "")

            GlassEffectContainer {
                HStack {
                    groupButton(title: "Previous group", systemImage: "chevron.left", enabled: clusterIndex > 0) { changeCluster(by: -1) }
                    Spacer()
                    decisionButtons(asset)
                    Spacer()
                    groupButton(title: "Next group", systemImage: "chevron.right", enabled: clusterIndex < clusters.count - 1) { changeCluster(by: 1) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Delete and Keep, as on Android: each fills with its colour while it is the asset's choice, and
    /// pressing it again clears the choice.
    private func decisionButtons(_ asset: Asset) -> some View {
        let decision = model.decision(for: asset)
        return HStack(spacing: 8) {
            decisionButton(.delete, title: "Delete", systemImage: "trash.fill", current: decision, asset: asset)
            decisionButton(.keep, title: "Keep", systemImage: "checkmark.circle.fill", current: decision, asset: asset)
        }
        .animation(.snappy, value: decision)
        .sensoryFeedback(.selection, trigger: decision)
    }

    @ViewBuilder
    private func decisionButton(_ choice: SwipeDecision, title: LocalizedStringKey, systemImage: String, current: SwipeDecision?, asset: Asset) -> some View {
        let label = Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(minWidth: 84)
        Group {
            if current == choice {
                Button { model.choose(choice, for: asset) } label: { label }
                    .buttonStyle(.glassProminent)
                    .tint(DuplicateStyle.color(choice))
            } else {
                Button { model.choose(choice, for: asset) } label: { label }
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.large)
        .accessibilityAddTraits(current == choice ? .isSelected : [])
    }

    private func groupButton(title: LocalizedStringKey, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(!enabled)
    }

    // MARK: Loading

    private func updateVideo() {
        if let current, current.type == .video {
            videoPlayer.play(current, using: model.client)
        } else {
            videoPlayer.stop()
        }
    }

    /// The previews either side, including across group edges, so swiping never waits. Android also
    /// fetches the originals; here the original loads when its page opens.
    private func prefetchNeighbours() {
        var neighbours: [Asset] = []
        if let next = assets[safe: selectedIndex + 1] ?? clusters[safe: clusterIndex + 1]?.assets.first { neighbours.append(next) }
        if let previous = assets[safe: selectedIndex - 1] ?? clusters[safe: clusterIndex - 1]?.assets.last { neighbours.append(previous) }
        let requests = neighbours.map { model.client.authorizedRequest(for: .preview(assetID: $0.id)) }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await ThumbnailLoader.shared.prefetch(requests, maxPixelSize: 1440)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Media

/// The picture or video, fitted, with zoom. Photos show the preview first and the original over it once
/// it arrives. Videos loop; their controls are in the viewer's bottom panel (`DuplicateVideoPlayer.kt`).
private struct DuplicateViewerMedia: View {
    let asset: Asset
    let client: ImmichClient
    let videoPlayer: DeckVideoPlayer
    @Binding var isZoomed: Bool
    let zoomMemory: ZoomMemory
    let onConfirmedTap: () -> Void
    let onDrag: (ViewerDrag) -> Void

    @State private var aspectRatio: CGFloat?
    @State private var mediaFrame: CGRect?
    @State private var isLoadingOriginal = false

    private var isVideo: Bool { asset.type == .video }
    private var player: AVPlayer? { videoPlayer.assetID == asset.id ? videoPlayer.player : nil }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let frame = mediaFrame ?? CGRect(origin: .zero, size: geometry.size)
                ZStack {
                    RemoteImage(request: client.authorizedRequest(for: .preview(assetID: asset.id))) { size in
                        guard size.width > 0, size.height > 0 else { return }
                        aspectRatio = size.width / size.height
                    }
                    if !isVideo {
                        RemoteImage(request: client.authorizedRequest(for: .original(assetID: asset.id)), maxPixelSize: 4096, isOverlay: true, isLoading: $isLoadingOriginal)
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
                if isLoadingOriginal {
                    ProgressView()
                        .padding(8)
                        .background(.tint.opacity(0.6), in: .circle)
                } else if isVideo, videoPlayer.hasFailed {
                    ContentUnavailableView("Error playing video", systemImage: "video.slash")
                        .background(.black.opacity(0.6))
                }
            }

            ZoomSurface(
                aspectRatio: aspectRatio,
                mediaFrame: $mediaFrame,
                isZoomed: $isZoomed,
                // A tap never changes the choice, as on Android (on a video it shows or hides the controls);
                // a double tap zooms.
                onTap: { _, _ in false },
                onConfirmedTap: onConfirmedTap,
                onHold: { _ in },
                onDrag: onDrag,
                memory: zoomMemory
            )
            .accessibilityElement()
            .accessibilityLabel(isVideo ? "Video" : "Photo")
        }
    }
}

/// Laid out like the swipe viewer's video controls but compact, as on Android (`DuplicateVideoPlayer.kt`):
/// plain play-pause and mute on the left, "elapsed / length" on the right, and a seek bar below, over a
/// soft scrim along the bottom of the video.
private struct DuplicateVideoControls: View {
    let asset: Asset
    let player: DeckVideoPlayer?
    @Binding var isScrubbing: Bool

    @State private var scrubTime: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                controlButton(title: player?.isPlaying == false ? "Play" : "Pause", systemImage: player?.isPlaying == false ? "play.fill" : "pause.fill") {
                    player?.togglePlayPause()
                }
                controlButton(title: player?.isMuted == true ? "Unmute" : "Mute", systemImage: player?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    player?.toggleMute()
                }
                Spacer()
                Text("\(Self.mediaTime(scrubTime ?? currentTime)) / \(Self.mediaTime(duration))")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.trailing, 12)
                    .accessibilityHidden(true)
            }

            Slider(
                value: Binding(
                    get: { scrubTime ?? currentTime },
                    set: { time in
                        guard let player else { return }
                        scrubTime = time
                        player.seek(to: time)
                    }
                ),
                in: 0...max(duration, 0.1)
            ) { isEditing in
                isScrubbing = isEditing
                if !isEditing { scrubTime = nil }
            }
            .tint(.white)
            .padding(.horizontal, 12)
            .accessibilityLabel("Playback position")
            .accessibilityValue(Text("\(Self.mediaTime(scrubTime ?? currentTime)) of \(Self.mediaTime(duration))"))
        }
        .foregroundStyle(.white)
        // Android: 4 pt at the sides and bottom, 16 pt at the top for the scrim to fade in.
        .padding(.horizontal, 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .disabled(player == nil)
    }

    /// A plain 44 pt icon button, like Android's icon buttons here.
    private func controlButton(title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .buttonStyle(.plain)
    }

    private var currentTime: Double { player?.currentTime ?? 0 }

    private var duration: Double {
        if let player, player.duration > 0 { return player.duration }
        return Double(asset.durationMilliseconds ?? 0) / 1000
    }

    /// "1:05", or "1:02:05" past an hour (`formatMediaTime`).
    static func mediaTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let (hours, minutes, secs) = (total / 3600, (total / 60) % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Strip

/// The group's assets as small tiles, like the strip under a photo in Photos. The selected one sits in the
/// middle, a little larger and outlined; scrolling selects whichever tile stops in the middle, and tapping
/// one selects it. Each shows its choice as in the cards, and its size for comparing.
private struct DuplicateViewerStrip: View {
    let assets: [Asset]
    let model: DuplicatesModel
    @Binding var selectedIndex: Int

    @State private var width: CGFloat = 0
    @State private var scrolledID: String?

    private static let tileWidth: CGFloat = 54

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                    tile(asset, isSelected: index == selectedIndex)
                        .onTapGesture { selectedIndex = index }
                }
            }
            .scrollTargetLayout()
        }
        .frame(height: 80)
        .contentMargins(.horizontal, max((width - Self.tileWidth) / 2, 16), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolledID, anchor: .center)
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: scrolledID) {
            if let index = assets.firstIndex(where: { $0.id == scrolledID }), index != selectedIndex {
                selectedIndex = index
            }
        }
        .onChange(of: selectedIndex, initial: true) {
            guard assets.indices.contains(selectedIndex) else { return }
            withAnimation(.smooth) { scrolledID = assets[selectedIndex].id }
        }
    }

    private func tile(_ asset: Asset, isSelected: Bool) -> some View {
        let decision = model.decision(for: asset)
        return DuplicateFilledImage(request: model.client.authorizedRequest(for: .preview(assetID: asset.id)))
            .overlay {
                if decision == .delete { Color.black.opacity(0.35) }
            }
            // As on Android's strip: the choice top right, favorite and video top left, the size along the
            // bottom. The tile is too narrow for the size and the choice to share the bottom edge.
            .overlay(alignment: .topTrailing) {
                if let decision {
                    DuplicateDecisionBadge(decision: decision, size: 16).padding(3)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 2) {
                    if model.isFavorite(asset) {
                        Image(systemName: "heart.fill").foregroundStyle(.red)
                    }
                    if asset.type == .video {
                        Image(systemName: "play.fill").foregroundStyle(.white)
                    }
                }
                .font(.system(size: 9))
                .shadow(radius: 2)
                .padding(3)
            }
            .overlay(alignment: .bottom) {
                if let size = asset.fileSize {
                    Text(DuplicateFormat.size(size))
                        .font(.system(size: 8, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 3)
                }
            }
            .frame(width: Self.tileWidth, height: 68)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white, lineWidth: 2)
                }
            }
            .opacity(isSelected ? 1 : 0.7)
            .scaleEffect(isSelected ? 1.08 : 1)
            .animation(.snappy, value: isSelected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asset.type == .video ? "Video" : "Photo")
            .accessibilityValue(decision.map(DuplicateStyle.label) ?? "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Info

/// File, date, format, size, resolution and albums, and a button to open the asset in Immich: the app on a tap,
/// the browser on a long press, as on Android. A standard iOS grouped list rather than Android's dialog.
/// Shared with the swipe screen's fullscreen viewer, as Android's `AssetInfoDialog` is.
struct DuplicateInfoSheet: View {
    let asset: Asset
    let client: ImmichClient

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// The real albums holding the asset, loaded when the sheet opens; nil while loading.
    @State private var albumNames: [String]?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("File", systemImage: "doc", value: asset.originalFileName ?? String(localized: "Unknown"))
                    row("Date", systemImage: "calendar", value: String(asset.effectiveDate.prefix { $0 != "T" }))
                    row("Format", systemImage: "info.circle", value: format)
                    row("Size", systemImage: "internaldrive", value: asset.fileSize.map(DuplicateFormat.size) ?? String(localized: "Unknown"))
                    row("Resolution", systemImage: "aspectratio", value: resolution)
                    row("Albums", systemImage: "rectangle.stack", value: albums)
                }

                Section {
                    // Not a Button, so the long press fires while held instead of on release.
                    Label("Open in Immich", systemImage: "arrow.up.forward.square")
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture {
                            openURL(appURL) { accepted in
                                if !accepted { openURL(webURL) }
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.4) { openURL(webURL) }
                        .accessibilityAddTraits(.isButton)
                } footer: {
                    Text("Long press to open in browser")
                }
            }
            .navigationTitle(asset.type == .video ? "Video details" : "Image details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Empty if the request fails, as on Android (`loadAlbumNames`).
        .task(id: asset.id) {
            albumNames = nil
            let albums: [Album]
            do {
                albums = try await client.getAllAlbums(containing: asset.id)
            } catch {
                AppLog.e("Duplicates", "Failed to load albums for asset", error)
                albums = []
            }
            albumNames = albums.filter { !$0.isVirtual }.map(\.albumName)
        }
    }

    private func row(_ label: LocalizedStringKey, systemImage: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    /// "IMAGE (.heic)", as on Android.
    private var format: String {
        let type = asset.type.rawValue
        guard let name = asset.originalFileName, let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex else { return type }
        return "\(type) (.\(name[name.index(after: dot)...].lowercased()))"
    }

    /// As in the card's metadata panel.
    private var albums: String {
        guard let albumNames else { return String(localized: "Loading…") }
        return albumNames.isEmpty ? String(localized: "None") : albumNames.formatted(.list(type: .and, width: .narrow))
    }

    private var resolution: String {
        guard let exif = asset.exifInfo else { return String(localized: "Unknown") }
        let width = exif.exifImageWidth.map(String.init) ?? "?"
        let height = exif.exifImageHeight.map(String.init) ?? "?"
        return "\(width) × \(height)"
    }

    /// The same links as the swipe screen's Open in Immich (`DeckModel.immichURL`).
    private var webURL: URL { client.serverURL.appending(path: "photos").appending(path: asset.id) }
    private var appURL: URL { URL(string: "immich://asset?id=\(asset.id)") ?? webURL }
}
