import SwiftUI

/// A tutorial drawn over a screen (Android's `TutorialOverlay`): a dimmed scrim with a hole over the view being
/// explained, a glow around the hole, and a glass card with the words. The hole travels from step to step.
///
/// Android draws a Material card and a pulsing stroke. This is the iOS version of the same thing: Liquid Glass, a
/// soft accent glow, page dots, and haptics (from `tutorialOverlay`).
struct TutorialOverlay: View {
    let controller: TutorialController
    let targets: [String: Anchor<CGRect>]

    var body: some View {
        ZStack {
            if let step = controller.step {
                TutorialScene(controller: controller, step: step, candidates: candidates(for: step))
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: controller.isActive)
    }

    /// The views a step could light: the one with its name, or all those sharing it before a `#`, as the groups
    /// of a list do.
    private func candidates(for step: TutorialStep) -> [Anchor<CGRect>] {
        guard let name = step.target else { return [] }
        return targets.filter { $0.key == name || $0.key.hasPrefix(name + "#") }.map(\.value)
    }
}

private struct TutorialScene: View {
    let controller: TutorialController
    let step: TutorialStep
    let candidates: [Anchor<CGRect>]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var hasKeyboardFocus: Bool
    /// The card's own height, measured, to find it a place that doesn't cover what it points at.
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // Of several candidates, the one nearest the middle of the screen is the one in view.
            let frame = candidates.map { proxy[$0] }.min { abs($0.midY - size.height / 2) < abs($1.midY - size.height / 2) }
            let hole = frame.flatMap { step.litRect(around: $0, in: size) }
            // With nothing to light, the hole is a point in the middle: the scrim covers everything.
            let spot = hole ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0)
            let radius = step.cornerRadius.map { $0 + step.padding } ?? min(spot.width, spot.height) / 2

            ZStack {
                // Takes every touch, the lit area included, so nothing under the tutorial can be used until it's done.
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture {}
                    .accessibilityHidden(true)

                SpotlightMask(hole: spot, cornerRadius: radius)
                    .fill(.black.opacity(0.72), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if hole != nil {
                    SpotlightGlow(hole: spot, cornerRadius: radius, pulses: !reduceMotion)
                }

                TutorialCard(
                    step: step,
                    index: controller.index,
                    count: controller.steps.count,
                    onBack: controller.back,
                    onNext: controller.next,
                    onSkip: controller.end
                )
                .frame(maxWidth: 440)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                // Hidden until measured, so it never shows in a place picked for a card of no height.
                .opacity(cardHeight > 0 ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                // Moved rather than padded, so the card is always offered the whole height to measure itself in.
                .offset(y: cardTop(beside: hole, in: size))
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: cardHeight)
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.55), value: controller.index)
        // The Mac and iPad keyboards: arrows and Return step through, Escape skips. The screen's own arrow keys
        // swipe the deck, so this takes the keyboard while the tutorial is up and swallows the up and down arrows.
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(.rightArrow) { controller.next(); return .handled }
        .onKeyPress(.return) { controller.next(); return .handled }
        .onKeyPress(.leftArrow) { controller.back(); return .handled }
        .onKeyPress(.escape) { controller.end(); return .handled }
        .onKeyPress(.upArrow) { .handled }
        .onKeyPress(.downArrow) { .handled }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { controller.end() }
    }

    /// Where the card's top edge goes, in the overlay's own space, which stops at the safe area (under the
    /// navigation bar, above the home indicator). Next to the lit area without covering it: above it when it is in
    /// the lower half, below it otherwise, or the other side if the first has no room. When neither side has room
    /// for the whole card, it takes the roomier one and covers as little of the lit area as it must.
    private func cardTop(beside hole: CGRect?, in size: CGSize) -> CGFloat {
        let margin: CGFloat = 8
        let gap: CGFloat = 12
        let height = min(cardHeight, size.height - 2 * margin)
        let lowest = size.height - margin - height
        guard let hole else { return lowest }

        let above = hole.minY - gap - height
        let below = hole.maxY + gap
        let fits = margin...max(margin, lowest)
        let (first, second) = hole.midY > size.height / 2 ? (above, below) : (below, above)
        if fits.contains(first) { return first }
        if fits.contains(second) { return second }
        let roomAbove = hole.minY - gap - margin
        let roomBelow = size.height - margin - hole.maxY - gap
        return roomAbove >= roomBelow ? margin : lowest
    }
}

/// Everything with a rounded hole in it, for an even-odd fill, so the hole glides when `hole` animates. The outside
/// reaches far past the overlay, which stops at the safe area, so the dimming covers the bars too.
@Animatable
private nonisolated struct SpotlightMask: Shape {
    var hole: CGRect
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -3000, dy: -3000))
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: .continuous)
        return path
    }
}

/// A soft accent ring around the hole that breathes (Android's pulsing stroke). Still with Reduce Motion.
private struct SpotlightGlow: View {
    let hole: CGRect
    let cornerRadius: CGFloat
    let pulses: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
            .frame(width: hole.width, height: hole.height)
            .position(x: hole.midX, y: hole.midY)
            .phaseAnimator(pulses ? [0.5, 1] : [0.9]) { ring, opacity in
                ring.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The words: a title with Skip, the message, page dots, and Back and Next. Android's `TooltipCard`.
private struct TutorialCard: View {
    let step: TutorialStep
    let index: Int
    let count: Int
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var titleHasFocus: Bool

    var body: some View {
        // At the largest text sizes the card scrolls instead of running off the screen.
        ViewThatFits(in: .vertical) {
            card
            ScrollView { card }
                .scrollBounceBehavior(.basedOnSize)
        }
        // VoiceOver starts at the title of each step.
        .task(id: step.id) {
            try? await Task.sleep(for: .milliseconds(150))
            titleHasFocus = true
        }
    }

    private var card: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleHasFocus)
                    Spacer(minLength: 12)
                    Button("Skip", action: onSkip)
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Text(step.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    StepDots(index: index, count: count)
                    Spacer(minLength: 8)
                    if index > 0 {
                        Button("Back", action: onBack)
                            .buttonStyle(.bordered)
                    }
                    Button(action: onNext) {
                        if index == count - 1 {
                            Text("Got it!")
                        } else {
                            Text("Next")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .buttonBorderShape(.capsule)
            }
            .padding(16)
            // Each step's words swap in place while the card around them glides to its new size.
            .id(step.id)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

#if DEBUG
/// A stand-in for the swipe screen with its three targets, to see the tutorial in the canvas.
private struct TutorialPreviewScreen: View {
    let startingAt: Int
    @State private var tutorial = TutorialController()
    @State private var motion = CardMotion()
    @State private var demo = GestureDemo()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Capsule().fill(.gray.opacity(0.25)).frame(height: 44)
                    .tutorialTarget("header")
                    .padding(.horizontal)
                // The chevron and the thumbnail strip the real screen has above its card.
                Color.clear.frame(height: 20)
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.gray.opacity(0.25)).frame(height: 76)
                    .padding(.horizontal)
                // The card the demo swipes, with the stamp the real card shows.
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.blue.gradient)
                    .overlay {
                        Text(motion.offset.width > 20 ? "KEEP" : motion.offset.width < -20 ? "DELETE" : "")
                            .font(.system(.largeTitle, design: .rounded, weight: .black))
                            .foregroundStyle(motion.offset.width > 0 ? .green : .red)
                    }
                    .offset(motion.offset)
                    .rotationEffect(.degrees(motion.offset.width / 25))
                    .overlay { GhostFinger(demo: demo, motion: motion) }
                    .tutorialTarget("deck")
                    .padding(.horizontal)
                Capsule().fill(.gray.opacity(0.25)).frame(height: 60)
                    .tutorialTarget("actions")
                    .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .tutorialOverlay(tutorial)
            .navigationTitle("Holiday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset Decisions", systemImage: "arrow.clockwise") {}
                        .disabled(tutorial.isActive)
                }
            }
        }
        .task {
            tutorial.start(TutorialStep.swipeDeck(swipes: .default)) {}
            for _ in 0..<startingAt { tutorial.next() }
        }
        .task(id: tutorial.step?.id == "gestures") {
            guard tutorial.step?.id == "gestures" else { return }
            await demo.run(on: motion, swipes: .default, canUndo: false)
        }
    }
}

/// A stand-in for the duplicates screen: groups in a scrolling list, each with its photos inside it, and the pill above.
private struct TutorialDuplicatesPreview: View {
    let startingAt: Int
    @State private var tutorial = TutorialController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Capsule().fill(.gray.opacity(0.25)).frame(height: 44)
                    .tutorialTarget("delete")
                    .padding(.horizontal)
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(0..<4, id: \.self) { group in
                            VStack(spacing: 14) {
                                Text("\(group + 2) items").font(.headline)
                                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.orange.gradient).frame(height: 170)
                                    .tutorialTarget("photos#\(group)")
                                Capsule().fill(.gray.opacity(0.25)).frame(height: 44)
                            }
                            .padding(16)
                            .background(.background.secondary, in: .rect(cornerRadius: 28, style: .continuous))
                            .tutorialTarget("cluster#\(group)")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 40)
                }
            }
            .tutorialOverlay(tutorial)
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            tutorial.start(TutorialStep.duplicates) {}
            for _ in 0..<startingAt { tutorial.next() }
        }
    }
}

#Preview("Gestures") { TutorialPreviewScreen(startingAt: 0) }
#Preview("Progress, dark") { TutorialPreviewScreen(startingAt: 1).preferredColorScheme(.dark) }
#Preview("Actions") { TutorialPreviewScreen(startingAt: 2) }
#Preview("Duplicates: groups") { TutorialDuplicatesPreview(startingAt: 0) }
#Preview("Duplicates: photos") { TutorialDuplicatesPreview(startingAt: 1) }
#Preview("Duplicates: delete") { TutorialDuplicatesPreview(startingAt: 2) }
#endif

/// Where the tutorial is, as dots, with the current one stretched. Reads "Step 2 of 3" to VoiceOver, as Android's badge does.
private struct StepDots: View {
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: dot == index ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}
