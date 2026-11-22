import SwiftUI

#if canImport(UIKit)
import UIKit

/// A phone stays upright, except while the swipe screen's fullscreen viewer is open. The swipe deck, the duplicates
/// list and the duplicates viewer are laid out for a tall screen. Android lets every screen turn, but these have no
/// landscape layout here, and the duplicates list broke when it turned behind its viewer.
///
/// A phone is told by the size of its screen, not by what the device calls itself: a foldable opened out is as
/// wide as a small tablet, and an iPad or a Mac window is wider still, so those keep every orientation.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `allowsLandscape()` while a viewer is on screen.
    static var allowsLandscape = false

    /// The shorter side of the screen, under which it counts as a phone (the largest iPhone is 440 pt).
    private static let phoneWidthLimit: CGFloat = 600

    static func isPhoneSized(_ screen: UIScreen) -> Bool {
        min(screen.bounds.width, screen.bounds.height) < phoneWidthLimit
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let screen = window?.windowScene?.screen ?? application.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let isPhone = screen.map(Self.isPhoneSized) ?? false
        guard isPhone else { return .all }
        return Self.allowsLandscape ? .allButUpsideDown : .portrait
    }
}

private struct LandscapeWhileShown: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { Self.setLandscapeAllowed(true) }
            .onDisappear { Self.setLandscapeAllowed(false) }
    }

    private static func setLandscapeAllowed(_ allowed: Bool) {
        AppDelegate.allowsLandscape = allowed
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              AppDelegate.isPhoneSized(scene.screen) else { return }
        // The mask is read again from the screen at the bottom of the stack up to the one on top.
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        // Closing the viewer with the phone on its side turns the screen back upright.
        if !allowed {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

extension View {
    /// Lets a phone turn to landscape while this view is on screen (a fullscreen viewer, as on Android).
    func allowsLandscape() -> some View {
        modifier(LandscapeWhileShown())
    }
}
#else
extension View {
    func allowsLandscape() -> some View { self }
}
#endif
