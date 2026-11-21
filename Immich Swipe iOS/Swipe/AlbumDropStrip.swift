import SwiftUI

/// Where the finger is while a card is dragged over the strip of albums, and which tile it is over (Android's
/// `AlbumDropState`). Everything is in screen coordinates, which is what the card's drag reports.
@Observable
final class DropStripState {
    /// The id of the strip's last tile: dropping there opens the full album picker rather than adding to an album.
    nonisolated static let moreID = "more"

    private(set) var isActive = false
    private(set) var pointer: CGPoint?
    /// Where each tile is on screen, by id. The tiles report themselves, and take themselves out when they go.
    var tileFrames: [String: CGRect] = [:]
    /// Where the scrolling part of the strip is on screen.
    var scrollBounds: CGRect?
    /// The albums on offer, the ones last added to first.
    var albums: [Album] = []

    /// The tile under the finger, once it is down in the strip or just above it.
    var hoveredID: String? { isActive ? Self.tile(at: pointer, in: tileFrames) : nil }

    func move(to point: CGPoint) {
        isActive = true
        pointer = point
    }

    func end() {
        isActive = false
        pointer = nil
    }

    /// The tile nearest the finger sideways, once the finger is no higher above the strip than a tile is tall.
    nonisolated static func tile(at pointer: CGPoint?, in frames: [String: CGRect]) -> String? {
        guard let pointer, let top = frames.values.map(\.minY).min(), let height = frames.values.map(\.height).max(),
              pointer.y >= top - height else { return nil }
        return frames.min { lhs, rhs in
            let (left, right) = (abs(pointer.x - lhs.value.midX), abs(pointer.x - rhs.value.midX))
            return left != right ? left < right : lhs.value.minX < rhs.value.minX
        }?.key
    }

    /// How far to move a card shrunk to `scale` beyond where it was dragged to, so the point the finger grabbed
    /// stays under the finger. `anchor` is that point from the card's middle at rest. The card is shrunk about its
    /// middle, moved by `drag`, then turned by `angle` about its middle, so the point wanted, the anchor plus the
    /// drag, is found by turning the other way.
    nonisolated static func thumbnailShift(anchor: CGPoint, drag: CGSize, angle: Double, scale: CGFloat) -> CGSize {
        let (x, y) = (anchor.x + drag.width, anchor.y + drag.height)
        let wantedX = x * cos(angle) + y * sin(angle)
        let wantedY = -x * sin(angle) + y * cos(angle)
        return CGSize(width: wantedX - drag.width - scale * anchor.x, height: wantedY - drag.height - scale * anchor.y)
    }

    /// -1 to 1: which way, and how fast, the strip should scroll for a finger at `pointer`; 0 away from its edges.
    nonisolated static func autoScrollDirection(pointer: CGPoint, bounds: CGRect, edge: CGFloat) -> CGFloat {
        if pointer.y < bounds.minY - bounds.height { return 0 }
        if pointer.x < bounds.minX + edge {
            return -(1 - ((pointer.x - bounds.minX) / edge).clamped(to: 0...1))
        }
        // Past the row's right edge is the More tile, which has to be reachable without scrolling.
        if (bounds.maxX - edge...bounds.maxX).contains(pointer.x) {
            return (pointer.x - (bounds.maxX - edge)) / edge
        }
        return 0
    }
}

private extension CGFloat {
    nonisolated func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// Albums to drop the dragged card on, rising over the toolbar while a card is pulled down (Android's
/// `AlbumDropStrip`). A custom control: no native one lets a drag pick a target from a row.
struct AlbumDropStrip: View {
    let state: DropStripState
    /// Adds the tile that opens the full album picker, for when the toolbar has no album button to do so.
    let showsMore: Bool
    let cover: (Album) -> URLRequest?

    @State private var position = ScrollPosition(edge: .leading)
    /// Where the row is scrolled to, which the auto-scroll keeps itself rather than reading it back a frame late.
    @State private var scrollX: CGFloat = 0
    @State private var ends = ScrollEnds()

    /// How near a row's edge the finger starts scrolling it, and the fastest it scrolls.
    private static let autoScrollEdge: CGFloat = 64
    private static let autoScrollSpeed: CGFloat = 600

    private struct ScrollEnds: Equatable {
        var canScrollBackward = false
        var canScrollForward = false
        var maxOffset: CGFloat = 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            row
            if showsMore {
                // Pinned past the end of the row, so it stays in reach however far the albums scroll.
                DropTile(id: DropStripState.moreID, title: Text("More"), count: nil, state: state) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .overlay { Image(systemName: SwipeAction.album.systemImage).font(.title2).foregroundStyle(.secondary) }
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .padding(.vertical, 12)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 8)
        // Only a drag reaches it, and the toolbar's album button is the way in without one.
        .accessibilityHidden(true)
        .sensoryFeedback(.selection, trigger: state.hoveredID) { _, hovered in hovered != nil }
        // Every drag starts at the recent albums; a finger near either edge of the row scrolls it.
        .task(id: state.isActive) { await autoScroll() }
        // The albums reload as a drag starts, and the one just used moves to the front.
        .onChange(of: state.albums.map(\.id)) {
            guard state.isActive else { return }
            scrollX = 0
            position.scrollTo(x: 0)
        }
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(state.albums) { album in
                    DropTile(id: album.id, title: Text(verbatim: album.albumName), count: album.assetCount, state: state) {
                        RemoteThumbnail(request: cover(album), size: 64, cornerRadius: 14)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, showsMore ? 0 : 16)
            .padding(.vertical, 12)
        }
        // A scroll view takes all the height it is offered; the strip is only as tall as its tiles.
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollEnds.self) { geometry in
            let maxOffset = max(geometry.contentSize.width - geometry.containerSize.width, 0)
            return ScrollEnds(canScrollBackward: geometry.contentOffset.x > 1, canScrollForward: geometry.contentOffset.x < maxOffset - 1, maxOffset: maxOffset)
        } action: { _, new in
            ends = new
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.scrollBounds = $0 }
        .mask { edgeFades }
    }

    /// Fades the row out where more of it is off screen, as Android's 24 dp edge fades do.
    private var edgeFades: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(ends.canScrollBackward ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(ends.canScrollForward ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
        }
    }

    /// Scrolls the row while the finger is near one of its edges, for as long as the drag lasts.
    private func autoScroll() async {
        guard state.isActive else { return }
        scrollX = 0
        position.scrollTo(x: 0)
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = clock.now
            let seconds = (now - last) / .seconds(1)
            last = now
            guard let pointer = state.pointer, let bounds = state.scrollBounds else { continue }
            let direction = DropStripState.autoScrollDirection(pointer: pointer, bounds: bounds, edge: Self.autoScrollEdge)
            guard direction != 0 else { continue }
            scrollX = min(max(scrollX + direction * Self.autoScrollSpeed * seconds, 0), ends.maxOffset)
            position.scrollTo(x: scrollX)
        }
    }
}

/// An album's cover and name in the strip, or the More tile. It grows and takes the accent colour while the
/// finger is over it, and reports where it is so the card's drag can tell.
private struct DropTile<Cover: View>: View {
    let id: String
    let title: Text
    let count: Int?
    let state: DropStripState
    @ViewBuilder let cover: Cover

    private static var coverSize: CGFloat { 64 }

    private var isHovered: Bool { state.hoveredID == id }

    var body: some View {
        VStack(spacing: 2) {
            cover
                .frame(width: Self.coverSize, height: Self.coverSize)
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isHovered ? Color.accentColor : .clear, lineWidth: 2)
                }
            title
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(isHovered ? Color.accentColor : .primary)
                .padding(.top, 4)
            if let count {
                Text(count, format: .number)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 72)
        // Measured before the scale, so a tile growing under the finger can't push itself away from it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.tileFrames[id] = $0 }
        .onDisappear { state.tileFrames[id] = nil }
        .scaleEffect(isHovered ? 1.15 : 1)
        .animation(.snappy, value: isHovered)
    }
}

#Preview("Album Drop Strip") {
    let state = DropStripState()
    state.albums = (1...8).map { Album(id: "a\($0)", albumName: "Album \($0)", assetCount: $0 * 37) }
    state.move(to: CGPoint(x: 200, y: 700))
    return VStack {
        Spacer()
        AlbumDropStrip(state: state, showsMore: true, cover: { _ in nil })
            .padding(.bottom, 8)
    }
}
