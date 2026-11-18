import SwiftUI

/// One duplicate group, as on Android (`DuplicateClusterCard.kt`): how many of its assets are decided,
/// a fullscreen button, the assets side by side (or in a sideways row past two), and Keep all / Delete all.
///
/// Drawn in the iOS style rather than Android's Material card: a plain rounded card with no border, the
/// count as a title and subtitle, and glass buttons. Android turns the card's border green once every
/// asset has a choice; here the subtitle turns into a green "Sorted".
struct DuplicateClusterCard: View {
    let cluster: DuplicatesModel.Cluster
    let model: DuplicatesModel
    /// Width inside the card's padding, to size the tiles of a sideways row.
    let contentWidth: CGFloat
    /// The asset being pinched, drawn by the screen's overlay instead, so its tile is hidden.
    let peekingAssetID: String?
    let onPeek: (DuplicatePeek) -> Void
    /// Opens the fullscreen viewer on this asset index.
    let onOpen: (Int) -> Void

    var body: some View {
        let decided = cluster.assets.count { model.decision(for: $0) != nil }
        let isSorted = decided == cluster.assets.count

        VStack(spacing: 14) {
            header(decided: decided, isSorted: isSorted)
            assets
            buttons
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 28, style: .continuous))
    }

    /// "3 items" over "1 of 3 sorted" (or a green "Sorted"), and the fullscreen button. Android's Best
    /// Shot "Analyze at full size" button is not ported yet.
    private func header(decided: Int, isSorted: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(cluster.assets.count) item](inflect: true)")
                    .font(.headline)
                Group {
                    if isSorted {
                        Label("Sorted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("\(decided, format: .number) of \(cluster.assets.count, format: .number) sorted")
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
            }
            .animation(.snappy, value: decided)
            .accessibilityElement(children: .combine)

            Spacer()

            Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") { onOpen(0) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        }
    }

    @ViewBuilder
    private var assets: some View {
        if cluster.assets.count <= 2 {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(cluster.assets.enumerated()), id: \.element.id) { index, asset in
                    tile(asset, index: index)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            // About two tiles and a peek of the third, never narrower than 135 pt.
            let tileWidth = max((contentWidth - 8) / 2.15, 135)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(Array(cluster.assets.enumerated()), id: \.element.id) { index, asset in
                        tile(asset, index: index)
                            .frame(width: tileWidth)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // A pinch owns the fingers, as on Android, so the row doesn't scroll under it.
            .scrollDisabled(peekingAssetID != nil)
        }
    }

    private func tile(_ asset: Asset, index: Int) -> some View {
        DuplicateAssetTile(
            asset: asset,
            decision: model.decision(for: asset),
            isFavorite: model.isFavorite(asset),
            request: model.client.authorizedRequest(for: .preview(assetID: asset.id)),
            isPeeking: peekingAssetID == asset.id,
            onToggle: { model.toggle(asset) },
            onOpen: { onOpen(index) },
            onPeek: onPeek
        )
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            DuplicateGroupButton(
                title: "Keep all",
                systemImage: "checkmark.circle.fill",
                color: .green,
                isOn: !cluster.assets.isEmpty && cluster.assets.allSatisfy { model.decision(for: $0) == .keep }
            ) {
                model.setCluster(cluster, to: .keep)
            }
            DuplicateGroupButton(
                title: "Delete all",
                systemImage: "trash.fill",
                color: .red,
                isOn: !cluster.assets.isEmpty && cluster.assets.allSatisfy { model.decision(for: $0) == .delete }
            ) {
                model.setCluster(cluster, to: .delete)
            }
        }
    }
}

// MARK: - Tile

/// One asset of a group: its preview with the favorite, video and choice badges, then its size and
/// choice underneath. Tap cycles the choice, a long press opens the fullscreen viewer, and a pinch lifts
/// the picture out of the card for a closer look until the fingers lift (`DuplicateAssetItem.kt`).
///
/// The pinch follows Android's maths: two fingers zoom 1–4× about the picture's centre, the fingers'
/// midpoint moves it (up to 100 pt × zoom each way, Android's 250 px), and once a pinch has started one
/// remaining finger keeps moving it. SwiftUI's `MagnifyGesture` can't report the midpoint, so the fingers
/// are followed with `CardPinchGesture`, as on the swipe card.
private struct DuplicateAssetTile: View {
    let asset: Asset
    let decision: SwipeDecision?
    let isFavorite: Bool
    let request: URLRequest
    let isPeeking: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onPeek: (DuplicatePeek) -> Void

    @State private var frame: CGRect = .zero
    @State private var pinchScale: CGFloat = 1
    @State private var pinchOffset: CGSize = .zero
    /// From the second finger landing until just after the last one lifts, so the tap and long press
    /// that finish with a pinch don't change the choice or open the viewer.
    @State private var isPinching = false

    var body: some View {
        VStack(spacing: 4) {
            DuplicateTilePicture(asset: asset, decision: decision, isFavorite: isFavorite, request: request)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                .opacity(isPeeking ? 0 : 1)
                .contentShape(.rect(cornerRadius: 16, style: .continuous))
                .onTapGesture { if !isPinching { onToggle() } }
                .onLongPressGesture { if !isPinching { onOpen() } }
                .background {
                    CardPinchGesture(onBegan: beginPinch, onChanged: pinch, onEnded: endPinch)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(asset.type == .video ? "Video" : "Photo")
                .accessibilityValue(decision.map(DuplicateStyle.label) ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Changes between Keep, Delete and no choice")
                .accessibilityAction(named: "Fullscreen", onOpen)

            // Android also writes KEEP or DELETE here; the badge on the picture shows it instead.
            Text(asset.fileSize.map(DuplicateFormat.size) ?? String(localized: "Unknown size"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func beginPinch() {
        isPinching = true
        pinchScale = 1
        pinchOffset = .zero
        // Shown at once, so the list and the row stop scrolling before the fingers move.
        reportPeek(isActive: true)
    }

    private func pinch(_ step: PinchStep) {
        guard isPinching else { return }
        if step.touchCount >= 2 {
            pinchScale = min(max(pinchScale * step.zoomChange, 1), 4)
        }
        let limit = 100 * pinchScale
        pinchOffset = CGSize(
            width: min(max(pinchOffset.width + step.pan.width, -limit), limit),
            height: min(max(pinchOffset.height + step.pan.height, -limit), limit)
        )
        reportPeek(isActive: true)
    }

    private func endPinch() {
        guard isPinching else { return }
        reportPeek(isActive: false)
        // The tap or long press that ends with these fingers arrives just after; let it pass first.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            isPinching = false
        }
    }

    private func reportPeek(isActive: Bool) {
        onPeek(DuplicatePeek(asset: asset, frame: frame, scale: pinchScale, offset: pinchOffset, isActive: isActive))
    }
}

/// The 3:4 picture of a tile with its badges, shared by the tile and the pinch overlay. The overlay fades
/// the badges out as it grows.
///
/// The choice shows like a selection in Photos: an empty ring while undecided, a green check or a red bin
/// in the corner, and a photo marked Delete is dimmed. Android draws a coloured frame instead.
struct DuplicateTilePicture: View {
    let asset: Asset
    let decision: SwipeDecision?
    let isFavorite: Bool
    let request: URLRequest
    var badgeOpacity: Double = 1

    var body: some View {
        Color.clear
            .aspectRatio(0.75, contentMode: .fit)
            .overlay { DuplicateFilledImage(request: request) }
            .overlay(alignment: .topLeading) {
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.red)
                        .padding(8)
                        .opacity(badgeOpacity)
                }
            }
            .overlay {
                if decision == .delete {
                    Color.black.opacity(0.35 * badgeOpacity)
                }
            }
            .overlay(alignment: .bottomLeading) { typeBadge.padding(8).opacity(badgeOpacity) }
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if let decision {
                        DuplicateDecisionBadge(decision: decision, size: 28)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Circle()
                            .strokeBorder(.white, lineWidth: 1.5)
                            .background(.black.opacity(0.2), in: .circle)
                            .frame(width: 28, height: 28)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .padding(8)
                .opacity(badgeOpacity)
            }
            .animation(.snappy, value: decision)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var typeBadge: some View {
        if asset.type == .video {
            Image(systemName: "play.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.5), in: .circle)
                .accessibilityLabel("Video")
        } else if asset.isGIF {
            Text(verbatim: "GIF")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
        }
    }
}

/// A white-rimmed check or bin in the choice's colour.
struct DuplicateDecisionBadge: View {
    let decision: SwipeDecision
    let size: CGFloat

    var body: some View {
        Image(systemName: decision == .delete ? "trash.circle.fill" : "checkmark.circle.fill")
            .resizable()
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, DuplicateStyle.color(decision))
            .frame(width: size, height: size)
            .background(.white, in: .circle)
    }
}

/// An authenticated Immich image that fills its frame, cropped, with a broken-image mark if it fails.
struct DuplicateFilledImage: View {
    let request: URLRequest

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            .animation(.easeOut(duration: 0.2), value: image != nil)
        }
        .task(id: request.url) {
            image = nil
            failed = false
            do {
                // Previews are 1440 px; that size is shared with the fullscreen viewer, so it opens instantly.
                image = try await ThumbnailLoader.shared.image(for: request, maxPixelSize: 1440)
            } catch is CancellationError {
            } catch {
                failed = true
            }
        }
    }
}

// MARK: - Group buttons

/// Keep all / Delete all: glass tinted with the choice's colour while off, prominent filled glass while
/// the whole group has that choice. Android's expressive toggle buttons morph their shape instead; the
/// glass gives its own press response.
private struct DuplicateGroupButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isOn {
                Button(action: action) { label }
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action) { label.foregroundStyle(color) }
                    .buttonStyle(.glass)
            }
        }
        .tint(color)
        .controlSize(.large)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .animation(.snappy, value: isOn)
        .sensoryFeedback(.selection, trigger: isOn)
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Pinch to peek

/// A tile being pinched: where it sits on screen, how far it is zoomed (1–4×, as on Android) and moved.
struct DuplicatePeek: Equatable {
    var asset: Asset
    var frame: CGRect
    var scale: CGFloat
    var offset: CGSize
    /// False once the fingers lift; the overlay then shrinks back and goes away.
    var isActive: Bool
}

/// Draws the pinched tile above everything, over a backdrop that darkens as it grows
/// (`InstagramZoomOverlay.kt`).
struct DuplicatePeekOverlay: View {
    let peek: DuplicatePeek
    let model: DuplicatesModel

    var body: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            ZStack {
                Color.black.opacity(min((peek.scale - 1) / 1.5, 0.7))
                DuplicateTilePicture(
                    asset: peek.asset,
                    decision: model.decision(for: peek.asset),
                    isFavorite: model.isFavorite(peek.asset),
                    request: model.client.authorizedRequest(for: .preview(assetID: peek.asset.id)),
                    badgeOpacity: min(max(1 - (peek.scale - 1) * 1.5, 0), 1)
                )
                .frame(width: peek.frame.width, height: peek.frame.height)
                .scaleEffect(peek.scale)
                .offset(peek.offset)
                .position(x: peek.frame.midX - origin.x, y: peek.frame.midY - origin.y)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared look and formatting

nonisolated enum DuplicateStyle {
    static func color(_ decision: SwipeDecision) -> Color {
        decision == .delete ? .red : .green
    }

    /// "KEEP" or "DELETE", as on Android.
    static func label(_ decision: SwipeDecision) -> String {
        decision == .delete ? String(localized: "DELETE") : String(localized: "KEEP")
    }
}

nonisolated enum DuplicateFormat {
    /// "1.25 GB", "3.40 MB" or "512 KB", in 1024 steps, as on Android (`formatSizeStr`).
    static func size(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        if mb >= 1 { return String(format: "%.2f MB", mb) }
        return String(format: "%.0f KB", kb)
    }

    /// Shortens a long file name in the middle, keeping its extension: "IMG_…20240101_123456.jpg"
    /// (`formatMiddleEllipsisFileName`).
    static func middleEllipsis(_ fileName: String, maxLength: Int = 22) -> String {
        guard fileName.count > maxLength else { return fileName }
        let ellipsis = "…"
        // A dot that is neither first nor last starts the extension.
        let dot = fileName.lastIndex(of: ".").flatMap { $0 > fileName.startIndex && fileName.index(after: $0) < fileName.endIndex ? $0 : nil }
        let ext = dot.map { String(fileName[$0...]) } ?? ""
        let base = dot.map { String(fileName[..<$0]) } ?? fileName
        let availableForBase = maxLength - ext.count - ellipsis.count

        if availableForBase < 3 {
            let available = maxLength - ellipsis.count
            if available <= 0 { return String(fileName.prefix(maxLength)) }
            let prefix = min(2, available - 1)
            return fileName.prefix(prefix) + ellipsis + fileName.suffix(available - prefix)
        }
        let prefix = min(4, availableForBase / 3)
        return base.prefix(prefix) + ellipsis + base.suffix(availableForBase - prefix) + ext
    }
}
