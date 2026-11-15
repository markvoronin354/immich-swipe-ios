import SwiftUI

/// Which bottom-bar buttons show, and how tapping the card behaves.
struct InteractionsSettingsView: View {
    @AppStorage(Setting.Key.showAddToAlbumButton) private var showAddToAlbum = Setting.Default.showAddToAlbumButton
    @AppStorage(Setting.Key.showSwipeButtons) private var showSwipeButtons = Setting.Default.showSwipeButtons
    @AppStorage(Setting.Key.showArchiveButton) private var showArchive = Setting.Default.showArchiveButton
    @AppStorage(Setting.Key.showLockButton) private var showLock = Setting.Default.showLockButton
    @AppStorage(Setting.Key.showFavoriteButton) private var showFavorite = Setting.Default.showFavoriteButton
    @AppStorage(Setting.Key.autoNextOnFavorite) private var autoNext = Setting.Default.autoNextOnFavorite
    @AppStorage(Setting.Key.tapToSwipe) private var tapToSwipe = Setting.Default.tapToSwipe
    @AppStorage(Setting.Key.doubleTapEnabled) private var doubleTapEnabled = Setting.Default.doubleTapEnabled
    @AppStorage(Setting.Key.doubleTapAction) private var doubleTapAction = Setting.Default.doubleTapAction
    @AppStorage(Setting.Key.showTimeline) private var showTimeline = Setting.Default.showTimeline
    @AppStorage(Setting.Key.showToolbarLabels) private var showLabels = Setting.Default.showToolbarLabels
    @AppStorage(Setting.Key.toolbarButtonOrder) private var savedOrder = Setting.Default.toolbarButtonOrder

    private var order: [SortingBarButton] { SortingBarButton.order(from: savedOrder) }

    private var shownButtons: [SortingBarButton] {
        order.filter { button in
            switch button {
            case .archive: showArchive
            case .favorite: showFavorite
            case .album: showAddToAlbum
            case .lock: showLock
            }
        }
    }

    var body: some View {
        // A plain scroll view with hand-drawn grouped cards rather than a Form. Inside a List, the row's own
        // long-press takes over and lifts the whole toolbar preview instead of one button; pinned above the
        // Form, the preview didn't scroll with the page as it does on Android. This keeps both.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if shownButtons.count > 1 {
                    toolbarPreview
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                SettingsCard(header: "Toolbar") {
                    SettingsRow { Toggle("Button labels", isOn: $showLabels) }
                    SettingsRow { Toggle("Add to album button", isOn: $showAddToAlbum) }
                    SettingsRow { Toggle("Keep/Delete buttons", isOn: $showSwipeButtons) }
                    SettingsRow { Toggle("Archive button", isOn: $showArchive) }
                    SettingsRow { Toggle("Lock button", isOn: $showLock) }
                    // The line under Favorite starts at the indented Auto-advance row, like Android's divider.
                    SettingsRow(separatorInset: showFavorite ? 20 : 0, isLast: !showFavorite) {
                        Toggle("Favorite button", isOn: $showFavorite)
                    }
                    if showFavorite {
                        // Indented under Favorite with its description right below, like Android.
                        SettingsRow(isLast: true) {
                            Toggle(isOn: $autoNext) {
                                Text("Auto-advance")
                                Text("Moves to the next photo and marks the current one as Keep after you favorite it.")
                            }
                            .padding(.leading, 20)
                        }
                    }
                }

                SettingsCard(header: "Actions", footer: "Tap to swipe: tap the left ⅓ of the card to delete and the right ⅓ to keep. The middle ⅓ is left free for the card's buttons.") {
                    SettingsRow { Toggle("Tap to swipe", isOn: $tapToSwipe) }
                    SettingsRow(isLast: !doubleTapEnabled) { Toggle("Double tap", isOn: $doubleTapEnabled) }
                    if doubleTapEnabled {
                        SettingsRow(isLast: true) {
                            Picker("Double tap does", selection: $doubleTapAction) {
                                Text("Fullscreen").tag(DoubleTapAction.fullscreen)
                                Text("Favorite").tag(DoubleTapAction.favorite)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                // Not in the Android app, where the timeline always shows.
                SettingsCard(header: "Layout") {
                    SettingsRow(isLast: true) { Toggle("Asset timeline", isOn: $showTimeline) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        // The toggles write straight to storage, so animate here: the preview slides in and out, and its
        // buttons come and go, as buttons are turned on and off.
        .animation(.snappy, value: shownButtons)
        .animation(.snappy, value: showFavorite)
        .animation(.snappy, value: doubleTapEnabled)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Interactions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// As on Android, the buttons are rearranged by dragging them sideways in a toolbar preview, in the
    /// order they sit between Undo and Sort.
    private var toolbarPreview: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(shownButtons, id: \.self) { button in
                    VStack(spacing: 4) {
                        Image(systemName: button.systemImage)
                            .font(.title3)
                            .frame(height: 28)
                        Text(button.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(.dragPreview, .rect(cornerRadius: 12))
                    .contentShape(.rect)
                    .frame(maxWidth: .infinity)
                }
                .reorderable()
            }
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            .reorderContainer(for: SortingBarButton.self, itemID: \.self) { difference in
                let source = IndexSet(difference.sources.compactMap { shownButtons.firstIndex(of: $0) })
                let destination = switch difference.destination.position {
                case .before(let button): shownButtons.firstIndex(of: button) ?? shownButtons.count
                case .end: shownButtons.count
                }
                withAnimation {
                    savedOrder = SortingBarButton.saved(SortingBarButton.moving(order, shown: shownButtons, from: source, to: destination))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Toolbar preview")

            Text("Long-press and drag to rearrange buttons")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

/// One grouped section of the Interactions page, drawn to match the system inset grouped list.
private struct SettingsCard<Content: View>: View {
    let header: LocalizedStringKey
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            VStack(spacing: 0) { content }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 28)
    }
}

/// A row in a `SettingsCard`, with the list's row insets and a separator under it unless it's the last.
private struct SettingsRow<Content: View>: View {
    var separatorInset: CGFloat = 0
    var isLast = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider().padding(.leading, 20 + separatorInset)
                }
            }
    }
}

/// Where each button on the swipe card sits, whether it shows, and how buttons in one corner stack.
struct ActionButtonsSettingsView: View {
    @AppStorage(Setting.Key.showFullscreenButton) private var showFullscreen = Setting.Default.showFullscreenButton
    @AppStorage(Setting.Key.showRotateButton) private var showRotate = Setting.Default.showRotateButton
    @AppStorage(Setting.Key.showImmichButton) private var showImmich = Setting.Default.showImmichButton
    @AppStorage(Setting.Key.fullscreenPosition) private var fullscreenPosition = Setting.Default.fullscreenPosition
    @AppStorage(Setting.Key.rotatePosition) private var rotatePosition = Setting.Default.rotatePosition
    @AppStorage(Setting.Key.immichPosition) private var immichPosition = Setting.Default.immichPosition
    @AppStorage(Setting.Key.stackOrientation) private var orientation = Setting.Default.stackOrientation
    @AppStorage(Setting.Key.immichOpenMode) private var openMode = Setting.Default.immichOpenMode
    @AppStorage(Setting.Key.showMuteButton) private var showMute = Setting.Default.showMuteButton
    @AppStorage(Setting.Key.showDownloadButton) private var showDownload = Setting.Default.showDownloadButton
    @AppStorage(Setting.Key.showShareButton) private var showShare = Setting.Default.showShareButton
    @AppStorage(Setting.Key.showFullResolutionButton) private var showFullResolution = Setting.Default.showFullResolutionButton
    @AppStorage(Setting.Key.mutePosition) private var mutePosition = Setting.Default.mutePosition
    @AppStorage(Setting.Key.downloadPosition) private var downloadPosition = Setting.Default.downloadPosition
    @AppStorage(Setting.Key.sharePosition) private var sharePosition = Setting.Default.sharePosition
    @AppStorage(Setting.Key.fullResolutionPosition) private var fullResolutionPosition = Setting.Default.fullResolutionPosition
    @AppStorage(Setting.Key.keepFullResolution) private var keepFullResolution = Setting.Default.keepFullResolution
    @State private var isConfirmingReset = false

    private var layout: CardButtonLayout {
        CardButtonLayout(
            show: [
                .fullscreen: showFullscreen, .rotate: showRotate, .immich: showImmich,
                .mute: showMute, .download: showDownload, .share: showShare, .fullResolution: showFullResolution,
            ],
            position: [
                .fullscreen: fullscreenPosition, .rotate: rotatePosition, .immich: immichPosition,
                .mute: mutePosition, .download: downloadPosition, .share: sharePosition, .fullResolution: fullResolutionPosition,
            ],
            orientation: orientation
        )
    }

    var body: some View {
        Form {
            Section {
                CardLayoutPreview(layout: layout)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker("Stacking direction", selection: $orientation) {
                    Text("Vertically").tag(ButtonStackOrientation.vertical)
                    Text("Horizontally").tag(ButtonStackOrientation.horizontal)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Button Stacking")
            } footer: {
                Text("How buttons stack when they share a corner.")
            }

            ButtonSection(title: "Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", show: $showFullscreen, position: $fullscreenPosition)
            ButtonSection(title: "Rotate", systemImage: "arrow.clockwise", show: $showRotate, position: $rotatePosition)
            ButtonSection(title: "Open in Immich", systemImage: "arrow.up.forward.square", show: $showImmich, position: $immichPosition) {
                Picker("Open mode", selection: $openMode) {
                    Text("App").tag(ImmichOpenMode.app)
                    Text("Web").tag(ImmichOpenMode.web)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Touch and hold the button on a card to use the other mode. If the Immich app isn't installed, the web page opens instead.")
            }

            ButtonSection(title: "Mute", systemImage: "speaker.slash", show: $showMute, position: $mutePosition) {
                EmptyView()
            } footer: {
                Text("Only appears on videos.")
            }
            ButtonSection(title: "Download", systemImage: "arrow.down.to.line", show: $showDownload, position: $downloadPosition) {
                EmptyView()
            } footer: {
                Text("Saves the original to your Photos library.")
            }
            ButtonSection(title: "Share", systemImage: "square.and.arrow.up", show: $showShare, position: $sharePosition) {
                EmptyView()
            } footer: {
                Text("Shares the original with another app.")
            }
            ButtonSection(title: "Full Resolution", systemImage: CardGlyph.hd, show: $showFullResolution, position: $fullResolutionPosition) {
                Toggle("Stay enabled while swiping", isOn: $keepFullResolution)
            } footer: {
                Text("Loads the original instead of a preview. Only appears on photos, and uses more data.")
            }

            Section {
                Button("Reset to defaults", systemImage: "arrow.counterclockwise") {
                    isConfirmingReset = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Reset Action Buttons?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive, action: resetToDefaults)
        } message: {
            Text("All action buttons will go back to their default positions, stacking and visibility.")
        }
        .navigationTitle("Action Buttons")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func resetToDefaults() {
        showFullscreen = Setting.Default.showFullscreenButton
        showRotate = Setting.Default.showRotateButton
        showImmich = Setting.Default.showImmichButton
        showMute = Setting.Default.showMuteButton
        showDownload = Setting.Default.showDownloadButton
        showShare = Setting.Default.showShareButton
        showFullResolution = Setting.Default.showFullResolutionButton
        fullscreenPosition = Setting.Default.fullscreenPosition
        rotatePosition = Setting.Default.rotatePosition
        immichPosition = Setting.Default.immichPosition
        mutePosition = Setting.Default.mutePosition
        downloadPosition = Setting.Default.downloadPosition
        sharePosition = Setting.Default.sharePosition
        fullResolutionPosition = Setting.Default.fullResolutionPosition
        orientation = Setting.Default.stackOrientation
        openMode = Setting.Default.immichOpenMode
        keepFullResolution = Setting.Default.keepFullResolution
    }
}

private struct ButtonSection<Extra: View, Footer: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var show: Bool
    @Binding var position: IconPosition
    @ViewBuilder var extra: Extra
    @ViewBuilder var footer: Footer

    var body: some View {
        Section {
            Toggle(isOn: $show) {
                Label { Text(title) } icon: { CardGlyph(name: systemImage) }
            }
            if show {
                Picker("Position", selection: $position) {
                    ForEach(IconPosition.allCases, id: \.self) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                extra
            }
        } footer: {
            footer
        }
        // Position and the extra options slide in and out as the button is turned on and off.
        .animation(.snappy, value: show)
    }
}

extension ButtonSection where Extra == EmptyView, Footer == EmptyView {
    init(title: LocalizedStringKey, systemImage: String, show: Binding<Bool>, position: Binding<IconPosition>) {
        self.init(title: title, systemImage: systemImage, show: show, position: position, extra: { EmptyView() }, footer: { EmptyView() })
    }
}

extension IconPosition {
    var title: LocalizedStringKey {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// A small card showing where the buttons will land, using the same layout rules as the real card.
struct CardLayoutPreview: View {
    let layout: CardButtonLayout
    /// Sound only exists on videos and full resolution only on photos, so the preview can show either.
    var previewsVideo = false

    private let cardSize = CGSize(width: 150, height: 210)
    private let inset: CGFloat = 10
    private let buttonSize: CGFloat = 30
    private let buttonSpacing: CGFloat = 6

    /// How much to shrink the buttons so no row or column of corners runs past the card's edge.
    private var buttonScale: CGFloat {
        let stacksHorizontally = layout.orientation == .horizontal
        var scale: CGFloat = 1
        for isRow in [true, false] {
            let pairs: [(IconPosition, IconPosition)] = isRow
                ? [(.topLeft, .topRight), (.bottomLeft, .bottomRight)]
                : [(.topLeft, .bottomLeft), (.topRight, .bottomRight)]
            let available = (isRow ? cardSize.width : cardSize.height) - 2 * inset
            for (first, second) in pairs {
                let total = extent(of: first, along: isRow == stacksHorizontally)
                    + extent(of: second, along: isRow == stacksHorizontally) + buttonSpacing
                scale = min(scale, available / total)
            }
        }
        return scale
    }

    /// The length a corner's stack takes along one axis, at full size.
    private func extent(of position: IconPosition, along stackAxis: Bool) -> CGFloat {
        let count = CGFloat(layout.buttons(in: position, isVideo: previewsVideo).count)
        guard count > 0 else { return 0 }
        return stackAxis ? count * buttonSize + (count - 1) * buttonSpacing : buttonSize
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(.quaternary)
            .overlay { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary) }
            .overlay {
                VStack {
                    HStack(alignment: .top) {
                        corner(.topLeft)
                        Spacer()
                        corner(.topRight)
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        corner(.bottomLeft)
                        Spacer()
                        corner(.bottomRight)
                    }
                }
                .padding(inset)
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func corner(_ position: IconPosition) -> some View {
        let scale = buttonScale
        let stack = layout.orientation == .vertical
            ? AnyLayout(VStackLayout(spacing: buttonSpacing * scale))
            : AnyLayout(HStackLayout(spacing: buttonSpacing * scale))
        stack {
            ForEach(layout.buttons(in: position, isVideo: previewsVideo), id: \.self) { button in
                CardGlyph(name: button.symbol)
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize * scale, height: buttonSize * scale)
                    .background(.black.opacity(0.65), in: .circle)
            }
        }
    }
}

extension CardButton {
    var symbol: String {
        switch self {
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .rotate: "arrow.clockwise"
        case .immich: "arrow.up.forward.square"
        case .mute: "speaker.wave.2.fill"
        case .download: "arrow.down.to.line"
        case .share: "square.and.arrow.up"
        case .fullResolution: CardGlyph.hd
        }
    }
}

#Preview("Action Buttons") {
    NavigationStack { ActionButtonsSettingsView() }
}

#Preview("Interactions") {
    NavigationStack { InteractionsSettingsView() }
}
