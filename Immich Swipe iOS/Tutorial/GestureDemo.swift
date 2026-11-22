import SwiftUI

/// Shows what each swipe does by swiping the real top card by itself, with a ghost finger on it, one direction at a
/// time. Android's tutorial has an animated hand for this in its code but never turns it on. Nothing is decided: the
/// card follows the finger, shows its stamp, and springs back.
@Observable
final class GestureDemo {
    private(set) var isShowing = false
    private(set) var isFingerDown = false

    /// A little past where a real swipe commits (`CardMotion.distanceThreshold`), so the stamp pops as it does then.
    private static let pull = CardMotion.distanceThreshold + 6

    /// Loops until cancelled, then puts the card back.
    func run(on motion: CardMotion, swipes: SwipeMapping, canUndo: Bool) async {
        do {
            // Let the tutorial's card settle first.
            try await Task.sleep(for: .milliseconds(700))
            withAnimation(.smooth(duration: 0.3)) { isShowing = true }
            while true {
                for pull in Self.pulls(swipes: swipes, canUndo: canUndo) {
                    try await Task.sleep(for: .milliseconds(350))
                    withAnimation(.smooth(duration: 0.2)) { isFingerDown = true }
                    try await Task.sleep(for: .milliseconds(200))
                    withAnimation(.smooth(duration: 0.7)) { motion.offset = pull }
                    try await Task.sleep(for: .milliseconds(1500))
                    withAnimation(.smooth(duration: 0.2)) { isFingerDown = false }
                    withAnimation(.bouncy) { motion.offset = .zero }
                    try await Task.sleep(for: .milliseconds(600))
                }
            }
        } catch {
            // Cancelled: the step changed or the tutorial ended.
        }
        withAnimation(.smooth(duration: 0.25)) {
            isShowing = false
            isFingerDown = false
            motion.offset = .zero
        }
    }

    /// Right, left, down, up, as the first step's words go. Only the pulls that show something: pulling down
    /// to undo with nothing to undo resists instead, pulling down to drop on an album or a star needs the strip,
    /// and pulling up for details opens a panel, none of which is a swipe to show off.
    private static func pulls(swipes: SwipeMapping, canUndo: Bool) -> [CGSize] {
        var pulls = [CGSize(width: pull, height: 0), CGSize(width: -pull, height: 0)]
        if !swipes.down.isDropTarget, swipes.down != .undo || canUndo { pulls.append(CGSize(width: 0, height: pull)) }
        if swipes.up != .details { pulls.append(CGSize(width: 0, height: -pull)) }
        return pulls
    }
}

/// A fingertip that rides the top card while `GestureDemo` swipes it. In its own view, so the screen doesn't
/// redraw as the card moves.
struct GhostFinger: View {
    let demo: GestureDemo
    let motion: CardMotion

    var body: some View {
        if demo.isShowing {
            Circle()
                .fill(.white.opacity(0.4))
                .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2) }
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .scaleEffect(demo.isFingerDown ? 0.82 : 1)
                .offset(motion.offset)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
