import Observation
import SwiftUI

/// Pushes the settings screen onto the main navigation stack.
struct SettingsRoute: Hashable {}

/// Owns the main navigation path, so any screen (and the profile sheet) can open Settings
/// without knowing how it got where it is.
@Observable
final class Navigator {
    var path = NavigationPath()

    func openSettings() {
        path.append(SettingsRoute())
    }

    /// Back to the first screen, for example when the account changes.
    func reset() {
        path = NavigationPath()
    }
}
