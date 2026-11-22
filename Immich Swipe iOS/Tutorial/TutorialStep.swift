import SwiftUI

/// One stop in a tutorial (Android's `TutorialStep`): what to say, and which view to light up while saying it.
struct TutorialStep: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    /// The `tutorialTarget` to light up. With none, or one that isn't on screen, the whole screen is dimmed.
    var target: String?
    /// Room between the target and the edge of the lit area.
    var padding: CGFloat = 6
    /// Corner radius of the target's own shape. Nil: fully rounded ends, for a pill.
    var cornerRadius: CGFloat? = 16

    /// The area to light for a target's `frame` in an overlay of `size`: the frame with `padding` around it. It isn't
    /// held inside the overlay, which stops at the safe area, so a target flush with its edge (the pill just under the
    /// navigation bar) keeps its outline on every side. Nil if the target isn't in the overlay at all.
    func litRect(around frame: CGRect, in size: CGSize) -> CGRect? {
        let lit = frame.insetBy(dx: -padding, dy: -padding)
        return lit.intersects(CGRect(origin: .zero, size: size)) ? lit : nil
    }
}
