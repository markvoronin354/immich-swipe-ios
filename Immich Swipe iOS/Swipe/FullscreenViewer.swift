import AVFoundation
import SwiftUI

/// The fullscreen viewer, as on Android (`FullscreenViewer.kt`): the current photo or video on black,
/// with the next one waiting behind it.
///
/// Drag right or left to do what swiping that way does on the card, and the next photo takes its place;
/// drag up to close. Dragging down closes too, unless "Use swipe down action in fullscreen" is on, when it does
/// what swiping down does on the card. Pinch or double-tap to zoom. Tapping shows or hides the controls, and
/// with tap to swipe on, tapping the edges swipes. Holding a finger down hides the controls and pauses a video
/// until it lifts.
///
/// Android's distances are pixels; they are divided by 2.5 here, as for the card (`CardMotion`).
struct FullscreenViewer: View {
    let model: DeckModel
    let videoPlayer: DeckVideoPlayer
    let livePhotoPlayer: LivePhotoPlayer

    @Environment(\.dismiss) private var dismiss
    private let prefs = DeckPreferences()

    /// How far the current page has been dragged.
    @State private var dragOffset: CGSize = .zero
    @State private var isFlying = false
    @State private var isHolding = false
    @State private var wasPlayingBeforeHold = false
    @State private var isZoomed = false
    /// Toggled by a tap. Kept from one asset to the next, as on Android.
    @State private var controlsVisible = true
    /// The asset whose details are showing.
    @State private var infoAsset: Asset?
    /// The photo the album picker is open for, over the viewer, which stays open.
    @State private var albumAsset: Asset?
    /// While the photo brought back by a swipe down rises in from below, so it shows no badge.
    @State private var isRestoring = false

    /// 150 px: past this a released drag swipes.
    fileprivate static let swipeDistance: CGFloat = 60
    /// 120 px up or down, and less than 100 px sideways, closes, or runs the swipe down action.
    fileprivate static let closeDistance: CGFloat = 48
    private static let closeMaxSideways: CGFloat = 40
    /// 1000 px: the background is gone once the page has been pulled this far towards closing.
    private static let fadeDistance: CGFloat = 400
    /// 2000 px: where a page swiped sideways flies to.
    private static let flyDistance: CGFloat = 800
    /// Android flies a page swiped down off the window; this clears the tallest iPad.
    private static let verticalFlyDistance: CGFloat = 1400
    /// 500 px: the next page is full size once the current one is this far aside.
    private static let nextGrowDistance: CGFloat = 200

    var body: some View {
        ZStack {
            Color.black
                .opacity(fade)
                .ignoresSafeArea()

            if let next = model.deck.upcoming(1).first {
                ViewerPage(asset: next, model: model, videoPlayer: videoPlayer, livePhotoPlayer: livePhotoPlayer, scale: 0.85 + 0.15 * nextProgress, controlsVisible: controlsVisible && !isHolding)
                    .id(next.id)
                    .opacity((0.6 + 0.4 * nextProgress) * fade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let current = model.deck.current {
                ViewerPage(
                    asset: current,
                    model: model,
                    videoPlayer: videoPlayer,
                    livePhotoPlayer: livePhotoPlayer,
                    isCurrent: true,
                    offset: dragOffset,
                    fade: fade,
                    controlsVisible: controlsVisible && !isHolding,
                    isZoomed: $isZoomed,
                    isRestoring: isRestoring,
                    actions: actions(for: current)
                )
                .id(current.id)
            }
        }
        .environment(\.colorScheme, .dark)
        .presentationBackground(.clear)
        #if os(iOS)
        // Android hides the system bars in the viewer.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        .animation(.easeInOut(duration: 0.2), value: isHolding)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .sheet(item: $infoAsset) { asset in
            DuplicateInfoSheet(asset: asset, client: model.client)
        }
        .sheet(item: $albumAsset) { asset in
            AddToAlbumSheet(model: model, asset: asset)
        }
        .onChange(of: model.deck.current?.id) {
            isHolding = false
            isZoomed = false
            livePhotoPlayer.stop()
        }
        .onDisappear { livePhotoPlayer.stop() }
        // The last photo has been sorted.
        .onChange(of: model.deck.current == nil) { _, isFinished in
            if isFinished { dismiss() }
        }
    }

    /// 1 at rest, 0 once the page has been pulled `fadeDistance` towards closing: up always, and down unless
    /// swiping down runs its action.
    private var fade: Double {
        let closingPull = prefs.fullscreenSwipeDownUsesAction ? -dragOffset.height : abs(dragOffset.height)
        return min(max(1 - closingPull / Self.fadeDistance, 0), 1)
    }

    /// A pull that swipes, rather than closes, undoes or opens a picker, brings the next photo up as a sideways one does.
    private var nextProgress: CGFloat {
        let pullsToSwipe = prefs.fullscreenSwipeDownUsesAction && prefs.swipeDownAction != .undo && !prefs.swipeDownAction.isDropTarget
        let pull = pullsToSwipe ? max(abs(dragOffset.width), dragOffset.height) : abs(dragOffset.width)
        return min(pull / Self.nextGrowDistance, 1)
    }

    private func actions(for asset: Asset) -> ViewerActions {
        ViewerActions(
            tap: { point, size in tap(at: point, in: size) },
            confirmedTap: { controlsVisible.toggle() },
            playPause: {
                guard asset.type == .video, videoPlayer.assetID == asset.id else { return }
                videoPlayer.togglePlayPause()
            },
            hold: { hold($0, asset: asset) },
            drag: drag,
            swipe: { swipe($0, toward: $1) },
            close: { dismiss() },
            undo: { model.undo() },
            favorite: { model.toggleFavoriteForCurrent() },
            mute: { videoPlayer.toggleMute() },
            toggleLivePhoto: { livePhotoPlayer.toggle(asset, using: model.client) },
            fullResolution: { model.toggleFullResolution(keepWhileSwiping: prefs.keepFullResolution) },
            info: { infoAsset = asset }
        )
    }

    /// Tap to swipe on the edges, as on the card. Not while zoomed in.
    private func tap(at point: CGPoint, in size: CGSize) -> Bool {
        guard !isZoomed, let edge = CardTapRules.edge(atX: point.x, width: size.width, tapToSwipe: prefs.tapToSwipe) else {
            return false
        }
        swipe(prefs.swipes.action(toward: edge), toward: edge)
        return true
    }

    private func hold(_ isHeld: Bool, asset: Asset) {
        isHolding = isHeld
        guard asset.type == .video, videoPlayer.assetID == asset.id else { return }
        if isHeld {
            wasPlayingBeforeHold = videoPlayer.isPlaying
            videoPlayer.pause()
        } else if wasPlayingBeforeHold {
            videoPlayer.resume()
        }
    }

    /// The page follows the finger. While a finger is held the drag is ignored.
    private func drag(_ drag: ViewerDrag) {
        guard !isFlying else { return }
        switch drag {
        case .changed(let translation):
            guard !isHolding else { return }
            // With nothing to undo, a pull down that would undo resists instead of following the finger.
            let resists = prefs.fullscreenSwipeDownUsesAction && prefs.swipeDownAction == .undo && !model.deck.canUndo
            let height = resists && translation.height > 0 ? translation.height * 0.2 : translation.height
            dragOffset = CGSize(width: translation.width, height: height)
        case .ended:
            let (x, y) = (dragOffset.width, dragOffset.height)
            if isHolding {
                snapBack()
            } else if y > Self.closeDistance, abs(x) < Self.closeMaxSideways {
                if prefs.fullscreenSwipeDownUsesAction { swipeDown() } else { close() }
            } else if y < -Self.closeDistance, abs(x) < Self.closeMaxSideways {
                close()
            } else if x > Self.swipeDistance {
                swipe(prefs.swipes.right, toward: .trailing)
            } else if x < -Self.swipeDistance {
                swipe(prefs.swipes.left, toward: .leading)
            } else {
                snapBack()
            }
        case .cancelled:
            snapBack()
        }
    }

    private func snapBack() {
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) { dragOffset = .zero }
    }

    /// Throws the page off towards the edge in 180 ms, as on Android, then carries out the action. The next
    /// page is already in place underneath.
    private func swipe(_ action: SwipeAction, toward edge: Edge) {
        guard !isFlying, !isHolding, let assetID = model.deck.current?.id else { return }
        isFlying = true
        let target: CGSize = switch edge {
        case .trailing: CGSize(width: Self.flyDistance, height: 0)
        case .leading: CGSize(width: -Self.flyDistance, height: 0)
        case .bottom: CGSize(width: 0, height: Self.verticalFlyDistance)
        case .top: CGSize(width: 0, height: -Self.verticalFlyDistance)
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            dragOffset = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.swipe(action, on: assetID)
                dragOffset = .zero
            }
            isFlying = false
        }
    }

    /// A swipe down that runs the card's swipe down action. Undo keeps the viewer open, as on Android: this
    /// photo drops away and the one brought back rises in from below. So does Album: the picker opens over the
    /// photo, which springs back, as there is no strip to drop it on here.
    private func swipeDown() {
        let action = prefs.swipeDownAction
        if action == .album {
            albumAsset = model.deck.current
            snapBack()
            return
        }
        guard action == .undo else {
            swipe(action, toward: .bottom)
            return
        }
        guard !isFlying, !isHolding, model.deck.canUndo else {
            snapBack()
            return
        }
        isFlying = true
        withAnimation(.easeInOut(duration: 0.18)) {
            dragOffset = CGSize(width: 0, height: Self.verticalFlyDistance)
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.undo()
                isRestoring = true
            }
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                dragOffset = .zero
            } completion: {
                isRestoring = false
                isFlying = false
            }
        }
    }

    /// Carries the pull on in one motion: the page keeps sliding up or down and the background fades out, and
    /// only then is the cover removed, without its own slide. Otherwise the cover would slide away a
    /// second time after the page had already been pulled.
    private func close() {
        isFlying = true
        withAnimation(.easeOut(duration: 0.22)) {
            dragOffset = CGSize(width: dragOffset.width, height: dragOffset.height < 0 ? -1000 : 1000)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

/// What the current page's touches and buttons do.
struct ViewerActions {
    var tap: (CGPoint, CGSize) -> Bool = { _, _ in false }
    var confirmedTap: () -> Void = {}
    var playPause: () -> Void = {}
    var hold: (Bool) -> Void = { _ in }
    var drag: (ViewerDrag) -> Void = { _ in }
    var swipe: (SwipeAction, Edge) -> Void = { _, _ in }
    var close: () -> Void = {}
    var undo: () -> Void = {}
    var favorite: () -> Void = {}
    var mute: () -> Void = {}
    var toggleLivePhoto: () -> Void = {}
    var fullResolution: () -> Void = {}
    var info: () -> Void = {}
}

// MARK: - Page

/// One asset in the viewer: its media, the controls over it and the Keep / Delete stamp. The page waiting
/// behind the current one is only a picture: no touches, no video, no original.
private struct ViewerPage: View {
    let asset: Asset
    let model: DeckModel
    let videoPlayer: DeckVideoPlayer
    let livePhotoPlayer: LivePhotoPlayer
    var isCurrent = false
    /// Applied inside each layer rather than to the whole page: a page scaled from outside no longer
    /// reaches the screen edges, so its media stops ignoring the safe area and is centred 12 pt lower,
    /// then jumps up when it becomes the current page.
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var fade: Double = 1
    var controlsVisible = true
    var isZoomed: Binding<Bool> = .constant(false)
    /// Rising back in after a swipe down undid, so the badge stays off it, as on the card.
    var isRestoring = false
    var actions = ViewerActions()

    private let prefs = DeckPreferences()
    /// Width over height of the media as drawn, from the preview once it has loaded.
    @State private var aspectRatio: CGFloat?
    /// Where the zoom surface wants the media drawn; nil fills the screen.
    @State private var mediaFrame: CGRect?
    @State private var isLoadingOriginal = false
    @State private var showsVideoSpinner = false

    private var rotation: Int { model.rotation(of: asset) }
    private var isVideo: Bool { asset.type == .video }

    /// The deck's shared player, once it is playing this page's video.
    private var player: AVPlayer? {
        isCurrent && videoPlayer.assetID == asset.id ? videoPlayer.player : nil
    }

    /// The live photo player, while it is playing this page's clip.
    private var livePhotoClip: AVPlayer? {
        isCurrent && livePhotoPlayer.assetID == asset.id ? livePhotoPlayer.player : nil
    }

    /// The preview is shown, and the original drawn over it only while full resolution is on, as on
    /// Android (`FullResolutionRequest.kt`). GIFs already load as originals.
    private var originalRequest: URLRequest? {
        guard isCurrent, !asset.isGIF, model.usesFullResolution(asset, keepWhileSwiping: prefs.keepFullResolution) else { return nil }
        return model.originalRequest(for: asset)
    }

    /// The file size, shown only while the deck is sorted by size.
    private var sizeText: String? {
        guard model.sortOrder == .sizeDescending || model.sortOrder == .sizeAscending else { return nil }
        return (asset.fileSize ?? 0).formatted(.byteCount(style: .file))
    }

    /// Before the video's player is ready, and while it buffers. Shown after half a second, so a quick
    /// start doesn't flicker.
    private var isWaitingForVideo: Bool {
        isCurrent && isVideo && !videoPlayer.hasFailed && (player == nil || videoPlayer.isBuffering)
    }

    var body: some View {
        ZStack {
            mediaLayer
                // Rounded like the screen, so the page doesn't show square corners as it tilts away.
                .clipShape(ConcentricRectangle())
                .scaleEffect(scale)
                .rotationEffect(.degrees(offset.width / 24))
                .offset(offset)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            if isCurrent {
                ZoomSurface(
                    aspectRatio: aspectRatio,
                    mediaFrame: $mediaFrame,
                    isZoomed: isZoomed,
                    onTap: actions.tap,
                    onConfirmedTap: actions.confirmedTap,
                    onHold: actions.hold,
                    onDrag: actions.drag
                )
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel(isVideo ? "Video" : "Photo")
                .accessibilityAction(named: Text(prefs.swipes.right.title)) { actions.swipe(prefs.swipes.right, .trailing) }
                .accessibilityAction(named: Text(prefs.swipes.left.title)) { actions.swipe(prefs.swipes.left, .leading) }
                .accessibilityAction(named: model.isFavorite(asset) ? "Unfavorite" : "Favorite") { actions.favorite() }
                .accessibilityActions {
                    if player != nil {
                        Button(videoPlayer.isPlaying ? "Pause" : "Play") { actions.playPause() }
                    }
                }
            }

            // Laid out full screen outside the tilt, like the media: under a rotation SwiftUI drops the safe area,
            // so an `ignoresSafeArea` inside it stops reaching the screen edge and the scrim comes up short.
            ViewerScrim()
                .opacity(controlsVisible ? 1 : 0)
                .scaleEffect(scale)
                .rotationEffect(.degrees(offset.width / 24))
                .offset(offset)
                .ignoresSafeArea()

            // The controls move and tilt with the page, as on Android.
            ViewerControls(
                asset: asset,
                isFavorite: model.isFavorite(asset),
                canUndo: model.deck.canUndo,
                isMuted: videoPlayer.isMuted,
                isFullResolution: model.usesFullResolution(asset, keepWhileSwiping: prefs.keepFullResolution),
                showsLabels: prefs.showToolbarLabels,
                sizeText: sizeText,
                videoPlayer: player == nil ? nil : videoPlayer,
                actions: actions
            )
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(isCurrent && controlsVisible)
            .scaleEffect(scale)
            .rotationEffect(.degrees(offset.width / 24))
            .offset(offset)

            stamp
                .rotationEffect(.degrees(offset.width / 24))
                .offset(offset)
        }
        .task(id: isWaitingForVideo) {
            guard isWaitingForVideo else {
                showsVideoSpinner = false
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { showsVideoSpinner = true }
        }
    }

    /// The media, turned in 90° steps, drawn where the zoom surface says, over the page's own black.
    private var mediaLayer: some View {
        GeometryReader { geometry in
            let frame = mediaFrame ?? CGRect(origin: .zero, size: geometry.size)
            let sideways = rotation % 180 != 0
            ZStack {
                RemoteImage(request: model.previewRequest(for: asset), animates: isCurrent && asset.isGIF) { size in
                    guard size.width > 0, size.height > 0 else { return }
                    aspectRatio = sideways ? size.height / size.width : size.width / size.height
                }
                if let originalRequest {
                    RemoteImage(request: originalRequest, maxPixelSize: 4096, isOverlay: true, isLoading: $isLoadingOriginal)
                }
                if let player = player ?? livePhotoClip {
                    PlayerSurface(player: player)
                }
            }
            .frame(width: sideways ? frame.height : frame.width, height: sideways ? frame.width : frame.height)
            .rotationEffect(.degrees(Double(rotation)))
            .position(x: frame.midX, y: frame.midY)
        }
        .overlay { statusOverlay }
        .background(.black.opacity(fade))
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if isCurrent, isVideo, videoPlayer.hasFailed {
            ContentUnavailableView("Error playing video", systemImage: "video.slash")
                .background(.black.opacity(0.6))
        } else if showsVideoSpinner {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoadingOriginal {
            // The preview stays visible underneath, so this is small and see-through.
            ProgressView()
                .padding(8)
                .background(.tint.opacity(0.6), in: .circle)
        }
    }

    /// What the drag would do, fading in over the first 200 px of it, up to 90%: the swipe down action while
    /// that is on and pulling down would run it, else the action for the side being dragged towards.
    @ViewBuilder
    private var stamp: some View {
        let swipes = prefs.swipes
        let pullsDown = prefs.fullscreenSwipeDownUsesAction && !isRestoring
            && (model.deck.canUndo || swipes.down != .undo) && offset.height > abs(offset.width)
        if pullsDown || offset.width != 0 {
            let intent = pullsDown ? SwipeIntent(action: swipes.down, edge: .bottom)
                : offset.width > 0 ? SwipeIntent(action: swipes.right, edge: .trailing)
                : SwipeIntent(action: swipes.left, edge: .leading)
            let distance = pullsDown ? offset.height : abs(offset.width)
            IntentStamp(action: intent.action, isCommitted: distance > (pullsDown ? FullscreenViewer.closeDistance : FullscreenViewer.swipeDistance))
                .opacity(min(distance / 80, 1) * 0.9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: intent.stampAlignment)
                // Below the top bar, as on Android.
                .padding(.top, ViewerControls.topBarBottom + 6)
                .padding(.horizontal, 60)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Controls

/// The layout of Android's `PreviewControls.kt`. A top bar with Back, the date and time, and Info; three
/// fixed slots at the bottom for Undo, Favorite, and Mute on videos or full resolution on photos (empty on
/// GIFs, so nothing moves when the next page differs); and gradients behind both, so the containerless controls stay legible. Above the bottom
/// row sit a video's controls, or a photo's size while sorting by size.
private struct ViewerControls: View {
    let asset: Asset
    let isFavorite: Bool
    let canUndo: Bool
    let isMuted: Bool
    let isFullResolution: Bool
    let showsLabels: Bool
    let sizeText: String?
    /// Set for the current page's video once it is playing.
    let videoPlayer: DeckVideoPlayer?
    let actions: ViewerActions

    /// 8 pt above the 64 pt top bar, from the top of the safe area.
    static let topBarBottom: CGFloat = 8 + 64

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()

            // 12 pt above the bottom row, as on Android.
            if asset.type == .video {
                VideoControls(asset: asset, player: videoPlayer, sizeText: sizeText, onTogglePlay: actions.playPause)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                VStack(spacing: 8) {
                    if asset.isLivePhoto {
                        LivePill(action: actions.toggleLivePhoto)
                    }
                    if let sizeText {
                        SizePill(text: sizeText)
                    }
                }
                .padding(.bottom, 12)
            }

            bottomBar
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button("Back", systemImage: "chevron.backward", action: actions.close)
                .keyboardShortcut(.cancelAction)
                .modifier(TopBarButtonStyle())

            VStack(spacing: 0) {
                if let dateTime {
                    Text(dateTime.date)
                        .font(.headline)
                        .lineLimit(1)
                    Text(dateTime.time)
                        .font(.caption)
                        .opacity(0.8)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Button("Asset info", systemImage: "info.circle", action: actions.info)
                .modifier(TopBarButtonStyle())
        }
        .padding(.horizontal, 4)
        .frame(height: 64)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ViewerAction(title: "Undo", systemImage: "arrow.uturn.backward", showsLabel: showsLabels, action: actions.undo)
                .disabled(!canUndo)
                .opacity(canUndo ? 1 : 0.38)
                .frame(maxWidth: .infinity)

            ViewerAction(
                title: "Favorite",
                systemImage: isFavorite ? "heart.fill" : "heart",
                showsLabel: showsLabels,
                action: actions.favorite
            )
            .accessibilityAddTraits(isFavorite ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: isFavorite)
            .frame(maxWidth: .infinity)

            ZStack {
                if asset.type == .video {
                    ViewerAction(
                        title: isMuted ? "Unmute" : "Mute",
                        systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        showsLabel: showsLabels,
                        action: actions.mute
                    )
                } else if !asset.isGIF {
                    // The HD badge fills in while the original is shown, like Android's filled and outlined icons.
                    ViewerAction(
                        title: "Full-res",
                        systemImage: CardGlyph.hd,
                        isFilled: isFullResolution,
                        showsLabel: showsLabels,
                        action: actions.fullResolution
                    )
                    .accessibilityAddTraits(isFullResolution ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 64)
        .padding(.bottom, 8)
    }

    /// "Nov 11", with the year when it isn't this year, and the time in the device's clock format.
    private var dateTime: (date: String, time: String)? {
        let iso = asset.effectiveDate
        guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))
            ?? (try? Date.ISO8601FormatStyle().parse(iso)) else { return nil }
        let isThisYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let day = isThisYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return (day, date.formatted(date: .omitted, time: .shortened))
    }
}

/// A containerless icon button in the top bar.
private struct TopBarButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 48, height: 48)
            .contentShape(.rect)
            .buttonStyle(.plain)
    }
}

/// A containerless bottom-row action: its icon over its label, or the icon alone with labels turned
/// off. The icon bounces on a tap, as on Android.
private struct ViewerAction: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isFilled = false
    let showsLabel: Bool
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 4) {
                CardGlyph(name: systemImage, isFilled: isFilled)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: taps)
                if showsLabel {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Darkens the top 160 pt and bottom 280 pt behind the controls, as on Android (`ViewerScrim`).
private struct ViewerScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 280)
        }
        .clipShape(ConcentricRectangle())
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The file size while sorting by size, in the card buttons' look (`CardIconLabel`): a dark tint over a
/// blurred material with a thin rim. Liquid Glass would swell while the page tilts during a swipe.
private struct SizePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.35), in: .capsule)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
    }
}

/// Fullscreen video controls, as on Android (`VideoControls` in `SharedVideoPlayer.kt`): play/pause on
/// the left and the size and "elapsed / length" on the right, with a seek bar below that moves the video
/// as it is dragged. Before the video plays (the next page, or while loading) they show 0:00 against the
/// length the server reported, so they are already in place.
private struct VideoControls: View {
    let asset: Asset
    let player: DeckVideoPlayer?
    let sizeText: String?
    let onTogglePlay: () -> Void

    /// Where the seek bar is being dragged to, or nil when it follows the video.
    @State private var scrubTime: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill", action: onTogglePlay)
                    .contentTransition(.symbolEffect(.replace))
                    .disabled(player == nil)
                    .modifier(TopBarButtonStyle())

                Spacer()

                if let sizeText {
                    SizePill(text: sizeText)
                        .padding(.trailing, 12)
                }

                Text("\(Self.mediaTime(scrubTime ?? currentTime)) / \(Self.mediaTime(duration))")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .padding(.trailing, 12)
                    .accessibilityHidden(true)
            }

            slider
        }
    }

    private var slider: some View {
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
            if !isEditing { scrubTime = nil }
        }
        .tint(.white)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text("\(Self.mediaTime(scrubTime ?? currentTime)) of \(Self.mediaTime(duration))"))
    }

    private var isPlaying: Bool { player?.isPlaying ?? false }

    private var currentTime: Double { player?.currentTime ?? 0 }

    private var duration: Double {
        if let player, player.duration > 0 { return player.duration }
        return Double(asset.durationMilliseconds ?? 0) / 1000
    }

    /// "1:05", or "1:02:05" past an hour, as on Android (`formatMediaTime`).
    static func mediaTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let (hours, minutes, secs) = (total / 3600, (total / 60) % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
