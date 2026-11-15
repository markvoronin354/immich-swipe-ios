import SwiftUI

/// One step of finger movement on the card, in the card's own coordinates.
struct PinchStep {
    /// How much the fingers spread since the last step (1 = no change, or only one finger down).
    var zoomChange: CGFloat
    /// Where the fingers' midpoint was at the last step.
    var centroid: CGPoint
    /// How far the midpoint has moved since the last step.
    var pan: CGSize
    /// How many fingers are down.
    var touchCount: Int
    /// The card's size.
    var size: CGSize
}

#if os(iOS)
import UIKit

/// Follows every finger on the view it is the background of, like the pointer loop in the Android app's
/// ZoomableBox. SwiftUI's gestures can't do this: MagnifyGesture reports only the spread of two fingers,
/// and DragGesture jumps when a finger is lifted. This reports each move with the zoom change, the
/// midpoint and its movement, and tells when the last finger is up.
///
/// The recogniser sits on the window's root view and never claims the touches, so SwiftUI's own gestures
/// keep working alongside it. Only touches that start inside this view count.
struct CardPinchGesture: UIViewRepresentable {
    /// A second finger came down: a zoom has begun.
    var onBegan: () -> Void
    var onChanged: (PinchStep) -> Void
    /// The last finger came up.
    var onEnded: () -> Void

    func makeUIView(context: Context) -> PinchHostView {
        let view = PinchHostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.handlers = self
        return view
    }

    func updateUIView(_ view: PinchHostView, context: Context) {
        view.handlers = self
    }

    final class PinchHostView: UIView, UIGestureRecognizerDelegate {
        var handlers: CardPinchGesture?

        private lazy var tracker: TouchTracker = {
            let tracker = TouchTracker()
            tracker.host = self
            tracker.delegate = self
            tracker.cancelsTouchesInView = false
            tracker.delaysTouchesBegan = false
            tracker.delaysTouchesEnded = false
            return tracker
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tracker.view?.removeGestureRecognizer(tracker)
            guard let window else { return }
            // Our own view ignores touches, so the recogniser has to live higher up to see them.
            var root: UIView = self
            while let parent = root.superview, parent !== window { root = parent }
            root.addGestureRecognizer(tracker)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            bounds.contains(touch.location(in: self))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// Watches touches without ever recognising, so it can't take them from anything else.
    final class TouchTracker: UIGestureRecognizer {
        weak var host: PinchHostView?
        private var active: [UITouch] = []
        private var hasBegunZoom = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            active.append(contentsOf: touches.filter { !active.contains($0) })
            if active.count >= 2, !hasBegunZoom {
                hasBegunZoom = true
                host?.handlers?.onBegan()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let host, !active.isEmpty else { return }
            let now = active.map { $0.location(in: host) }
            let before = active.map { $0.previousLocation(in: host) }
            let centroidNow = Self.centroid(of: now)
            let centroidBefore = Self.centroid(of: before)

            var zoomChange: CGFloat = 1
            if active.count >= 2 {
                let spreadBefore = Self.spread(of: before, around: centroidBefore)
                let spreadNow = Self.spread(of: now, around: centroidNow)
                if spreadBefore > 0.001 { zoomChange = spreadNow / spreadBefore }
            }

            host.handlers?.onChanged(PinchStep(
                zoomChange: zoomChange,
                centroid: centroidBefore,
                pan: CGSize(width: centroidNow.x - centroidBefore.x, height: centroidNow.y - centroidBefore.y),
                touchCount: active.count,
                size: host.bounds.size
            ))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            lift(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            lift(touches)
        }

        override func reset() {
            active.removeAll()
            hasBegunZoom = false
        }

        private func lift(_ touches: Set<UITouch>) {
            active.removeAll { touches.contains($0) }
            if active.isEmpty {
                hasBegunZoom = false
                host?.handlers?.onEnded()
            }
        }

        private static func centroid(of points: [CGPoint]) -> CGPoint {
            let count = CGFloat(max(points.count, 1))
            return CGPoint(x: points.map(\.x).reduce(0, +) / count, y: points.map(\.y).reduce(0, +) / count)
        }

        /// The average distance of the points from their midpoint.
        private static func spread(of points: [CGPoint], around centre: CGPoint) -> CGFloat {
            let total = points.map { hypot($0.x - centre.x, $0.y - centre.y) }.reduce(0, +)
            return total / CGFloat(max(points.count, 1))
        }
    }
}
#else
/// Pinch-to-zoom on the card is touch-only.
struct CardPinchGesture: View {
    var onBegan: () -> Void
    var onChanged: (PinchStep) -> Void
    var onEnded: () -> Void

    var body: some View { Color.clear }
}
#endif
