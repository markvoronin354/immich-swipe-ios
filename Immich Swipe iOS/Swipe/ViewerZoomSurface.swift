import SwiftUI

/// How far in a zoom surface is and which part of the media is in the middle of the screen, as fractions
/// of the media's size, so it carries over between pictures of different resolutions.
struct ZoomViewport: Equatable {
    var scale: CGFloat = 1
    var centre = CGPoint(x: 0.5, y: 0.5)
}

/// Keeps the zoom of the surface on screen, for the one that replaces it. A plain class rather than state,
/// so following a pinch doesn't redraw the screen around it.
final class ZoomMemory {
    var viewport: ZoomViewport?
}

/// A drag on the fullscreen viewer while the media is at its normal size, in screen points.
enum ViewerDrag {
    case changed(CGSize)
    case ended(CGSize)
    case cancelled
}

/// The fullscreen viewer's touch layer. It draws nothing: it takes every touch and reports where the
/// media should be drawn, so the photo or video itself stays a plain SwiftUI view that can slide and fade.
///
/// On iOS it is a real scroll view, so zooming feels like Photos: momentum, rubber-banding at the edges,
/// and the picture can't be lost off screen. The numbers are Android's (`ZoomableBox.kt`): up to 10×, and
/// a double tap zooms to 3× at the tapped spot or back out. Swipe and close drags only start at 1×.
struct ZoomSurface {
    /// Width over height of the media as drawn, or nil until it is known (then it fills the surface).
    var aspectRatio: CGFloat?
    /// Where the media should be drawn, in this view's coordinates. Nil until the first layout.
    @Binding var mediaFrame: CGRect?
    /// Zoomed in past 1.05×, Android's threshold, which turns off tap to swipe.
    @Binding var isZoomed: Bool
    /// A single tap, reported at once. Returns true if it did something, so a double tap is ignored.
    var onTap: (CGPoint, CGSize) -> Bool
    /// A single tap that turned out not to be the start of a double tap.
    var onConfirmedTap: () -> Void
    /// A finger has been held still for half a second (true), and lifted again (false).
    var onHold: (Bool) -> Void
    var onDrag: (ViewerDrag) -> Void
    /// Where to keep the zoom, so a new surface for the next asset starts zoomed in on the same spot.
    /// Nil starts every surface at 1×.
    var memory: ZoomMemory? = nil

    static let maximumZoom: CGFloat = 10
    static let doubleTapZoom: CGFloat = 3
    static let zoomedThreshold: CGFloat = 1.05
}

#if canImport(UIKit)
import UIKit

extension ZoomSurface: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        let coordinator = context.coordinator
        view.delegate = coordinator
        view.pendingViewport = memory?.viewport
        view.aspectRatio = aspectRatio
        // Layout runs while SwiftUI is updating, so the new frame is reported just after.
        view.onLayout = { [weak coordinator] in
            DispatchQueue.main.async { coordinator?.report() }
        }
        coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        view.aspectRatio = aspectRatio
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomSurface
        private weak var scrollView: ZoomScrollView?
        private let swipePan = UIPanGestureRecognizer()
        private let instantTap = UITapGestureRecognizer()
        private let confirmedTap = UITapGestureRecognizer()
        private let doubleTap = UITapGestureRecognizer()
        private let hold = UILongPressGestureRecognizer()
        /// The last tap was used by `onTap` (a tap-to-swipe), so it doesn't also count towards a double tap.
        private var tapWasUsed = false
        private var isHolding = false
        private var holdEndedAt = Date.distantPast
        /// Runs while the scroll view animates on its own (springing back from below 1×, double-tap
        /// zoom). Those animations move only its layers and report just the end state, so the frame is
        /// read from the layers on screen every frame instead.
        private var displayLink: CADisplayLink?
        private var idleFrames = 0

        init(parent: ZoomSurface) {
            self.parent = parent
        }

        func install(on view: ZoomScrollView) {
            scrollView = view
            swipePan.addTarget(self, action: #selector(panned))
            instantTap.addTarget(self, action: #selector(tappedInstantly))
            confirmedTap.addTarget(self, action: #selector(tappedOnce))
            doubleTap.addTarget(self, action: #selector(tappedTwice))
            doubleTap.numberOfTapsRequired = 2
            confirmedTap.require(toFail: doubleTap)
            hold.addTarget(self, action: #selector(held))
            hold.minimumPressDuration = 0.5
            for recognizer in [swipePan, instantTap, confirmedTap, doubleTap, hold] as [UIGestureRecognizer] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
            view.panGestureRecognizer.isEnabled = false
        }

        /// Hands SwiftUI the media's frame on screen, and whether it is zoomed in.
        func report() {
            guard let view = scrollView else { return }
            // While following an animation the display link reports the frame; the end state would jump.
            if displayLink == nil { publishFrame(of: view.zoomView.layer, offset: view.contentOffset) }
            // Not until the remembered zoom has been applied, or the 1× start would overwrite it.
            if let memory = parent.memory, view.pendingViewport == nil {
                memory.viewport = view.currentViewport
            }
            let zoomed = view.zoomScale > ZoomSurface.zoomedThreshold
            if parent.isZoomed != zoomed { parent.isZoomed = zoomed }
            // At 1× one finger swipes or closes; the scroll view only pans once there is something to pan.
            view.panGestureRecognizer.isEnabled = view.zoomScale > 1.01
        }

        private func publishFrame(of zoomLayer: CALayer, offset: CGPoint) {
            let content = zoomLayer.frame
            let frame = CGRect(
                x: content.minX - offset.x,
                y: content.minY - offset.y,
                width: content.width,
                height: content.height
            )
            if parent.mediaFrame != frame { parent.mediaFrame = frame }
        }

        private func followAnimations() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(stepAnimation))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        /// Draws the media where the scroll view's layers are on screen right now, until they come to rest.
        @objc private func stepAnimation() {
            guard let view = scrollView else {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            let zoomLayer = view.zoomView.layer.presentation() ?? view.zoomView.layer
            let offset = (view.layer.presentation() ?? view.layer).bounds.origin
            publishFrame(of: zoomLayer, offset: offset)
            let isAnimating = !(view.layer.animationKeys() ?? []).isEmpty || !(view.zoomView.layer.animationKeys() ?? []).isEmpty
            // Two quiet frames in a row, in case the spring back starts a frame after the fingers lift.
            idleFrames = view.isZooming || view.isZoomBouncing || isAnimating ? 0 : idleFrames + 1
            if idleFrames >= 2 {
                idleFrames = 0
                displayLink?.invalidate()
                displayLink = nil
                report()
            }
        }

        // MARK: Scroll view

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.zoomView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centreContent()
            report()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            report()
        }

        /// A second finger turns a swipe that was under way into a zoom.
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            // Followed from the start, so the spring back after zooming out below 1× is followed too.
            followAnimations()
            if swipePan.state == .began || swipePan.state == .changed {
                swipePan.isEnabled = false
                swipePan.isEnabled = true
            }
        }

        // MARK: Gestures

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === swipePan, let view = scrollView else { return true }
            return view.zoomScale <= 1.01 && !view.isZooming && !view.isZoomBouncing
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Taps that end a hold don't count.
        private var isTapAllowed: Bool {
            !isHolding && Date().timeIntervalSince(holdEndedAt) > 0.2
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: nil)
            let size = CGSize(width: translation.x, height: translation.y)
            switch recognizer.state {
            case .began, .changed: parent.onDrag(.changed(size))
            case .ended: parent.onDrag(.ended(size))
            case .cancelled, .failed: parent.onDrag(.cancelled)
            default: break
            }
        }

        @objc private func tappedInstantly(_ recognizer: UITapGestureRecognizer) {
            guard let view = scrollView, isTapAllowed else { return }
            // In screen terms: the scroll view's own coordinates move as it scrolls.
            let point = recognizer.location(in: view)
            tapWasUsed = parent.onTap(CGPoint(x: point.x - view.contentOffset.x, y: point.y - view.contentOffset.y), view.bounds.size)
        }

        @objc private func tappedOnce(_ recognizer: UITapGestureRecognizer) {
            guard isTapAllowed, !tapWasUsed else { return }
            parent.onConfirmedTap()
        }

        /// Zoomed in: back to 1×. Otherwise 3× around the tapped spot, as on Android.
        @objc private func tappedTwice(_ recognizer: UITapGestureRecognizer) {
            guard let view = scrollView, isTapAllowed, !tapWasUsed else { return }
            followAnimations()
            if view.zoomScale > ZoomSurface.zoomedThreshold {
                view.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: view.zoomView)
                let size = CGSize(
                    width: view.bounds.width / ZoomSurface.doubleTapZoom,
                    height: view.bounds.height / ZoomSurface.doubleTapZoom
                )
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                isHolding = true
                parent.onHold(true)
            case .ended, .cancelled, .failed:
                guard isHolding else { return }
                isHolding = false
                holdEndedAt = Date()
                parent.onHold(false)
            default:
                break
            }
        }
    }
}

/// A scroll view whose only content is an empty view the size of the fitted media. Zooming and panning
/// move that view; the coordinator reads its frame back and SwiftUI draws the media there.
final class ZoomScrollView: UIScrollView {
    let zoomView = UIView()
    var onLayout: (() -> Void)?
    var aspectRatio: CGFloat? {
        didSet {
            guard oldValue != aspectRatio else { return }
            needsReset = true
            setNeedsLayout()
        }
    }

    /// A zoom to start at, applied once the media's shape is known.
    var pendingViewport: ZoomViewport?

    private var laidOutSize: CGSize = .zero
    private var needsReset = true

    /// The current zoom, with the middle of the screen as a fraction of the media.
    var currentViewport: ZoomViewport {
        let size = zoomView.frame.size
        guard size.width > 0, size.height > 0 else { return ZoomViewport() }
        return ZoomViewport(
            scale: zoomScale,
            centre: CGPoint(
                x: (contentOffset.x + bounds.width / 2) / size.width,
                y: (contentOffset.y + bounds.height / 2) / size.height
            )
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(zoomView)
        minimumZoomScale = 1
        maximumZoomScale = ZoomSurface.maximumZoom
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new size (the phone turned) or a newly known shape starts again at 1×.
        if needsReset || bounds.size != laidOutSize {
            needsReset = false
            laidOutSize = bounds.size
            resetZoom()
        }
    }

    private func resetZoom() {
        zoomScale = 1
        let size = Self.fit(aspectRatio, in: bounds.size)
        zoomView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centreContent()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        // Only once the media's shape is known; before that the fitted size is just the screen.
        if aspectRatio != nil, let viewport = pendingViewport {
            pendingViewport = nil
            if viewport.scale > 1.01 { apply(viewport) }
        }
        onLayout?()
    }

    /// Zooms to the remembered scale with the same part of the media in the middle, kept within the
    /// edges so a picture of another shape doesn't end up off screen.
    private func apply(_ viewport: ZoomViewport) {
        zoomScale = min(viewport.scale, maximumZoomScale)
        centreContent()
        let size = zoomView.frame.size
        let x = viewport.centre.x * size.width - bounds.width / 2
        let y = viewport.centre.y * size.height - bounds.height / 2
        contentOffset = CGPoint(
            x: min(max(x, -contentInset.left), contentSize.width + contentInset.right - bounds.width),
            y: min(max(y, -contentInset.top), contentSize.height + contentInset.bottom - bounds.height)
        )
    }

    /// Keeps media smaller than the screen in the middle of it.
    func centreContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    private static func fit(_ aspectRatio: CGFloat?, in size: CGSize) -> CGSize {
        guard let aspectRatio, aspectRatio > 0, size.width > 0, size.height > 0 else { return size }
        if size.width / size.height > aspectRatio {
            return CGSize(width: size.height * aspectRatio, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspectRatio)
    }
}
#else
/// On the Mac the viewer has no zoom: a click or drag does what a tap or swipe does on iOS.
extension ZoomSurface: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { onDrag(.changed($0.translation)) }
                        .onEnded { onDrag(.ended($0.translation)) }
                )
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            if !onTap(value.location, geometry.size) { onConfirmedTap() }
                        }
                )
        }
    }
}
#endif
