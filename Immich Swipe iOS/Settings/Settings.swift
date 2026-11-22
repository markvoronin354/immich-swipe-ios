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

/// What a swipe does (Android's `SwipeAction`). Favorite favourites the photo, then keeps it so the deck moves
/// on. Undo only makes sense for a swipe down and Details for a swipe up, which is what they do by default.
/// Album and Rating only make sense for a swipe down too: the card is dropped on an album or a star, or the
/// album picker or the rating sheet opens.
nonisolated enum SwipeAction: String, CaseIterable, Sendable {
    case keep = "KEEP", delete = "DELETE", archive = "ARCHIVE", lock = "LOCK", favorite = "FAVORITE", undo = "UNDO", details = "DETAILS", album = "ALBUM", rating = "RATING"

    /// The choices for each direction, in Android's order. Undo, Details, Album and Rating are left out of the sides.
    static let sideChoices: [SwipeAction] = [.keep, .delete, .favorite, .archive, .lock]
    static let downChoices: [SwipeAction] = [.keep, .delete, .favorite, .archive, .undo, .lock, .album, .rating]
    static let upChoices: [SwipeAction] = [.keep, .delete, .favorite, .archive, .details, .lock]

    /// Whether pulling the card down shrinks it to be dropped on a strip of targets, rather than swiping it away.
    var isDropTarget: Bool { self == .album || self == .rating }

    /// The decision it records. Favorite keeps the photo; Undo, Details, Album and Rating record nothing, though
    /// dropping the card on an album or a star keeps it.
    var decision: SwipeDecision? {
        switch self {
        case .keep, .favorite: .keep
        case .delete: .delete
        case .archive: .archive
        case .lock: .lock
        case .undo, .details, .album, .rating: nil
        }
    }

    /// Android's `swipe_keep`, `swipe_delete`, `swipe_archive`, `swipe_locked`, `swipe_label_favorite`, `swipe_undo`, `swipe_details`, `swipe_label_album`, `swipe_label_rating`.
    var title: LocalizedStringKey {
        switch self {
        case .keep: "Keep"
        case .delete: "Delete"
        case .archive: "Archive"
        case .lock: "Lock"
        case .favorite: "Favorite"
        case .undo: "Undo"
        case .details: "Details"
        case .album: "Album"
        case .rating: "Rating"
        }
    }

    var systemImage: String {
        switch self {
        case .keep: "checkmark.circle"
        case .delete: "trash"
        case .archive: "archivebox"
        case .lock: "lock"
        case .favorite: "heart"
        case .undo: "arrow.uturn.backward"
        case .details: "info.circle"
        case .album: "plus.rectangle.on.rectangle"
        case .rating: "star"
        }
    }
}

/// What swiping in each direction does. Left and right never share an action: the toolbar's end buttons and
/// the tap zones would otherwise do the same thing.
nonisolated struct SwipeMapping: Equatable, Sendable {
    var left: SwipeAction
    var right: SwipeAction
    var up: SwipeAction
    var down: SwipeAction

    static let `default` = SwipeMapping(left: Setting.Default.swipeLeftAction, right: Setting.Default.swipeRightAction, up: Setting.Default.swipeUpAction, down: Setting.Default.swipeDownAction)

    /// The action for a swipe off this edge: left towards leading, right towards trailing.
    func action(toward edge: Edge) -> SwipeAction {
        switch edge {
        case .leading: left
        case .trailing: right
        case .top: up
        case .bottom: down
        }
    }

    /// Picking the other side's action hands that side this side's old one, as on Android.
    func settingLeft(_ action: SwipeAction) -> SwipeMapping {
        var mapping = self
        if action == right { mapping.right = left }
        mapping.left = action
        return mapping
    }

    func settingRight(_ action: SwipeAction) -> SwipeMapping {
        var mapping = self
        if action == left { mapping.left = right }
        mapping.right = action
        return mapping
    }

    func contains(_ action: SwipeAction) -> Bool {
        [left, right, up, down].contains(action)
    }
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

/// What a playing video does to other audio on the device (Android's `PlaybackBehavior`).
nonisolated enum PlaybackBehavior: String, CaseIterable, Sendable {
    case pauseOthers = "PAUSE_OTHERS", playOverOthers = "IGNORE"
}

nonisolated enum ButtonStackOrientation: String, CaseIterable, Sendable {
    case vertical = "VERTICAL", horizontal = "HORIZONTAL"
}

/// Whether buttons sharing a corner merge into one pill or stay separate circles.
nonisolated enum ButtonStackStyle: String, CaseIterable, Sendable {
    case connected = "CONNECTED", separate = "SEPARATE"
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
        static let stackStyle = "button_stack_style"
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
        static let showInfoButton = "show_info_icon"
        static let infoPosition = "info_icon_pos"

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
        static let syncLocalDeletion = "sync_local_deletion"
        static let playbackBehavior = "audio_focus"
        static let swipeLeftAction = "swipe_left_action"
        static let swipeRightAction = "swipe_right_action"
        static let swipeUpAction = "swipe_up_action"
        static let swipeDownAction = "swipe_down_action"
        static let fullscreenSwipeDownUsesAction = "fullscreen_swipe_down_uses_action"

        static let reminderEnabled = "reminder_enabled"
        static let reminderInterval = "reminder_interval"
        static let reminderCustomMinDays = "reminder_custom_min_days"
        static let reminderCustomMaxDays = "reminder_custom_max_days"

        static let backupWarningShown = "backup_warning_shown"
        static let hasCompletedSwipeTutorial = "has_completed_swipe_tutorial"
        static let hasCompletedDuplicatesTutorial = "has_completed_duplicates_tutorial"
        /// Internal: set once the tutorial flags have been given their first value (see `TutorialFlags`).
        static let initialInstallProcessed = "initial_install_processed"
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
        static let stackStyle = ButtonStackStyle.connected
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
        static let showInfoButton = false
        static let infoPosition = IconPosition.bottomLeft

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
        /// Off, as on Android: deleting from Immich leaves the device's Photos library alone.
        static let syncLocalDeletion = false
        static let playbackBehavior = PlaybackBehavior.pauseOthers
        static let swipeLeftAction = SwipeAction.delete
        static let swipeRightAction = SwipeAction.keep
        static let swipeUpAction = SwipeAction.details
        static let swipeDownAction = SwipeAction.undo
        /// Off, as on Android: swiping down in the viewer closes it.
        static let fullscreenSwipeDownUsesAction = false

        static let reminderEnabled = false
        static let reminderInterval = ReminderInterval.often
        static let reminderCustomMinDays = 3
        static let reminderCustomMaxDays = 7

        static let backupWarningShown = false
        static let hasCompletedSwipeTutorial = false
        static let hasCompletedDuplicatesTutorial = false
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
    /// Info opens the details panel, after Fullscreen as on Android (`ActionButtonsOverlay.kt`).
    case fullscreen, info, rotate, immich, mute, download, share, fullResolution
}

/// Which buttons go in which corner, in order. Pure, so it's easy to test and the same rules apply
/// to the card and to the settings preview.
nonisolated struct CardButtonLayout: Equatable, Sendable {
    var show: [CardButton: Bool]
    var position: [CardButton: IconPosition]
    var orientation: ButtonStackOrientation
    var style: ButtonStackStyle = Setting.Default.stackStyle

    static let `default` = CardButtonLayout(
        show: [
            .fullscreen: Setting.Default.showFullscreenButton,
            .info: Setting.Default.showInfoButton,
            .rotate: Setting.Default.showRotateButton,
            .immich: Setting.Default.showImmichButton,
            .mute: Setting.Default.showMuteButton,
            .download: Setting.Default.showDownloadButton,
            .share: Setting.Default.showShareButton,
            .fullResolution: Setting.Default.showFullResolutionButton,
        ],
        position: [
            .fullscreen: Setting.Default.fullscreenPosition,
            .info: Setting.Default.infoPosition,
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

    /// How big the card's buttons are and how far apart.
    struct Metrics: Equatable, Sendable {
        var size: CGFloat
        var spacing: CGFloat
    }

    static let fullMetrics = Metrics(size: 48, spacing: 12)
    /// Android's 8 dp gap, and a size that stays easy to tap.
    static let tightestMetrics = Metrics(size: 36, spacing: 8)

    /// Shrinks the buttons so every edge's stacks fit in `available`, the card's size inside its padding. Not
    /// on Android, where too many buttons in a row run off the card. First the gap closes from 12 pt to 8 pt,
    /// then every button shrinks alike, never below 36 pt. Two corners along one edge keep one gap between
    /// them, as between buttons. Connected buttons touch, so only the gap between two corners is left.
    func metrics(fitting available: CGSize, isVideo: Bool = false) -> Metrics {
        let full = Self.fullMetrics, tightest = Self.tightestMetrics
        guard available.width > 0, available.height > 0 else { return full }
        let edges: [(IconPosition, IconPosition, isRow: Bool)] = [
            (.topLeft, .topRight, true), (.bottomLeft, .bottomRight, true),
            (.topLeft, .bottomLeft, false), (.topRight, .bottomRight, false),
        ]
        // Along each edge: how many button lengths and gaps it needs, and how much room it has.
        let demands = edges.map { first, second, isRow -> (buttons: CGFloat, gaps: CGFloat, room: CGFloat) in
            let stacksAlong = isRow == (orientation == .horizontal)
            let counts = [first, second].map { buttons(in: $0, isVideo: isVideo).count }.filter { $0 > 0 }
            let buttons = counts.reduce(0) { $0 + (stacksAlong ? $1 : 1) }
            let gaps = counts.reduce(0) { $0 + (stacksAlong && style == .separate ? $1 - 1 : 0) } + (counts.count == 2 ? 1 : 0)
            return (CGFloat(buttons), CGFloat(gaps), isRow ? available.width : available.height)
        }

        let spacing = demands.filter { $0.gaps > 0 }
            .map { ($0.room - $0.buttons * full.size) / $0.gaps }
            .reduce(full.spacing, min)
        // Connected buttons have no gaps to close, so a stack can still be too long at full size.
        let overflows = demands.contains { $0.gaps == 0 && $0.buttons * full.size > $0.room }
        if !overflows, spacing >= tightest.spacing { return Metrics(size: full.size, spacing: spacing) }

        let size = demands.filter { $0.buttons > 0 }
            .map { ($0.room - $0.gaps * tightest.spacing) / $0.buttons }
            .reduce(full.size, min)
        return Metrics(size: max(size, tightest.size), spacing: tightest.spacing)
    }
}

// MARK: - Taps

/// What a tap on the card does when "Tap to swipe" is on: the left third swipes left, the right third
/// swipes right, and the middle is left alone so the card's own buttons stay usable.
nonisolated enum CardTapRules {
    static let edgeFraction = 0.3

    /// The edge the tap swipes the card towards, or nil for the middle.
    static func edge(atX x: Double, width: Double, tapToSwipe: Bool) -> Edge? {
        guard tapToSwipe, width > 0 else { return nil }
        if x < width * edgeFraction { return .leading }
        if x > width * (1 - edgeFraction) { return .trailing }
        return nil
    }
}
