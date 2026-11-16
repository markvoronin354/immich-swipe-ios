import SwiftUI

/// The settings the swipe screen obeys, read live from `UserDefaults`, so changing one in Settings
/// shows up in the deck without restarting anything.
///
/// Declare it as `private let prefs = DeckPreferences()` in any deck view that needs a setting.
struct DeckPreferences: DynamicProperty {
    @AppStorage(Setting.Key.showFullscreenButton) var showFullscreenButton = Setting.Default.showFullscreenButton
    @AppStorage(Setting.Key.showRotateButton) var showRotateButton = Setting.Default.showRotateButton
    @AppStorage(Setting.Key.showImmichButton) var showImmichButton = Setting.Default.showImmichButton
    @AppStorage(Setting.Key.fullscreenPosition) var fullscreenPosition = Setting.Default.fullscreenPosition
    @AppStorage(Setting.Key.rotatePosition) var rotatePosition = Setting.Default.rotatePosition
    @AppStorage(Setting.Key.immichPosition) var immichPosition = Setting.Default.immichPosition
    @AppStorage(Setting.Key.stackOrientation) var stackOrientation = Setting.Default.stackOrientation
    @AppStorage(Setting.Key.immichOpenMode) var immichOpenMode = Setting.Default.immichOpenMode
    @AppStorage(Setting.Key.showMuteButton) var showMuteButton = Setting.Default.showMuteButton
    @AppStorage(Setting.Key.showDownloadButton) var showDownloadButton = Setting.Default.showDownloadButton
    @AppStorage(Setting.Key.showShareButton) var showShareButton = Setting.Default.showShareButton
    @AppStorage(Setting.Key.showFullResolutionButton) var showFullResolutionButton = Setting.Default.showFullResolutionButton
    @AppStorage(Setting.Key.mutePosition) var mutePosition = Setting.Default.mutePosition
    @AppStorage(Setting.Key.downloadPosition) var downloadPosition = Setting.Default.downloadPosition
    @AppStorage(Setting.Key.sharePosition) var sharePosition = Setting.Default.sharePosition
    @AppStorage(Setting.Key.fullResolutionPosition) var fullResolutionPosition = Setting.Default.fullResolutionPosition
    @AppStorage(Setting.Key.keepFullResolution) var keepFullResolution = Setting.Default.keepFullResolution
    @AppStorage(Setting.Key.showInfoButton) var showInfoButton = Setting.Default.showInfoButton
    @AppStorage(Setting.Key.infoPosition) var infoPosition = Setting.Default.infoPosition

    @AppStorage(Setting.Key.showFavoriteButton) var showFavoriteButton = Setting.Default.showFavoriteButton
    @AppStorage(Setting.Key.showArchiveButton) var showArchiveButton = Setting.Default.showArchiveButton
    @AppStorage(Setting.Key.showLockButton) var showLockButton = Setting.Default.showLockButton
    @AppStorage(Setting.Key.showAddToAlbumButton) var showAddToAlbumButton = Setting.Default.showAddToAlbumButton
    @AppStorage(Setting.Key.showSwipeButtons) var showSwipeButtons = Setting.Default.showSwipeButtons
    @AppStorage(Setting.Key.showToolbarLabels) var showToolbarLabels = Setting.Default.showToolbarLabels
    @AppStorage(Setting.Key.toolbarButtonOrder) var savedToolbarButtonOrder = Setting.Default.toolbarButtonOrder
    @AppStorage(Setting.Key.autoNextOnFavorite) var autoNextOnFavorite = Setting.Default.autoNextOnFavorite
    @AppStorage(Setting.Key.tapToSwipe) var tapToSwipe = Setting.Default.tapToSwipe
    @AppStorage(Setting.Key.doubleTapEnabled) var doubleTapEnabled = Setting.Default.doubleTapEnabled
    @AppStorage(Setting.Key.doubleTapAction) var doubleTapAction = Setting.Default.doubleTapAction
    @AppStorage(Setting.Key.showTimeline) var showTimeline = Setting.Default.showTimeline
    @AppStorage(Setting.Key.swipeLeftAction) var swipeLeftAction = Setting.Default.swipeLeftAction
    @AppStorage(Setting.Key.swipeRightAction) var swipeRightAction = Setting.Default.swipeRightAction
    @AppStorage(Setting.Key.swipeUpAction) var swipeUpAction = Setting.Default.swipeUpAction
    @AppStorage(Setting.Key.swipeDownAction) var swipeDownAction = Setting.Default.swipeDownAction
    @AppStorage(Setting.Key.fullscreenSwipeDownUsesAction) var fullscreenSwipeDownUsesAction = Setting.Default.fullscreenSwipeDownUsesAction

    var swipes: SwipeMapping {
        SwipeMapping(left: swipeLeftAction, right: swipeRightAction, up: swipeUpAction, down: swipeDownAction)
    }

    var layout: CardButtonLayout {
        CardButtonLayout(
            show: [
                .fullscreen: showFullscreenButton, .info: showInfoButton, .rotate: showRotateButton, .immich: showImmichButton,
                .mute: showMuteButton, .download: showDownloadButton, .share: showShareButton, .fullResolution: showFullResolutionButton,
            ],
            position: [
                .fullscreen: fullscreenPosition, .info: infoPosition, .rotate: rotatePosition, .immich: immichPosition,
                .mute: mutePosition, .download: downloadPosition, .share: sharePosition, .fullResolution: fullResolutionPosition,
            ],
            orientation: stackOrientation
        )
    }
}
