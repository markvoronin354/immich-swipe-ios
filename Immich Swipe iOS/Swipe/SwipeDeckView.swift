import SwiftUI

/// The swipe screen, laid out like the Android app: progress pill, counts, thumbnail strip, the card,
/// and a bottom bar with Undo, Archive, Favorite, Album and Sort.
///
/// Decisions are saved on the device only. They're sent to the server from "Apply changes", a
/// separate step with its own review screen.
struct SwipeDeckView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.openURL) private var openURL

    private let prefs = DeckPreferences()

    @State private var model: DeckModel
    @State private var motion = CardMotion()
    @State private var videoPlayer = DeckVideoPlayer()
    @State private var livePhotoPlayer = LivePhotoPlayer()
    @State private var isConfirmingReset = false
    @State private var isReviewing = false
    @State private var albumAsset: Asset?
    @State private var ratingAsset: Asset?
    /// The albums or stars a card pulled down is dropped on, with the finger's place over them.
    @State private var drop = DropStripState()
    /// Why a card dropped on an album couldn't be added to it, or a rating couldn't be set. The card has often
    /// gone by then, so this says so.
    @State private var failure: DropFailure?
    /// The viewer follows the deck's current photo, so it stays open as photos are kept or deleted in it.
    @State private var isFullscreen = false

    init(model: DeckModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressPill(
                remaining: model.remainingCount,
                deleted: model.deletedCount,
                kept: model.keptCount,
                progress: model.progress,
                isLoadingMore: model.isLoadingMore
            ) {
                isReviewing = true
            }
            .padding(.horizontal)

            if !model.deck.assets.isEmpty {
                // Android's chevron above the card: it folds the timeline away and brings it back.
                Button {
                    withAnimation(.snappy) { prefs.showTimeline.toggle() }
                } label: {
                    Image(systemName: "chevron.compact.up")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(prefs.showTimeline ? 0 : 180))
                        .frame(width: 96, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Asset timeline")

                if prefs.showTimeline {
                    DeckTimelineStrip(model: model)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)

            DeckBottomBar(
                model: model,
                motion: motion,
                onAlbum: { albumAsset = model.deck.current }
            )
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
        // Slides the card up or down along with the strip, whichever way the chevron was tapped.
        .animation(.snappy, value: prefs.showTimeline)
        .navigationTitle(model.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reset Decisions", systemImage: "arrow.clockwise") { isConfirmingReset = true }
                    .tint(.red)
                    .disabled(model.decidedCount == 0)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            // No glass behind the avatar: it is already a round picture.
            ToolbarItem(placement: .primaryAction) {
                ProfileButton()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // An alert, not a confirmation dialog: on iPhone that one hangs off the button instead of centring.
        .alert("Reset this album?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Decisions", role: .destructive) { model.resetDecisions() }
        } message: {
            Text("Every keep, delete, archive and lock decision for these photos is forgotten. Nothing on the server changes.")
        }
        .sheet(isPresented: $isReviewing) {
            DeckReviewSheet(model: model)
        }
        .sheet(item: $albumAsset) { asset in
            AddToAlbumSheet(model: model, asset: asset)
        }
        .sheet(item: $ratingAsset) { asset in
            RatingSheet(model: model, asset: asset)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isFullscreen) {
            FullscreenViewer(model: model, videoPlayer: videoPlayer, livePhotoPlayer: livePhotoPlayer)
        }
        #else
        .sheet(isPresented: $isFullscreen) {
            FullscreenViewer(model: model, videoPlayer: videoPlayer, livePhotoPlayer: livePhotoPlayer)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
        .sensoryFeedback(.impact(weight: .light), trigger: model.decidedCount)
        .task { await model.load() }
        .task(id: model.deck.current?.id) {
            prefetchUpcoming()
            updateVideo()
            await model.loadCurrentDetails()
        }
        .onDisappear {
            videoPlayer.stop()
            livePhotoPlayer.stop()
        }
        #if os(iOS)
        // Swiping a card right to keep could start the system "swipe back" instead. The back button still works.
        .background { BackSwipeBlocker() }
        #endif
        .overlay(alignment: .top) {
            if model.transfer == .saved {
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.green.opacity(0.3)), in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Over the bottom bar, as on Android, while a card is pulled down to be dropped on an album or a star.
        .overlay(alignment: .bottom) {
            ZStack {
                if drop.isActive {
                    dropStrip
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: drop.isActive)
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }), presenting: failure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .animation(.snappy, value: model.transfer)
        .task(id: model.transfer) {
            guard model.transfer == .saved else { return }
            try? await Task.sleep(for: .seconds(2))
            model.clearTransfer()
        }
        .alert("Couldn't Save", isPresented: Binding(get: { transferError != nil }, set: { if !$0 { model.clearTransfer() } })) {
            Button("OK") { model.clearTransfer() }
        } message: {
            Text(transferError ?? "")
        }
        .sensoryFeedback(.success, trigger: model.transfer) { _, new in new == .saved }
    }

    private var transferError: String? {
        if case .failed(let message) = model.transfer { message } else { nil }
    }

    /// Plays the current card's video, or stops playback when the card isn't a video.
    private func updateVideo() {
        if let current = model.deck.current, current.type == .video {
            videoPlayer.play(current, using: model.client)
        } else {
            videoPlayer.stop()
        }
        // A live photo's clip plays only from its pill, so a new card never starts one.
        livePhotoPlayer.stop()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.deck.assets.isEmpty:
            if let total = model.serverTotal, total > 0, model.syncedCount > 0 {
                // A sync that holds its pages back until the end, as on Android, shows how far it has got.
                ProgressView(value: Double(min(model.syncedCount, total)), total: Double(total)) {
                    Text("Loading album metadata… \(model.syncedCount, format: .number) / \(total, format: .number)")
                }
                .frame(width: 200)
            } else {
                ProgressView("Loading photos…")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load photos", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        default:
            if model.deck.isFinished {
                FinishedView(model: model) { isReviewing = true }
            } else if model.deck.assets.isEmpty {
                ContentUnavailableView("No photos here", systemImage: "photo.on.rectangle")
            } else {
                if let current = model.deck.current {
                    CardStack(
                        model: model,
                        motion: motion,
                        videoPlayer: videoPlayer,
                        livePhotoPlayer: livePhotoPlayer,
                        actions: cardActions(for: current),
                        drop: drop,
                        onDropBegan: loadDropAlbums,
                        onDrop: dropOnTarget,
                        onRate: { rate(current, stars: $0) }
                    )
                }
            }
        }
    }

    private func cardActions(for asset: Asset) -> SwipeCardActions {
        SwipeCardActions(
            layout: prefs.layout,
            rotate: { model.rotateCurrent() },
            openInImmich: { openInImmich(prefs.immichOpenMode) },
            openInImmichElsewhere: { openInImmich(prefs.immichOpenMode.other) },
            fullscreen: { if model.deck.current != nil { isFullscreen = true } },
            isMuted: videoPlayer.isMuted,
            toggleMute: { videoPlayer.toggleMute() },
            isDownloading: model.downloadingAssetID == asset.id,
            download: { Task { await model.downloadCurrent() } },
            shareItem: model.shareable(asset),
            isFullResolution: model.usesFullResolution(asset, keepWhileSwiping: prefs.keepFullResolution),
            toggleFullResolution: { model.toggleFullResolution(keepWhileSwiping: prefs.keepFullResolution) },
            sizeText: model.sortOrder == .sizeDescending || model.sortOrder == .sizeAscending
                ? (asset.fileSize ?? 0).formatted(.byteCount(style: .file))
                : nil
        )
    }

    /// The strip the card is dropped on: stars for a rating, albums otherwise.
    @ViewBuilder
    private var dropStrip: some View {
        if prefs.swipes.down == .rating {
            RatingDropStrip(state: drop, currentRating: model.deck.current?.starRating ?? 0)
        } else {
            AlbumDropStrip(state: drop, showsMore: !prefs.showAddToAlbumButton, cover: model.coverRequest(for:))
        }
    }

    /// The albums reload as a drag starts, so the one just used is first, as in the picker. Stars need no loading.
    private func loadDropAlbums() {
        guard prefs.swipes.down == .album else { return }
        Task {
            do {
                drop.albums = try await model.loadAlbums()
            } catch {
                AppLog.e("SwipeViewModel", "Error loading albums for drop strip", error)
            }
        }
    }

    /// A card was let go over a tile. The More tile opens the picker (the rating sheet for stars) and the card
    /// stays; an album or a star takes the photo, and the card goes (and is kept, as on Android). Returns
    /// whether it went.
    private func dropOnTarget(_ id: String) -> Bool {
        guard let asset = model.deck.current else { return false }
        if prefs.swipes.down == .rating {
            guard let stars = Int(id) else {
                ratingAsset = asset
                return false
            }
            rate(asset, stars: stars)
            return true
        }
        if id == DropStripState.moreID {
            albumAsset = asset
            return false
        }
        guard let album = drop.albums.first(where: { $0.id == id }) else { return false }
        Task {
            do {
                try await model.add(asset, to: album)
            } catch {
                failure = DropFailure(title: "Couldn't Add to Album", message: AddToAlbumSheet.failureMessage(for: error, albumName: album.albumName))
            }
        }
        return true
    }

    /// Sets the rating from a drop or from the stars in the details panel.
    private func rate(_ asset: Asset, stars: Int) {
        Task {
            do {
                try await model.rate(asset, stars: stars)
            } catch {
                failure = DropFailure(title: "Couldn't Set the Rating", message: RatingSheet.failureMessage(for: error))
            }
        }
    }

    /// Opens the current photo in the Immich app, or its web page. If the app isn't installed the web page opens instead.
    private func openInImmich(_ mode: ImmichOpenMode) {
        guard let asset = model.deck.current else { return }
        let web = model.immichURL(for: asset)
        switch mode {
        case .web:
            openURL(web)
        case .app:
            openURL(model.immichAppURL(for: asset)) { accepted in
                if !accepted { openURL(web) }
            }
        }
    }

    /// Warms the image cache for the next few cards, so swiping never waits on the network.
    private func prefetchUpcoming() {
        let requests = model.deck.upcoming(3).map(model.previewRequest(for:))
        Task { await ThumbnailLoader.shared.prefetch(requests, maxPixelSize: 1440) }
    }
}

/// What the alert after a failed drop or rating says.
private struct DropFailure {
    let title: LocalizedStringKey
    let message: String
}

// MARK: - Card stack and gesture

private struct CardStack: View {
    let model: DeckModel
    let motion: CardMotion
    let videoPlayer: DeckVideoPlayer
    let livePhotoPlayer: LivePhotoPlayer
    let actions: SwipeCardActions
    /// The strip of albums the card is dropped on, which the deck view draws.
    let drop: DropStripState
    /// A card has been pulled down far enough to be dropped, so the albums to drop it on can be loaded.
    let onDropBegan: () -> Void
    /// A card has been released over a tile. True if it was dropped on an album, and so is gone.
    let onDrop: (String) -> Bool
    /// A star was tapped in the details panel.
    let onRate: (Int) -> Void

    private let prefs = DeckPreferences()
    @State private var cardSize: CGSize = .zero
    /// Pulled far enough down with Album on swipe down, the card shrinks to a thumbnail to drop on an album.
    @State private var isDropping = false
    /// Where on the card the finger took hold of it, from the card's middle, which the thumbnail keeps under the finger.
    @State private var dropAnchor: CGPoint = .zero
    /// The middle of the card at rest, on screen.
    @State private var stackCenter: CGPoint = .zero
    /// Pinch zoom on the current card, like the Android app's ZoomableBox with resetOnRelease: 0.7×–10×,
    /// anchored under the fingers, a one-finger drag pans once zoomed in, and everything springs back on release.
    @State private var zoom: CGFloat = 1
    /// Where the zoomed photo has been moved to: pinch anchor, two-finger pan and one-finger pan together.
    @State private var zoomOffset: CGSize = .zero
    /// True from the moment a second finger lands until the swipe drag that was running has ended, so the
    /// drag can't turn the end of a zoom into a swipe.
    @State private var isZoomSession = false
    @State private var isDragging = false
    @State private var isTouching = false
    /// The card whose original is downloading. Keyed by card so one card's late update can't clear the next one's.
    @State private var loadingOriginalID: Asset.ID?
    /// The metadata panel, as on Android (`SwipeCard.kt`): 0 hidden, 1 fully open.
    @State private var panelProgress: CGFloat = 0
    /// How far the open panel is pulled past fully open; it stretches taller, up to 15% of its height.
    @State private var panelStretch: CGFloat = 0
    @State private var panelHeight: CGFloat = 0
    @State private var panelStartProgress: CGFloat = 0
    /// What the current drag moves, locked when it starts.
    @State private var dragMode = DragMode.undecided
    /// True while the card drag runs. SwiftUI resets it even when the system cancels the drag (say, the
    /// phone is locked mid-swipe), which never calls `onEnded`.
    @GestureState private var isDragActive = false
    /// Albums holding the current card, fetched the first time its panel opens.
    @State private var albums: (assetID: Asset.ID, names: [String])?
    /// Hidden by a long press until the next tap, and kept hidden from card to card, as on Android.
    @State private var controlsHidden = false
    /// From the long press until just after the finger lifts, so lifting it isn't also taken as a tap.
    @State private var isLongPressing = false

    private enum DragMode { case undecided, card, panel }

    private static let zoomRange: ClosedRange<CGFloat> = 0.7...10
    /// Past this the card counts as zoomed in: drags pan the photo instead of swiping the card.
    private static let zoomedThreshold: CGFloat = 1.05

    private var isZoomed: Bool { zoom > Self.zoomedThreshold }

    var body: some View {
        ZStack {
            if let next = motion.heldBackCard ?? model.deck.upcoming(1).first {
                // Grows and brightens as the top card is dragged aside, as on Android (`SwipeCard.kt`), so it
                // is already full size when the top card leaves and takes its place without a jump.
                SwipeCard(asset: next, imageRequest: model.previewRequest(for: next), rotation: model.rotation(of: next), actions: backCardActions(for: next), controlsHidden: controlsHidden)
                    .scaleEffect(0.85 + 0.15 * backCardProgress)
                    .opacity(0.6 + 0.4 * backCardProgress)
                    .allowsHitTesting(false)
            }

            if let current = model.deck.current {
                SwipeCard(
                    asset: current,
                    imageRequest: model.previewRequest(for: current),
                    rotation: model.rotation(of: current),
                    fullResolutionRequest: showsOriginal(current) ? model.originalRequest(for: current) : nil,
                    player: videoPlayer.assetID == current.id ? videoPlayer.player : livePhotoPlayer.assetID == current.id ? livePhotoPlayer.player : nil,
                    intent: intent,
                    intentStrength: intentStrength,
                    buttonLayout: controlActions.layout,
                    zoom: zoom,
                    pan: zoomOffset,
                    isLoadingOriginal: loadingBinding(for: current),
                    animates: current.isGIF
                )
                .id(current.id)
                .opacity(motion.fade)
                .scaleEffect(isDropping ? Self.dropScale : 1)
                .offset(cardOffset)
                .animation(.spring(duration: 0.3, bounce: 0.15), value: isDropping)
                .rotationEffect(tilt)
                .gesture(drag)
                .background {
                    CardPinchGesture(onBegan: beginPinch, onChanged: pinch, onEnded: endTouches)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    cardSize = $0
                    motion.cardHeight = $0.height
                }
                // A drag that finished normally has already cleared `isDragging` in `onEnded`.
                .onChange(of: isDragActive) { _, active in
                    if !active { cancelDrag() }
                }
                .onChange(of: current.id) {
                    resetZoom()
                    panelProgress = 0
                    panelStretch = 0
                    isLongPressing = false
                    endDrop()
                }
                .modifier(CardTaps(
                    allowsDoubleTap: prefs.doubleTapEnabled,
                    onTap: { x in
                        if isLongPressing {
                            return
                        } else if controlsHidden {
                            // The tap only brings the controls back.
                            controlsHidden = false
                        } else if panelProgress > 0.1 {
                            setPanel(open: false)
                        } else if let edge = CardTapRules.edge(atX: x, width: cardSize.width, tapToSwipe: prefs.tapToSwipe) {
                            // Videos only pause from their time pill, as on Android.
                            motion.fly(prefs.swipes.action(toward: edge), toward: edge, in: model)
                        }
                    },
                    onDoubleTap: {
                        switch prefs.doubleTapAction {
                        case .fullscreen: actions.fullscreen()
                        case .favorite: motion.toggleFavorite(in: model, autoAdvance: prefs.autoNextOnFavorite)
                        }
                    }
                ))
                // Held for 500 ms without moving, as on Android; a drag cancels it.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard case .second(true, _) = value, !isLongPressing else { return }
                            isLongPressing = true
                            controlsHidden = true
                        }
                        .onEnded { _ in
                            Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                isLongPressing = false
                            }
                        }
                )
                .sensoryFeedback(trigger: controlsHidden) { _, hidden in hidden ? .impact : .selection }
                .accessibilityAction(named: Text(prefs.swipes.right.title)) { motion.fly(prefs.swipes.right, toward: .trailing, in: model) }
                .accessibilityAction(named: Text(prefs.swipes.left.title)) { motion.fly(prefs.swipes.left, toward: .leading, in: model) }
                .accessibilityAction(named: "Image details") { setPanel(open: true) }
                .accessibilityActions {
                    if videoPlayer.assetID == current.id {
                        Button(videoPlayer.isPlaying ? "Pause" : "Play") { videoPlayer.togglePlayPause() }
                    }
                    // Dropping the card on an album or a star takes a drag, so VoiceOver opens the picker instead.
                    if prefs.swipes.down.isDropTarget {
                        Button(prefs.swipes.down.title) { _ = onDrop(DropStripState.moreID) }
                    }
                }
                .transition(.identity)

                // Beside the card, not inside it, so the card's gestures can't swallow button taps.
                // It follows the card's motion so the buttons travel with it.
                // An overlay on the card's own size, so a long row of corner buttons can't widen the screen.
                Color.clear
                    .overlay {
                        // Gone while the card is a thumbnail over the strip: it follows the card but doesn't shrink.
                        CardControls(asset: current, actions: controlActions)
                            .opacity(controlsHidden || isDropping ? 0 : 1)
                            .allowsHitTesting(!controlsHidden)
                            .animation(.easeInOut(duration: 0.3), value: controlsHidden || isDropping)
                    }
                    .id(current.id)
                    .opacity(motion.fade)
                    .offset(motion.offset)
                    .rotationEffect(tilt)
                    .transition(.identity)

                // Over the controls, as on Android, and dragged by the same gesture as the card.
                MetadataPanel(
                    asset: current,
                    albumNames: albums?.assetID == current.id ? albums?.names : nil,
                    showsAlbums: model.source != .orphans,
                    onRate: onRate,
                    onClose: { setPanel(open: false) },
                    saveDescription: { try await model.saveDescription($0, for: current.id) }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                .scaleEffect(x: 1, y: 1 + (panelHeight > 0 ? panelStretch / panelHeight : 0), anchor: .bottom)
                .offset(y: panelHeight * (1 - panelProgress))
                .gesture(drag)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipShape(.rect(cornerRadius: 28))
                .allowsHitTesting(panelProgress > 0)
                .id(current.id)
                .opacity(motion.fade)
                .offset(motion.offset)
                .rotationEffect(tilt)
                .transition(.identity)
                .task(id: panelProgress > 0 ? current.id : nil) {
                    guard panelProgress > 0, model.source != .orphans, albums?.assetID != current.id else { return }
                    let names = await model.albumNames(containing: current)
                    if !Task.isCancelled { albums = (current.id, names) }
                }
            }
        }
        .onGeometryChange(for: CGPoint.self) { CGPoint(x: $0.frame(in: .global).midX, y: $0.frame(in: .global).midY) } action: { stackCenter = $0 }
    }

    /// Springs the panel fully open or shut.
    private func setPanel(open: Bool) {
        withAnimation(.spring(duration: 0.35)) { panelProgress = open ? 1 : 0 }
        withAnimation(.spring(duration: 0.4, bounce: 0.4)) { panelStretch = 0 }
    }

    /// Follows the finger. Past fully open the panel stretches with growing resistance, up to 15% of its height.
    private func dragPanel(by dy: CGFloat) {
        guard panelHeight > 0 else { return }
        let shown = panelStartProgress * panelHeight - dy
        panelProgress = min(max(shown / panelHeight, 0), 1)
        let maxStretch = panelHeight * 0.15
        let over = max(0, shown - panelHeight)
        // Android adds half of each step, scaled by how much stretch is left; this is that, summed.
        panelStretch = maxStretch * (1 - exp(-0.5 * over / maxStretch))
    }

    /// Opens on a flick up, shuts on a flick down, else whichever is nearer (open from 40%), as on Android.
    /// 500 px/s on Android, converted the same way as the card's thresholds.
    private func releasePanel(velocity vy: CGFloat) {
        let open = vy < -250 ? true : vy > 250 ? false : panelProgress >= 0.4
        setPanel(open: open)
    }

    private func loadingBinding(for asset: Asset) -> Binding<Bool> {
        Binding(
            get: { loadingOriginalID == asset.id },
            set: { isLoading in
                if isLoading {
                    loadingOriginalID = asset.id
                } else if loadingOriginalID == asset.id {
                    loadingOriginalID = nil
                }
            }
        )
    }

    /// The card's actions, told whether the original is still downloading.
    private var controlActions: SwipeCardActions {
        var actions = actions
        actions.isLoadingFullResolution = loadingOriginalID == model.deck.current?.id
        actions.video = videoPlayer.assetID == model.deck.current?.id ? videoPlayer : nil
        actions.showsLivePill = true
        actions.toggleLivePhoto = {
            if let current = model.deck.current { livePhotoPlayer.toggle(current, using: model.client) }
        }
        actions.toggleDetails = { setPanel(open: panelProgress <= 0.5) }
        return actions
    }

    /// The buttons drawn on the card behind, so they are already in place when it comes to the front.
    /// They're only a picture (the back card takes no touches), but show that card's own state.
    private func backCardActions(for asset: Asset) -> SwipeCardActions {
        var actions = actions
        actions.isDownloading = false
        actions.isLoadingFullResolution = false
        actions.isFullResolution = model.usesFullResolution(asset, keepWhileSwiping: prefs.keepFullResolution)
        actions.shareItem = model.shareable(asset)
        // Not playing, so no time pill; and no size pill, as on Android.
        actions.video = nil
        actions.sizeText = nil
        return actions
    }

    /// The top card's lean while dragged: a degree per 25 points on a phone. A wider card (iPad) leans per
    /// share of its width instead, so it slides sideways rather than swinging its far larger corners around.
    private var tilt: Angle {
        .degrees(motion.offset.width / max(25, cardSize.width / 15))
    }

    /// How small the card shrinks to while it is dropped on the strip (Android's `DropScale`).
    private static let dropScale: CGFloat = 0.4
    /// Pulled this far down, the card shrinks and the strip rises; back above the lower one, it goes away again.
    /// Android's 120 px and 60 px, converted as the card's other distances are.
    private static let dropStart: CGFloat = 48
    private static let dropEnd: CGFloat = 24

    /// Where the card is drawn: where it was dragged to, and while it is a thumbnail, the shift that keeps it
    /// under the finger.
    private var cardOffset: CGSize {
        let shift = dropShift
        return CGSize(width: motion.offset.width + shift.width, height: motion.offset.height + shift.height)
    }

    /// Shrinking about the middle, and the lean, would carry the point the finger grabbed away from the finger.
    /// Moving the card by the gap keeps the thumbnail under it.
    private var dropShift: CGSize {
        guard isDropping else { return .zero }
        return DropStripState.thumbnailShift(anchor: dropAnchor, drag: motion.offset, angle: tilt.radians, scale: Self.dropScale)
    }

    /// 0 at rest, 1 once the top card is 320 points aside (Android's 800 px). A card pulled down to swipe, not
    /// to undo or drop, or up to swipe, not to show details, brings the next one forward the same way.
    private var backCardProgress: CGFloat {
        let offset = motion.offset
        let swipes = prefs.swipes
        let pulledDown = swipes.down != .undo && !swipes.down.isDropTarget && !motion.isRestoring && offset.height > abs(offset.width)
        let pulledUp = swipes.up != .details && -offset.height > abs(offset.width)
        return min(1, abs(pulledDown || pulledUp ? offset.height : offset.width) / 320)
    }

    /// The original is drawn over the preview when asked for. GIFs already load as originals.
    private func showsOriginal(_ asset: Asset) -> Bool {
        !asset.isGIF && model.usesFullResolution(asset, keepWhileSwiping: prefs.keepFullResolution)
    }

    private var intent: SwipeIntent? {
        if motion.isRestoring { return nil }
        let offset = motion.offset
        let swipes = prefs.swipes
        if offset.height > abs(offset.width), offset.height > 20, model.deck.canUndo || swipes.down != .undo {
            return SwipeIntent(action: swipes.down, edge: .bottom)
        }
        if swipes.up != .details, -offset.height > abs(offset.width), offset.height < -20 {
            return SwipeIntent(action: swipes.up, edge: .top)
        }
        if offset.width > 20 { return SwipeIntent(action: swipes.right, edge: .trailing) }
        if offset.width < -20 { return SwipeIntent(action: swipes.left, edge: .leading) }
        return nil
    }

    private var intentStrength: Double {
        let distance = switch intent?.edge {
        case .bottom: motion.offset.height
        case .top: -motion.offset.height
        default: abs(motion.offset.width)
        }
        return min(1, Double(distance / CardMotion.distanceThreshold))
    }

    private var drag: some Gesture {
        // Measured on screen: the panel carries this gesture inside the card's offset and tilt, so in its own
        // space each move of the card would change the translation and the card would jitter.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($isDragActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !motion.isFlying else { return }
                isDragging = true
                // Once a second finger has landed the fingers move the photo, not the card.
                if isZoomSession { return }
                let (dx, dy) = (value.translation.width, value.translation.height)
                let swipes = prefs.swipes
                if dragMode == .undecided {
                    // Any vertical move while the panel is already open works the panel, and so does a mostly
                    // upward one, unless swiping up is an action of its own.
                    panelStartProgress = panelProgress
                    let isPanel = (panelStartProgress > 0.1 && abs(dy) > 5) || (abs(dy) > abs(dx) && dy < 0 && swipes.up == .details)
                    dragMode = isPanel ? .panel : .card
                }
                if dragMode == .panel {
                    dragPanel(by: dy)
                    return
                }
                // Cards travel downwards, and upwards when swiping up is an action. With nothing to undo the card
                // resists a pull down instead of following the finger, unless pulling down is a swipe of its own.
                let height: CGFloat
                if swipes.up != .details, dy < 0 {
                    height = dy
                } else {
                    let down = max(0, dy)
                    height = model.deck.canUndo || swipes.down != .undo ? down : down * 0.2
                }
                motion.offset = CGSize(width: dx, height: height)
                if swipes.down.isDropTarget { updateDrop(value) }
            }
            .onEnded { value in
                isDragging = false
                let mode = dragMode
                dragMode = .undecided
                if isZoomSession {
                    // The last finger may already be up; if so the zoom session ends with this drag.
                    if !isTouching { isZoomSession = false }
                    return
                }
                if mode == .panel {
                    releasePanel(velocity: value.velocity.height)
                } else if isDropping {
                    finishDrop()
                } else {
                    motion.release(translation: value.translation, velocity: value.velocity, swipes: prefs.swipes, in: model)
                }
            }
    }

    /// Pulled far enough down, the card shrinks to a thumbnail and the strip rises under it. The finger is then
    /// over a tile, or not, which the strip works out from where it is.
    private func updateDrop(_ value: DragGesture.Value) {
        let (dx, dy) = (value.translation.width, value.translation.height)
        if !isDropping, dy > Self.dropStart, dy > abs(dx) {
            isDropping = true
            dropAnchor = CGPoint(x: value.startLocation.x - stackCenter.x, y: value.startLocation.y - stackCenter.y)
            onDropBegan()
        } else if isDropping, dy < Self.dropEnd {
            endDrop()
        }
        if isDropping { drop.move(to: value.location) }
    }

    /// The card goes down with the strip if it was let go over a tile that took it, and springs back if not.
    private func finishDrop() {
        let target = drop.hoveredID
        endDrop()
        if let target, onDrop(target) {
            motion.fly(.keep, toward: .bottom, in: model)
        } else {
            withAnimation(.bouncy) { motion.offset = .zero }
        }
    }

    private func endDrop() {
        guard isDropping else { return }
        isDropping = false
        drop.end()
    }

    /// The system cancelled the drag before `onEnded`, as Android's `onDragCancel`: the panel settles to the
    /// nearer end and the card springs back to the middle.
    private func cancelDrag() {
        guard isDragging else { return }
        isDragging = false
        let mode = dragMode
        dragMode = .undecided
        if isZoomSession {
            if !isTouching { isZoomSession = false }
            return
        }
        if mode == .panel {
            releasePanel(velocity: 0)
        } else {
            endDrop()
            withAnimation(.bouncy) { motion.offset = .zero }
        }
    }

    private func beginPinch() {
        guard !motion.isFlying else { return }
        isZoomSession = true
        isTouching = true
        // A swipe that was already under way gives way to the pinch.
        motion.offset = .zero
    }

    /// Same maths as the Android ZoomableBox: with two fingers, zoom 0.7×–10× about their midpoint and
    /// follow the midpoint; with one finger, pan once zoomed in past 1.05×.
    private func pinch(_ step: PinchStep) {
        guard isZoomSession else { return }
        if step.touchCount >= 2 {
            let oldZoom = zoom
            let newZoom = min(max(oldZoom * step.zoomChange, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            let change = newZoom / oldZoom
            zoom = newZoom
            zoomOffset = CGSize(
                width: (step.centroid.x - step.size.width / 2) * (1 - change) + zoomOffset.width * change + step.pan.width,
                height: (step.centroid.y - step.size.height / 2) * (1 - change) + zoomOffset.height * change + step.pan.height
            )
        } else if isZoomed {
            zoomOffset = CGSize(width: zoomOffset.width + step.pan.width, height: zoomOffset.height + step.pan.height)
        }
    }

    /// The last finger is up: the photo springs back to where it started, as in the Android app.
    private func endTouches() {
        isTouching = false
        guard isZoomSession else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) { resetZoom() }
        // If the swipe drag is still winding down, it clears the session itself.
        if !isDragging { isZoomSession = false }
    }

    private func resetZoom() {
        zoom = 1
        zoomOffset = .zero
    }
}

/// Single and double taps on the card. A single tap waits for a possible second one only when double
/// tap is on, so tap-to-swipe stays instant otherwise.
private struct CardTaps: ViewModifier {
    let allowsDoubleTap: Bool
    let onTap: (CGFloat) -> Void
    let onDoubleTap: () -> Void

    func body(content: Content) -> some View {
        if allowsDoubleTap {
            content.gesture(
                SpatialTapGesture(count: 2).onEnded { _ in onDoubleTap() }
                    .exclusively(before: SpatialTapGesture().onEnded { onTap($0.location.x) })
            )
        } else {
            content.gesture(SpatialTapGesture().onEnded { onTap($0.location.x) })
        }
    }
}

/// Card position and the fly-off animation, shared by the card stack (gestures) and the buttons.
@Observable
final class CardMotion {
    var offset: CGSize = .zero
    private(set) var isFlying = false
    /// True while an undone card is sliding back in, so the "Undo" stamp stays off it.
    private(set) var isRestoring = false
    /// The current card's opacity. Only the undo animation lowers it, so the card can fade over a short slide.
    private(set) var fade: Double = 1
    /// The card shown behind the current one during an undo. Undoing changes which card is next, but the
    /// one behind stays as it was until the restored card has settled over it.
    private(set) var heldBackCard: Asset?

    /// The card's height, so a swipe up or down can carry it clear of the screen.
    var cardHeight: CGFloat = 0

    /// Distance and speed past which a drag commits (spec §3.2, Android pixels converted to points).
    static let distanceThreshold: CGFloat = 100
    static let velocityThreshold: CGFloat = 500

    /// Favourites the current photo. With auto-advance on, favouriting also keeps it and moves on.
    func toggleFavorite(in model: DeckModel, autoAdvance: Bool) {
        guard let asset = model.deck.current else { return }
        model.toggleFavoriteForCurrent()
        if autoAdvance, model.isFavorite(asset) { fly(.keep, toward: .trailing, in: model) }
    }

    /// Decides what a released drag means, as on Android (`SwipeCard.kt`): a pull down or up runs that
    /// direction's action (a pull down undoes by default), a swipe right or left runs that side's, and
    /// anything shorter snaps back.
    func release(translation: CGSize, velocity: CGSize, swipes: SwipeMapping, in model: DeckModel) {
        guard !isFlying else { return }
        let (x, y) = (translation.width, translation.height)
        let (vx, vy) = (velocity.width, velocity.height)
        let isPullDown = y > abs(x) && (y > Self.distanceThreshold || vy > Self.velocityThreshold)
        let isPullUp = swipes.up != .details && -y > abs(x) && (y < -Self.distanceThreshold || vy < -Self.velocityThreshold)

        if isPullDown, swipes.down.isDropTarget {
            // A pull that got far enough has raised the strip and is released by the card; this one never did,
            // so there is nothing to drop on, and the card goes back, as on Android.
            withAnimation(.bouncy) { offset = .zero }
        } else if isPullDown, swipes.down != .undo {
            fly(swipes.down, toward: .bottom, in: model)
        } else if isPullDown, model.deck.canUndo {
            undo(in: model)
        } else if isPullUp {
            fly(swipes.up, toward: .top, in: model)
        } else if x > Self.distanceThreshold || (vx > Self.velocityThreshold && x > -20) {
            fly(swipes.right, toward: .trailing, in: model)
        } else if x < -Self.distanceThreshold || (vx < -Self.velocityThreshold && x < 20) {
            fly(swipes.left, toward: .leading, in: model)
        } else {
            withAnimation(.bouncy) { offset = .zero }
        }
    }

    /// Undo by pulling down: the card slips a short way down while fading out, then the previous card
    /// rises back into place from the same spot, fading in. A short slide keeps it brief; Android's
    /// full-screen slide (`SwipeCard.kt`) felt like too much travel here.
    private func undo(in model: DeckModel) {
        let travel: CGFloat = 260
        isFlying = true
        heldBackCard = model.deck.upcoming(1).first
        withAnimation(.easeIn(duration: 0.14)) {
            offset = CGSize(width: 0, height: travel)
            fade = 0
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.undo()
                self.isRestoring = true
                self.offset = CGSize(width: 0, height: travel)
            }
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                self.offset = .zero
                self.fade = 1
            } completion: {
                self.isRestoring = false
                self.isFlying = false
                self.heldBackCard = nil
            }
        }
    }

    /// Throws the card off screen towards the edge, then carries out the action and brings the next card in
    /// place. Undo pulls the previous card back instead, and Details, Album and Rating only settle the card.
    func fly(_ action: SwipeAction, toward edge: Edge, in model: DeckModel) {
        guard !isFlying, let assetID = model.deck.current?.id else { return }
        switch action {
        case .undo where model.deck.canUndo:
            undo(in: model)
            return
        case .undo, .details, .album, .rating:
            withAnimation(.bouncy) { offset = .zero }
            return
        default:
            break
        }
        isFlying = true
        // Clear of the screen above or below even on an iPad, where the card is far taller than 900 points.
        let vertical = max(900, cardHeight + 300)
        let target: CGSize = switch edge {
        case .trailing: CGSize(width: 700, height: offset.height)
        case .leading: CGSize(width: -700, height: offset.height)
        case .top: CGSize(width: offset.width, height: -vertical)
        case .bottom: CGSize(width: offset.width, height: vertical)
        }
        // Starts fast and slows, so a flick carries straight on instead of stalling as it leaves the finger.
        withAnimation(.easeOut(duration: 0.2)) {
            offset = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.swipe(action, on: assetID)
                self.offset = .zero
            }
            self.isFlying = false
        }
    }
}

// MARK: - Header

/// A progress ring with "N left", the deleted and kept counts, and the list icon that opens the
/// review screen, all in one pill, as on Android.
private struct ProgressPill: View {
    let remaining: Int
    let deleted: Int
    let kept: Int
    let progress: Double
    let isLoadingMore: Bool
    let onReview: () -> Void

    var body: some View {
        // The whole pill is the button, so a tap anywhere on it opens the review screen.
        Button(action: onReview) { content }
            .buttonStyle(.plain)
            .accessibilityLabel("Review Decisions")
            .accessibilityValue(Text("\(remaining, format: .number) left, \(deleted, format: .number) deleted, \(kept, format: .number) kept"))
    }

    private var content: some View {
        // Sizes follow Android: a 44 pt pill, 13 pt "left" text and 12 pt counts, so large counts still fit.
        HStack(spacing: 0) {
            // While more photos load, a spinner stands in for the ring.
            HStack(spacing: 8) {
                Group {
                    if isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ProgressRing(progress: progress)
                    }
                }
                .frame(width: 22, height: 22)

                Text("\(remaining) left")
                    .font(.footnote.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            // Like Android's weight(1f): this side takes the spare room and gives way first.
            .frame(maxWidth: .infinity, alignment: .leading)

            Count(value: deleted, systemImage: "trash.fill", color: .red)
                .padding(.trailing, 10)
            Count(value: kept, systemImage: "checkmark.circle.fill", color: .green)
                .padding(.trailing, 12)

            Image(systemName: "list.bullet")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: remaining)
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 44)
        .contentShape(.capsule)
        .glassEffect(.regular, in: .capsule)
    }

    /// A determinate circular progress indicator. SwiftUI's circular `ProgressView` only spins on
    /// iOS, so this is drawn by hand.
    private struct ProgressRing: View {
        let progress: Double

        var body: some View {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(1.5)
            .animation(.smooth, value: progress)
        }
    }

    private struct Count: View {
        let value: Int
        let systemImage: String
        let color: Color

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(color)
                Text(value, format: .number)
                    .font(.caption.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .fixedSize()
            .animation(.snappy, value: value)
        }
    }
}

// MARK: - Bottom bar

private struct DeckBottomBar: View {
    let model: DeckModel
    let motion: CardMotion
    let onAlbum: () -> Void

    private let prefs = DeckPreferences()
    @State private var barWidth: CGFloat = 0
    @State private var widestTitle: CGFloat = 0

    /// The middle buttons that are switched on, in the saved order.
    private var shownButtons: [SortingBarButton] {
        SortingBarButton.order(from: prefs.savedToolbarButtonOrder).filter { button in
            switch button {
            case .archive: prefs.showArchiveButton
            case .favorite: prefs.showFavoriteButton
            case .album: prefs.showAddToAlbumButton
            case .lock: prefs.showLockButton
            }
        }
    }

    private var titles: [LocalizedStringKey] {
        let ends: [LocalizedStringKey] = prefs.showSwipeButtons ? [prefs.swipes.left.title, prefs.swipes.right.title] : []
        return ends + ["Undo", "Sort"] + shownButtons.map(\.title)
    }

    /// As on Android: labels show when the setting is on and the widest one, plus 16 pt, fits in a button.
    private var showsTitles: Bool {
        // Delete and Keep sit in their own capsules, so only the buttons in the middle one share its width.
        let buttonWidth = barWidth / CGFloat(2 + shownButtons.count)
        return prefs.showToolbarLabels && widestTitle > 0 && widestTitle + 16 <= buttonWidth
    }

    var body: some View {
        let current = model.deck.current
        let showsTitles = showsTitles
        let swipes = prefs.swipes
        HStack(spacing: 8) {
            // The end buttons look like, and do, what swiping that way does (Android's `SwipeFab`).
            if prefs.showSwipeButtons {
                BarButton(title: swipes.left.title, systemImage: swipes.left.systemImage, tint: Self.endTint(swipes.left), showsTitle: showsTitles) {
                    motion.fly(swipes.left, toward: .leading, in: model)
                }
                    .disabled(current == nil)
                    .frame(width: 64)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
            }
            HStack(spacing: 0) {
                BarButton(title: "Undo", systemImage: "arrow.uturn.backward", showsTitle: showsTitles) { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.deck.canUndo)
                ForEach(shownButtons, id: \.self) { button in
                    middleButton(button, current: current, showsTitle: showsTitles)
                        .disabled(current == nil)
                }
                SortMenu(model: model, showsTitle: showsTitles)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: .capsule)
            if prefs.showSwipeButtons {
                BarButton(title: swipes.right.title, systemImage: swipes.right.systemImage, tint: Self.endTint(swipes.right), showsTitle: showsTitles) {
                    motion.fly(swipes.right, toward: .trailing, in: model)
                }
                    .disabled(current == nil)
                    .frame(width: 64)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .background {
            // Every title at its natural width, to find the widest one.
            ZStack {
                ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                    Text(title).font(.caption).fixedSize()
                }
            }
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widestTitle = $0 }
        }
        .animation(.snappy, value: showsTitles)
        // Arrow keys work whichever control has focus.
        .background {
            Group {
                Button(swipes.left.title) { motion.fly(swipes.left, toward: .leading, in: model) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button(swipes.right.title) { motion.fly(swipes.right, toward: .trailing, in: model) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// Keep green and Delete red, as before; the other actions take the bar's usual colour.
    private static func endTint(_ action: SwipeAction) -> Color? {
        switch action {
        case .keep: .green
        case .delete: .red
        default: nil
        }
    }

    @ViewBuilder
    private func middleButton(_ button: SortingBarButton, current: Asset?, showsTitle: Bool) -> some View {
        switch button {
        case .archive:
            BarButton(title: button.title, systemImage: button.systemImage, showsTitle: showsTitle) { motion.fly(.archive, toward: .top, in: model) }
        case .lock:
            BarButton(title: button.title, systemImage: button.systemImage, showsTitle: showsTitle) { motion.fly(.lock, toward: .top, in: model) }
        case .favorite:
            let isFavorite = current.map(model.isFavorite) ?? false
            BarButton(title: button.title, systemImage: isFavorite ? "heart.fill" : "heart", tint: isFavorite ? .red : nil, showsTitle: showsTitle) {
                motion.toggleFavorite(in: model, autoAdvance: prefs.autoNextOnFavorite)
            }
        case .album:
            BarButton(title: button.title, systemImage: button.systemImage, showsTitle: showsTitle, action: onAlbum)
        }
    }
}

private struct BarButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color?
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BarLabel(title: title, systemImage: systemImage, tint: tint, showsTitle: showsTitle)
        }
        .buttonStyle(.plain)
    }
}

private struct BarLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color?
    var showsTitle = true

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint ?? .primary)
                .frame(height: 28)
            if showsTitle {
                Text(title)
                    .font(.caption)
            }
        }
        // Android's tiles are 8 pt shorter without labels (56 and 48).
        .frame(maxWidth: .infinity, minHeight: showsTitle ? 52 : 44)
        .contentShape(.rect)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
    }
}

/// The sort sheet. It keeps Android's behaviour (`SortOrderPopupMenu.kt`): it stays open while you pick
/// and the choice is applied when you dismiss it. Date / Size / Type switches which options are listed.
private struct SortMenu: View {
    let model: DeckModel
    var showsTitle = true

    @State private var isShowing = false
    /// What the sheet currently shows as picked. Only handed to the deck when the sheet closes.
    @State private var picked = DeckSortOrder.default

    var body: some View {
        Button {
            picked = model.sortOrder
            isShowing = true
        } label: {
            // Shows the chosen order's icon, as on Android (`SwipeActionBar.kt`).
            BarLabel(title: "Sort", systemImage: model.sortOrder.systemImage, showsTitle: showsTitle)
        }
        .buttonStyle(.plain)
        .disabled(!model.source.supportsSorting)
        .sheet(isPresented: $isShowing) {
            SortSheet(picked: $picked)
        }
        // Every close applies the pick, as Android's `handleDismiss` does: picking the order already in use
        // takes the deck back to its first undecided photo.
        .onChange(of: isShowing) { _, showing in
            guard !showing else { return }
            let order = picked
            Task { await model.setSortOrder(order) }
        }
    }
}

private struct SortSheet: View {
    @Binding var picked: DeckSortOrder

    private static let compact = PresentationDetent.height(330)
    private static let tall = PresentationDetent.height(520)
    @State private var detent = Self.compact

    var body: some View {
        VStack(spacing: 0) {
            // Switching category starts from that category's default order, as on Android.
            Picker("Sort By", selection: Binding(
                get: { picked.attribute },
                set: { attribute in
                    withAnimation(.smooth(duration: 0.4)) {
                        picked = attribute.defaultOrder
                        detent = attribute == .type ? Self.tall : Self.compact
                    }
                }
            )) {
                ForEach(DeckSortOrder.Attribute.allCases, id: \.self) { attribute in
                    Text(attribute.title).tag(attribute)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 4)

            // The options fade between categories while the sheet grows or shrinks to fit them.
            options
                .id(picked.attribute)
                .transition(.opacity)
        }
        .animation(.smooth(duration: 0.4), value: picked.attribute)
        .presentationDetents([Self.compact, Self.tall], selection: $detent)
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: picked)
        .onAppear { detent = picked.attribute == .type ? Self.tall : Self.compact }
    }

    private var options: some View {
        List {
            if picked.attribute == .type {
                Section("Show First") {
                    ForEach(DeckSortOrder.TypeFirst.allCases, id: \.self) { kind in
                        SortRow(
                            title: kind.title,
                            systemImage: kind == .videos ? "video" : "photo",
                            isSelected: picked.typeFirst == kind
                        ) { picked = picked.with(typeFirst: kind) }
                    }
                }
            }

            Section(picked.attribute == .type ? "Then" : "Order") {
                ForEach(picked.availableDirections, id: \.self) { direction in
                    SortRow(
                        title: direction.title(for: picked.attribute),
                        systemImage: direction.systemImage,
                        isSelected: picked.direction == direction
                    ) { picked = picked.with(direction: direction) }
                }
            }
        }
    }
}

private struct SortRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label { Text(title) } icon: { Image(systemName: systemImage) }
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Finished

private struct FinishedView: View {
    let model: DeckModel
    let onReview: () -> Void

    var body: some View {
        let freed = model.deck.bytes(of: .delete)
        ContentUnavailableView {
            Label("All sorted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } description: {
            VStack(spacing: 4) {
                Text("Kept \(model.keptCount, format: .number) · Deleted \(model.deletedCount, format: .number)")
                if freed > 0 {
                    Text("Deleting frees \(freed.formatted(.byteCount(style: .file)))")
                }
                if model.plan.pendingCount > 0 {
                    Text("^[\(model.plan.pendingCount) change](inflect: true) waiting to be applied.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Everything is applied to your server.")
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button("Review Decisions", action: onReview)
                .buttonStyle(.glassProminent)
        }
    }
}

#if os(iOS)
/// Turns off the navigation stack's swipe-to-go-back gestures (from the screen edge, and iOS 26's from
/// anywhere) while the swipe screen is showing, and turns them back on when it goes away.
private struct BackSwipeBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> BlockerView {
        let view = BlockerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BlockerView, context: Context) {}

    final class BlockerView: UIView {
        private weak var navigationController: UINavigationController?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                navigationController = Self.navigationController(from: self)
                setBackSwipe(enabled: false)
            } else {
                setBackSwipe(enabled: true)
            }
        }

        private func setBackSwipe(enabled: Bool) {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = enabled
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = enabled
        }

        private static func navigationController(from view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController, let navigation = controller.navigationController {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }
}
#endif
