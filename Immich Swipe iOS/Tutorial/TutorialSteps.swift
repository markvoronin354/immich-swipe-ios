import SwiftUI

/// The steps of each screen's tutorial, with Android's wording (`tutorial_*` strings) and targets.
extension TutorialStep {
    /// The swipe screen (`SwipeScreen.kt`). The first step names what each swipe does, so it follows the swipe
    /// settings. Android shouts the action names in capitals; here they're bold.
    static func swipeDeck(swipes: SwipeMapping) -> [TutorialStep] {
        let right = Text(swipes.right.title).bold()
        let left = Text(swipes.left.title).bold()
        let down = Text(swipes.down.title).bold()
        let up = Text(swipes.up.title).bold()
        let gestures: LocalizedStringKey = swipes.up == .details
            ? "Swipe RIGHT to \(right), swipe LEFT to \(left), swipe DOWN to \(down), or drag UP to view full photo EXIF details!"
            : "Swipe RIGHT to \(right), swipe LEFT to \(left), swipe DOWN to \(down), or swipe UP to \(up)!"
        return [
            TutorialStep(id: "gestures", title: "Swipe Gestures & Details", message: gestures, target: "deck", padding: 0, cornerRadius: 28),
            TutorialStep(id: "header", title: "Progress Tracking", message: "Monitor your sorting progress and counts at a glance. Tap the progress bar anytime to open the summary and sync changes to Immich!", target: "header", padding: 4, cornerRadius: nil),
            TutorialStep(id: "actions", title: "Quick Action Bar", message: "Use bottom buttons to Undo, Archive, Favorite, Add to Album, or change Sort Order.", target: "actions", cornerRadius: nil),
        ]
    }

    /// The duplicates screen (`DuplicatesScreen.kt`). The group and photos targets are shared by every group, and
    /// the step lights the one in the middle of the screen.
    static var duplicates: [TutorialStep] {
        [
            TutorialStep(id: "clusters", title: "Duplicate Groups", message: "Similar photos and videos are grouped into clusters. Compare resolution, file size, and details to decide which ones to clean up.", target: "cluster", cornerRadius: 28),
            TutorialStep(id: "selection", title: "Mark Keep or Delete", message: "Tap any photo card to toggle between Keep and Delete choices. Long-press any photo for a full-screen comparison view!", target: "photos"),
            TutorialStep(id: "action", title: "Free Up Server Space", message: "Once duplicate photos are marked for deletion, tap the progress bar anytime to open the summary and delete them from Immich!", target: "delete", cornerRadius: nil),
        ]
    }
}
