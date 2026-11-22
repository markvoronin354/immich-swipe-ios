import SwiftUI

/// The views a tutorial can light up, by name, as their bounds (Android's `tutorialTarget`). Anchors rather than
/// window coordinates, so a rotation, a resized window or larger text moves the spotlight along with the view.
private struct TutorialTargetKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Names this view, so a tutorial step can light it up. The rows of a list can share a name by adding `#` and
    /// something unique to each (`photos#7`): the step then lights whichever is nearest the middle of the screen.
    func tutorialTarget(_ id: String) -> some View {
        // Adds to the targets inside this view. `anchorPreference` would replace them, so a target nested in
        // another, like a group's photos in the group, would never be found.
        transformAnchorPreference(key: TutorialTargetKey.self, value: .bounds) { targets, anchor in
            targets[id] = anchor
        }
    }

    /// Shows the controller's tutorial over this view and the targets inside it.
    func tutorialOverlay(_ controller: TutorialController) -> some View {
        modifier(TutorialOverlayModifier(controller: controller))
    }
}

private struct TutorialOverlayModifier: ViewModifier {
    let controller: TutorialController

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(TutorialTargetKey.self) { targets in
                TutorialOverlay(controller: controller, targets: targets)
            }
            .sensoryFeedback(.selection, trigger: controller.index)
            .sensoryFeedback(.success, trigger: controller.finishedCount)
    }
}
