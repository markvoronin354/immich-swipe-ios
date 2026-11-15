import SwiftUI

// MARK: - Choices

// Raw values match the Android app, so a backup or a future settings import means the same thing in both.

nonisolated enum AppTheme: String, CaseIterable, Sendable {
    case system = "SYSTEM", light = "LIGHT", dark = "DARK"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

nonisolated enum DoubleTapAction: String, CaseIterable, Sendable {
    case fullscreen = "FULLSCREEN", favorite = "FAVORITE"
}

nonisolated enum ImmichOpenMode: String, CaseIterable, Sendable {
    case app = "APP", web = "WEB"

    var other: ImmichOpenMode { self == .app ? .web : .app }
}

nonisolated enum IconPosition: String, CaseIterable, Sendable {
    case topLeft = "TOP_LEFT", topRight = "TOP_RIGHT", bottomLeft = "BOTTOM_LEFT", bottomRight = "BOTTOM_RIGHT"

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeading: Bool { self == .topLeft || self == .bottomLeft }
}

nonisolated enum ButtonStackOrientation: String, CaseIterable, Sendable {
    case vertical = "VERTICAL", horizontal = "HORIZONTAL"
}

nonisolated enum ReminderInterval: String, CaseIterable, Sendable {
    case often = "OFTEN", rarely = "RARELY", custom = "CUSTOM"

    /// Days between reminders, picked at random inside this range.
    func dayRange(customMin: Int, customMax: Int) -> ClosedRange<Int> {
        switch self {
        case .often: 7...14
        case .rarely: 21...35
        case .custom:
            // At least a day, and never an empty range.
            max(customMin, 1)...max(customMax, customMin, 1)
        }
    }
}

// MARK: - Keys and defaults

/// Where each setting lives in `UserDefaults`, and what it is until the user changes it.
/// Keys and defaults follow the Android app (spec §4). Use with `@AppStorage`, so the settings
/// screen and the views that obey a setting can never disagree about the default.
nonisolated enum Setting {
    enum Key {
        static let theme = "theme_mode"

        static let showFullscreenButton = "show_fullscreen_icon"
        static let showRotateButton = "show_card_display_icon" // Android's name for the rotate button
        static let showImmichButton = "show_immich_icon"
        static let fullscreenPosition = "fullscreen_icon_pos"
        static let rotatePosition = "card_display_icon_pos"
        static let immichPosition = "immich_icon_pos"
        static let stackOrientation = "button_stack_orientation"
        static let immichOpenMode = "immich_open_mode"
        static let showMuteButton = "show_mute_icon"
        static let showDownloadButton = "show_download_icon"
        static let showShareButton = "show_share_icon"
        static let showFullResolutionButton = "show_full_size_icon"
        static let mutePosition = "mute_icon_pos"
        static let downloadPosition = "download_icon_pos"
        static let sharePosition = "share_icon_pos"
        static let fullResolutionPosition = "full_size_icon_pos"
        static let keepFullResolution = "keep_full_resolution"

        static let showFavoriteButton = "show_favorite"
        static let showArchiveButton = "show_archive"
        static let showLockButton = "show_lock"
        static let showAddToAlbumButton = "show_add_to_album"
        static let showSwipeButtons = "show_swipe_buttons"
        static let showToolbarLabels = "show_toolbar_labels"
        static let toolbarButtonOrder = "toolbar_button_order"
        static let autoNextOnFavorite = "auto_next_on_fav"
        static let tapToSwipe = "tap_to_swipe"
        static let doubleTapEnabled = "double_tap_enabled"
        static let doubleTapAction = "double_tap_action"
        static let showTimeline = "show_timeline"
        static let includeArchived = "include_archived"

        static let reminderEnabled = "reminder_enabled"
        static let reminderInterval = "reminder_interval"
        static let reminderCustomMinDays = "reminder_custom_min_days"
        static let reminderCustomMaxDays = "reminder_custom_max_days"

        static let backupWarningShown = "backup_warning_shown"
    }

    enum Default {
        static let theme = AppTheme.system

        static let showFullscreenButton = true
        static let showRotateButton = true
        static let showImmichButton = false
        static let fullscreenPosition = IconPosition.topRight
        static let rotatePosition = IconPosition.topLeft
        static let immichPosition = IconPosition.bottomLeft
        static let stackOrientation = ButtonStackOrientation.vertical
        static let immichOpenMode = ImmichOpenMode.app
        static let showMuteButton = true
        static let showDownloadButton = true
        static let showShareButton = false
        static let showFullResolutionButton = true
        static let mutePosition = IconPosition.bottomRight
        static let downloadPosition = IconPosition.bottomLeft
        static let sharePosition = IconPosition.bottomRight
        static let fullResolutionPosition = IconPosition.bottomRight
        static let keepFullResolution = false

        static let showFavoriteButton = true
        static let showArchiveButton = true
        static let showLockButton = false
        static let showAddToAlbumButton = true
        static let showSwipeButtons = false
        static let showToolbarLabels = true
        /// Empty means the default order; see `SortingBarButton.order(from:)`.
        static let toolbarButtonOrder = ""
        static let autoNextOnFavorite = false
        static let tapToSwipe = false
        static let doubleTapEnabled = true
        static let doubleTapAction = DoubleTapAction.fullscreen
        static let showTimeline = true
        /// On by default, as on Android: decks and counts include photos archived in Immich.
        static let includeArchived = true

        static let reminderEnabled = false
        static let reminderInterval = ReminderInterval.often
        static let reminderCustomMinDays = 3
        static let reminderCustomMaxDays = 7

        static let backupWarningShown = false
    }
}

// MARK: - Toolbar buttons

/// The bottom bar's middle buttons, which can be reordered, in their default order (Android's `ToolbarButton`).
/// Undo comes before them and Sort after; Delete and Keep stay at the ends.
nonisolated enum SortingBarButton: String, CaseIterable, Sendable {
    case archive = "ARCHIVE", favorite = "FAVORITE", album = "ALBUM", lock = "LOCK"

    /// The saved order, stored comma-separated as on Android. Unknown names are dropped and missing
    /// buttons go at the end, in the default order.
    static func order(from saved: String) -> [SortingBarButton] {
        var order: [SortingBarButton] = []
        for button in saved.split(separator: ",").compactMap({ SortingBarButton(rawValue: String($0)) }) + allCases where !order.contains(button) {
            order.append(button)
        }
        return order
    }

    static func saved(_ order: [SortingBarButton]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// Moves buttons among the ones shown. Hidden buttons keep their places in the full order, as on Android,
    /// where only the visible tiles can be dragged.
    static func moving(_ order: [SortingBarButton], shown: [SortingBarButton], from source: IndexSet, to destination: Int) -> [SortingBarButton] {
        var moved = shown
        moved.move(fromOffsets: source, toOffset: destination)
        var remaining = moved.makeIterator()
        return order.map { shown.contains($0) ? remaining.next() ?? $0 : $0 }
    }

    /// The bar's label, Android's `swipe_archive`, `swipe_label_favorite`, `swipe_label_album`, `swipe_locked`.
    var title: LocalizedStringKey {
        switch self {
        case .archive: "Archive"
        case .favorite: "Favorite"
        case .album: "Album"
        case .lock: "Lock"
        }
    }

    var systemImage: String {
        switch self {
        case .archive: "archivebox"
        case .favorite: "heart"
        case .album: "plus.rectangle.on.rectangle"
        case .lock: "lock"
        }
    }
}

// MARK: - Card buttons

/// One of the round buttons that can sit in a corner of the card.
/// The declaration order is the order buttons stack in when they share a corner.
nonisolated enum CardButton: CaseIterable, Hashable, Sendable {
    case fullscreen, rotate, immich, mute, download, share, fullResolution
}

/// Which buttons go in which corner, in order. Pure, so it's easy to test and the same rules apply
/// to the card and to the settings preview.
nonisolated struct CardButtonLayout: Equatable, Sendable {
    var show: [CardButton: Bool]
    var position: [CardButton: IconPosition]
    var orientation: ButtonStackOrientation

    static let `default` = CardButtonLayout(
        show: [
            .fullscreen: Setting.Default.showFullscreenButton,
            .rotate: Setting.Default.showRotateButton,
            .immich: Setting.Default.showImmichButton,
            .mute: Setting.Default.showMuteButton,
            .download: Setting.Default.showDownloadButton,
            .share: Setting.Default.showShareButton,
            .fullResolution: Setting.Default.showFullResolutionButton,
        ],
        position: [
            .fullscreen: Setting.Default.fullscreenPosition,
            .rotate: Setting.Default.rotatePosition,
            .immich: Setting.Default.immichPosition,
            .mute: Setting.Default.mutePosition,
            .download: Setting.Default.downloadPosition,
            .share: Setting.Default.sharePosition,
            .fullResolution: Setting.Default.fullResolutionPosition,
        ],
        orientation: Setting.Default.stackOrientation
    )

    /// Whether a button makes sense for this kind of photo: sound only matters for videos,
    /// "full resolution" is about loading the original image, and only images can be rotated.
    static func applies(_ button: CardButton, toVideo isVideo: Bool) -> Bool {
        switch button {
        case .mute: isVideo
        case .fullResolution, .rotate: !isVideo
        default: true
        }
    }

    /// Visible buttons per corner for a photo or a video. Buttons that don't apply take no space.
    func buttons(in corner: IconPosition, isVideo: Bool = false) -> [CardButton] {
        CardButton.allCases.filter {
            show[$0] == true && position[$0] == corner && Self.applies($0, toVideo: isVideo)
        }
    }
}

// MARK: - Taps

/// What a tap on the card does when "Tap to swipe" is on: the left third deletes, the right third
/// keeps, and the middle is left alone so the card's own buttons stay usable.
nonisolated enum CardTapRules {
    static let edgeFraction = 0.3

    static func decision(atX x: Double, width: Double, tapToSwipe: Bool) -> SwipeDecision? {
        guard tapToSwipe, width > 0 else { return nil }
        if x < width * edgeFraction { return .delete }
        if x > width * (1 - edgeFraction) { return .keep }
        return nil
    }
}
