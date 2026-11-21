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
    @AppStorage(Setting.Key.showToolbarLabels) private var showLabels = Setting.Default.showToolbarLabels
    @AppStorage(Setting.Key.toolbarButtonOrder) private var savedOrder = Setting.Default.toolbarButtonOrder
    @State private var isConfirmingReset = false

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

                SettingsCard(header: "Actions", footer: "Tap to swipe: tap the left ⅓ of the card to swipe left and the right ⅓ to swipe right. The middle ⅓ is left free for the card's buttons.") {
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

                ResetButton { isConfirmingReset = true }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .alert("Reset Interactions?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive, action: resetToDefaults)
        } message: {
            Text("The toolbar and tap gestures will go back to their defaults.")
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

    /// Everything this screen edits, as Android's `resetInteractions` does. The swipe actions and the Info
    /// button, which they can turn on, are left alone: resetting here must not take away the way into the details.
    private func resetToDefaults() {
        showLabels = Setting.Default.showToolbarLabels
        showAddToAlbum = Setting.Default.showAddToAlbumButton
        showSwipeButtons = Setting.Default.showSwipeButtons
        showArchive = Setting.Default.showArchiveButton
        showLock = Setting.Default.showLockButton
        showFavorite = Setting.Default.showFavoriteButton
        autoNext = Setting.Default.autoNextOnFavorite
        savedOrder = Setting.Default.toolbarButtonOrder
        tapToSwipe = Setting.Default.tapToSwipe
        doubleTapEnabled = Setting.Default.doubleTapEnabled
        doubleTapAction = Setting.Default.doubleTapAction
    }

    /// As on Android, the buttons are rearranged by dragging them sideways in a toolbar preview, in the
    /// order they sit between Undo and Sort. iOS 26 can only drag to reorder inside a list, so there the
    /// preview just shows the order and a list on its own page rearranges it.
    private var toolbarPreview: some View {
        VStack(spacing: 8) {
            if #available(iOS 27, *) {
                previewBar {
                    ForEach(shownButtons, id: \.self, content: previewButton)
                        .reorderable()
                }
                .reorderContainer(for: SortingBarButton.self, itemID: \.self) { difference in
                    let source = IndexSet(difference.sources.compactMap { shownButtons.firstIndex(of: $0) })
                    let destination = switch difference.destination.position {
                    case .before(let button): shownButtons.firstIndex(of: button) ?? shownButtons.count
                    case .end: shownButtons.count
                    }
                    moveButtons(from: source, to: destination)
                }

                Text("Long-press and drag to rearrange buttons")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                previewBar {
                    ForEach(shownButtons, id: \.self, content: previewButton)
                }

                NavigationLink {
                    ToolbarOrderList(buttons: shownButtons, move: moveButtons)
                } label: {
                    Label("Rearrange buttons", systemImage: "arrow.left.arrow.right")
                        .font(.footnote)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func previewBar(@ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: 0) { buttons() }
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Toolbar preview")
    }

    private func previewButton(_ button: SortingBarButton) -> some View {
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

    /// Moves shown buttons as `Array.move(fromOffsets:toOffset:)` would, keeping hidden ones where they were.
    private func moveButtons(from source: IndexSet, to destination: Int) {
        withAnimation {
            savedOrder = SortingBarButton.saved(SortingBarButton.moving(order, shown: shownButtons, from: source, to: destination))
        }
    }
}

/// The toolbar's buttons in a list with the system's drag handles, for rearranging them on iOS 26, which
/// can't drag them in the toolbar preview as iOS 27 and Android do.
private struct ToolbarOrderList: View {
    let buttons: [SortingBarButton]
    let move: (IndexSet, Int) -> Void

    var body: some View {
        List {
            Section {
                ForEach(buttons, id: \.self) { button in
                    Label { Text(button.title) } icon: { Image(systemName: button.systemImage) }
                }
                .onMove(perform: move)
            } footer: {
                Text("The order the buttons sit in between Undo and Sort.")
            }
        }
        // Always in edit mode, so the handles show without an Edit button first.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Rearrange Buttons")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One grouped section of the Interactions page, drawn to match the system inset grouped list.
private struct SettingsCard<Content: View>: View {
    var header: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            VStack(spacing: 0) { content }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
        }
        // A card with a header has room for it above; one without sits closer to the navigation bar.
        .padding(.top, header == nil ? 16 : 28)
    }
}

/// The "Reset to defaults" button under a settings page's cards.
private struct ResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
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

/// What each swipe direction does, and whether swiping down in the fullscreen viewer does it too. Android's
/// Swipe actions screen, which has its own reset.
struct SwipeActionsSettingsView: View {
    @AppStorage(Setting.Key.swipeLeftAction) private var swipeLeft = Setting.Default.swipeLeftAction
    @AppStorage(Setting.Key.swipeRightAction) private var swipeRight = Setting.Default.swipeRightAction
    @AppStorage(Setting.Key.swipeUpAction) private var swipeUp = Setting.Default.swipeUpAction
    @AppStorage(Setting.Key.swipeDownAction) private var swipeDown = Setting.Default.swipeDownAction
    @AppStorage(Setting.Key.fullscreenSwipeDownUsesAction) private var fullscreenSwipeDown = Setting.Default.fullscreenSwipeDownUsesAction
    // The Info button lives under Action Buttons, but moving swipe up off Details turns it on.
    @AppStorage(Setting.Key.showInfoButton) private var showInfo = Setting.Default.showInfoButton
    @State private var isConfirmingReset = false

    private var swipes: SwipeMapping { SwipeMapping(left: swipeLeft, right: swipeRight, up: swipeUp, down: swipeDown) }

    /// Left and right can't share an action: picking the other side's hands that side this one's old action.
    private var leftBinding: Binding<SwipeAction> {
        Binding(get: { swipeLeft }, set: { action in
            let mapping = swipes.settingLeft(action)
            (swipeLeft, swipeRight) = (mapping.left, mapping.right)
        })
    }

    private var rightBinding: Binding<SwipeAction> {
        Binding(get: { swipeRight }, set: { action in
            let mapping = swipes.settingRight(action)
            (swipeLeft, swipeRight) = (mapping.left, mapping.right)
        })
    }

    /// Swiping up was the only way into the details panel, so moving it off Details turns on the Info button.
    private var upBinding: Binding<SwipeAction> {
        Binding(get: { swipeUp }, set: { action in
            swipeUp = action
            if action != .details { showInfo = true }
        })
    }

    var body: some View {
        // Hand-drawn grouped cards on a scroll view, like the Interactions page, so the two look alike.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCard {
                    SettingsRow { SwipeActionPicker(title: "Swipe left", choices: SwipeAction.sideChoices, selection: leftBinding) }
                    SettingsRow { SwipeActionPicker(title: "Swipe right", choices: SwipeAction.sideChoices, selection: rightBinding) }
                    SettingsRow { SwipeActionPicker(title: "Swipe up", choices: SwipeAction.upChoices, selection: upBinding) }
                    SettingsRow { SwipeActionPicker(title: "Swipe down", choices: SwipeAction.downChoices, selection: $swipeDown) }
                    SettingsRow(isLast: true) {
                        Toggle(isOn: $fullscreenSwipeDown) {
                            Text("Use swipe down action in fullscreen")
                            Text("Off: swiping down closes the viewer. On: it does what Swipe down does on the card. Swiping up always closes it.")
                        }
                    }
                }

                ResetButton { isConfirmingReset = true }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .alert("Reset Swipe Actions?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive, action: resetToDefaults)
        } message: {
            Text("All four swipe directions will go back to their default actions.")
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Swipe actions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Everything this screen edits, as Android's `resetSwipeActions` does. The Info button stays on.
    private func resetToDefaults() {
        swipeLeft = Setting.Default.swipeLeftAction
        swipeRight = Setting.Default.swipeRightAction
        swipeUp = Setting.Default.swipeUpAction
        swipeDown = Setting.Default.swipeDownAction
        fullscreenSwipeDown = Setting.Default.fullscreenSwipeDownUsesAction
    }
}

/// A row naming a swipe direction, with a menu of what it can do on the right.
private struct SwipeActionPicker: View {
    let title: LocalizedStringKey
    let choices: [SwipeAction]
    @Binding var selection: SwipeAction

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(choices, id: \.self) { action in
                    Label(action.title, systemImage: action.systemImage).tag(action)
                }
            }
            .labelsHidden()
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
    @AppStorage(Setting.Key.stackStyle) private var style = Setting.Default.stackStyle
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
    @AppStorage(Setting.Key.showInfoButton) private var showInfo = Setting.Default.showInfoButton
    @AppStorage(Setting.Key.infoPosition) private var infoPosition = Setting.Default.infoPosition
    @State private var isConfirmingReset = false

    private var layout: CardButtonLayout {
        CardButtonLayout(
            show: [
                .fullscreen: showFullscreen, .info: showInfo, .rotate: showRotate, .immich: showImmich,
                .mute: showMute, .download: showDownload, .share: showShare, .fullResolution: showFullResolution,
            ],
            position: [
                .fullscreen: fullscreenPosition, .info: infoPosition, .rotate: rotatePosition, .immich: immichPosition,
                .mute: mutePosition, .download: downloadPosition, .share: sharePosition, .fullResolution: fullResolutionPosition,
            ],
            orientation: orientation,
            style: style
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
                Picker("Direction", selection: $orientation) {
                    Text("Vertically").tag(ButtonStackOrientation.vertical)
                    Text("Horizontally").tag(ButtonStackOrientation.horizontal)
                }
                .pickerStyle(.segmented)
                Picker("Style", selection: $style) {
                    Text("Connected").tag(ButtonStackStyle.connected)
                    Text("Separate").tag(ButtonStackStyle.separate)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Button Stacking")
            } footer: {
                Text("How buttons behave when they share a corner.")
            }

            ButtonSection(title: "Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", show: $showFullscreen, position: $fullscreenPosition)
            ButtonSection(title: "Details", systemImage: CardButton.info.symbol, show: $showInfo, position: $infoPosition)
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
        showInfo = Setting.Default.showInfoButton
        showRotate = Setting.Default.showRotateButton
        showImmich = Setting.Default.showImmichButton
        showMute = Setting.Default.showMuteButton
        showDownload = Setting.Default.showDownloadButton
        showShare = Setting.Default.showShareButton
        showFullResolution = Setting.Default.showFullResolutionButton
        fullscreenPosition = Setting.Default.fullscreenPosition
        infoPosition = Setting.Default.infoPosition
        rotatePosition = Setting.Default.rotatePosition
        immichPosition = Setting.Default.immichPosition
        mutePosition = Setting.Default.mutePosition
        downloadPosition = Setting.Default.downloadPosition
        sharePosition = Setting.Default.sharePosition
        fullResolutionPosition = Setting.Default.fullResolutionPosition
        orientation = Setting.Default.stackOrientation
        style = Setting.Default.stackStyle
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
    /// Connected buttons touch, so only separate ones leave a gap inside a corner.
    private var innerSpacing: CGFloat { layout.style == .connected ? 0 : buttonSpacing }

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
        return stackAxis ? count * buttonSize + (count - 1) * innerSpacing : buttonSize
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
        let buttons = layout.buttons(in: position, isVideo: previewsVideo)
        let merged = buttons.count > 1 && layout.style == .connected
        let stack = layout.orientation == .vertical
            ? AnyLayout(VStackLayout(spacing: innerSpacing * scale))
            : AnyLayout(HStackLayout(spacing: innerSpacing * scale))
        stack {
            ForEach(buttons, id: \.self) { button in
                CardGlyph(name: button.symbol)
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize * scale, height: buttonSize * scale)
                    .background(merged ? Color.clear : Color.black.opacity(0.65), in: .circle)
            }
        }
        .background(merged ? Color.black.opacity(0.65) : Color.clear, in: .capsule)
    }
}

extension CardButton {
    var symbol: String {
        switch self {
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .info: "info"
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

#Preview("Swipe Actions") {
    NavigationStack { SwipeActionsSettingsView() }
}
