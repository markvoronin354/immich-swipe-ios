import Foundation

/// Which tutorials have been shown, with Android's rules (`SessionDataStore`: `initializeTutorialStateForInstallOrUpgrade`,
/// `resetTutorials`). Read with `@AppStorage` and the keys in `Setting.Key`.
enum TutorialFlags {
    /// Runs once, the first time a version with tutorials launches. A fresh install sees both tutorials. An app that
    /// already has an account doesn't, so people who updated aren't walked through screens they know. A flag that
    /// already has a value is left alone.
    static func processInstall(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Setting.Key.initialInstallProcessed) else { return }
        let hasAccount = defaults.data(forKey: SessionStore.accountsKey)
            .flatMap { try? JSONDecoder().decode([Account].self, from: $0) }
            .map { !$0.isEmpty } ?? false
        for key in [Setting.Key.hasCompletedSwipeTutorial, Setting.Key.hasCompletedDuplicatesTutorial] where defaults.object(forKey: key) == nil {
            defaults.set(hasAccount, forKey: key)
        }
        defaults.set(true, forKey: Setting.Key.initialInstallProcessed)
    }

    /// Settings → App Tutorials: both play again the next time their screen opens.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: Setting.Key.hasCompletedSwipeTutorial)
        defaults.set(false, forKey: Setting.Key.hasCompletedDuplicatesTutorial)
    }
}
