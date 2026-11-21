import SwiftUI

/// Five stars to drop the dragged card on, rising over the bottom bar while a card is pulled down (Android's
/// `RatingDropStrip`). The stars up to the one under the finger fill in; each reports its place to `state`
/// under its number. Until the finger is over one, the stars fill to the photo's rating (none when unrated) in a
/// quieter colour. A custom control, like the album strip: no native one lets a drag pick a star.
struct RatingDropStrip: View {
    let state: DropStripState
    /// The photo's rating now, 0 when it has none.
    let currentRating: Int

    /// Held once the drag ends, so the next photo's rating doesn't flash in while the strip slides away.
    @State private var shownRating: Int

    init(state: DropStripState, currentRating: Int) {
        self.state = state
        self.currentRating = currentRating
        _shownRating = State(initialValue: currentRating)
    }

    private var hovered: Int { state.hoveredID.flatMap(Int.init) ?? 0 }

    var body: some View {
        let lit = hovered > 0 ? hovered : shownRating
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                StarTile(star: star, isFilled: star <= lit, isHovering: hovered > 0, isSelected: star == hovered, state: state)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 8)
        // Only a drag reaches it; the rating sheet is the way in without one.
        .accessibilityHidden(true)
        .sensoryFeedback(.selection, trigger: hovered) { _, star in star > 0 }
        .onChange(of: currentRating) {
            if state.isActive { shownRating = currentRating }
        }
    }
}

/// One star of the strip. It grows while the finger is over it.
private struct StarTile: View {
    let star: Int
    let isFilled: Bool
    /// The finger is over some star, so the stars show what dropping would set rather than what the photo has.
    let isHovering: Bool
    let isSelected: Bool
    let state: DropStripState

    private var tint: Color {
        if !isFilled { .secondary } else if isHovering { .accentColor } else { .accentColor.opacity(0.5) }
    }

    var body: some View {
        Image(systemName: isFilled ? "star.fill" : "star")
            .font(.system(size: 38))
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)
            // Measured before the scale, so a star growing under the finger can't push itself away from it.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.tileFrames[String(star)] = $0 }
            .onDisappear { state.tileFrames[String(star)] = nil }
            .scaleEffect(isSelected ? 1.25 : 1)
            .animation(.snappy, value: isSelected)
            .animation(.easeOut(duration: 0.15), value: isFilled)
    }
}

/// Five stars to tap, for rating where there is no strip to drop the card on (Android's `RatingDialog`): the
/// fullscreen viewer, and VoiceOver. Like the album picker it writes to the server itself and says why if it can't.
struct RatingSheet: View {
    let model: DeckModel
    let asset: Asset

    @Environment(\.dismiss) private var dismiss
    @State private var isRating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Button { rate(star) } label: {
                            Image(systemName: "star")
                                .font(.largeTitle)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel(Text("\(star) of 5 stars"))
                    }
                }
                .disabled(isRating)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)
            // From the top, so the stars stay put when a failure message appears under them.
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
            .navigationTitle("Rate this photo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(230)])
    }

    private func rate(_ stars: Int) {
        isRating = true
        errorMessage = nil
        Task {
            defer { isRating = false }
            do {
                try await model.rate(asset, stars: stars)
                dismiss()
            } catch {
                errorMessage = Self.failureMessage(for: error)
            }
        }
    }

    /// Why a rating couldn't be set, for this sheet and for the strip and panel that rate without it.
    static func failureMessage(for error: Error) -> String {
        if let permission = error.missingPermission {
            String(localized: "Couldn't set the rating. Your API key is missing the \(permission) permission.")
        } else {
            error.localizedDescription
        }
    }
}

#Preview("Rating Drop Strip") {
    let state = DropStripState()
    state.move(to: CGPoint(x: 200, y: 700))
    return VStack {
        Spacer()
        RatingDropStrip(state: state, currentRating: 3)
            .padding(.bottom, 8)
    }
}
