import UIKit

/// Asks iOS for time to finish if the app is sent to the background part way through server changes, as
/// Android carries on with them. Without it the app is suspended within seconds and the remaining requests
/// fail, leaving the changes half applied until the next try.
///
/// Create one when the work starts and call `end()` when it's done: `defer { background.end() }`.
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        // Out of time: iOS will suspend the app anyway, so give the time back as it asks.
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
