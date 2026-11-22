import Observation

/// Runs one tutorial: which step is showing, and what to do when it ends (Android's `TutorialController`).
/// Each screen with a tutorial owns one.
@Observable
final class TutorialController {
    private(set) var steps: [TutorialStep] = []
    private(set) var index = 0
    private(set) var isActive = false
    /// Tutorials finished with "Got it!", for the success haptic. Skipping one doesn't count.
    private(set) var finishedCount = 0
    private var onComplete: (() -> Void)?

    var step: TutorialStep? { isActive && steps.indices.contains(index) ? steps[index] : nil }
    var isLastStep: Bool { index == steps.count - 1 }

    /// Starts from the first step. `onComplete` runs however the tutorial ends: finished, skipped, or left behind.
    func start(_ steps: [TutorialStep], onComplete: @escaping () -> Void) {
        guard !steps.isEmpty, !isActive else { return }
        self.steps = steps
        self.onComplete = onComplete
        index = 0
        isActive = true
    }

    func next() {
        if isLastStep {
            finishedCount += 1
            end()
        } else {
            index += 1
        }
    }

    func back() {
        if index > 0 { index -= 1 }
    }

    /// Skip, the Escape key, or leaving the screen. Android counts all of them as done, so the tutorial doesn't come back.
    func end() {
        guard isActive else { return }
        isActive = false
        let done = onComplete
        onComplete = nil
        done?()
    }
}
