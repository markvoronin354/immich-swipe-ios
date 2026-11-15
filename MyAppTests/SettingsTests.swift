import Foundation
import SwiftUI
import Testing
@testable import Immich_Swipe_iOS

struct SettingsTests {
    @Test func rawValuesAndKeysMatchAndroid() {
        #expect(AppTheme(rawValue: "SYSTEM") == .system)
        #expect(IconPosition(rawValue: "BOTTOM_RIGHT") == .bottomRight)
        #expect(ButtonStackOrientation(rawValue: "HORIZONTAL") == .horizontal)
        #expect(DoubleTapAction(rawValue: "FAVORITE") == .favorite)
        #expect(ImmichOpenMode(rawValue: "WEB") == .web)
        #expect(ReminderInterval(rawValue: "RARELY") == .rarely)
        #expect(Setting.Key.showRotateButton == "show_card_display_icon")
        #expect(Setting.Key.rotatePosition == "card_display_icon_pos")
        #expect(Setting.Key.showFullResolutionButton == "show_full_size_icon")
        #expect(Setting.Key.fullResolutionPosition == "full_size_icon_pos")
        #expect(Setting.Key.keepFullResolution == "keep_full_resolution")
    }

    @Test func defaultsMatchAndroid() {
        #expect(Setting.Default.showImmichButton == false)
        #expect(Setting.Default.showMuteButton && Setting.Default.showDownloadButton && Setting.Default.showFullResolutionButton)
        #expect(Setting.Default.showShareButton == false)
        #expect(Setting.Default.mutePosition == .bottomRight && Setting.Default.downloadPosition == .bottomLeft)
        #expect(Setting.Default.keepFullResolution == false)
        #expect(Setting.Default.showLockButton == false)
        #expect(Setting.Default.showSwipeButtons == false)
        #expect(Setting.Default.doubleTapEnabled == true)
        #expect(Setting.Default.fullscreenPosition == .topRight)
        #expect(Setting.Default.rotatePosition == .topLeft)
        #expect(Setting.Default.immichPosition == .bottomLeft)
    }

    @Test func reminderRangesFollowAndroid() {
        #expect(ReminderInterval.often.dayRange(customMin: 3, customMax: 7) == 7...14)
        #expect(ReminderInterval.rarely.dayRange(customMin: 3, customMax: 7) == 21...35)
        #expect(ReminderInterval.custom.dayRange(customMin: 3, customMax: 7) == 3...7)
        // Nonsense input is repaired, never crashes.
        #expect(ReminderInterval.custom.dayRange(customMin: 0, customMax: 0) == 1...1)
        #expect(ReminderInterval.custom.dayRange(customMin: 9, customMax: 2) == 9...9)
    }

    @Test func themeMapsToColorScheme() {
        #expect(AppTheme.system.colorScheme == nil)
        #expect(AppTheme.light.colorScheme == .light)
        #expect(AppTheme.dark.colorScheme == .dark)
    }
}

struct CardButtonLayoutTests {
    @Test func defaultLayoutMatchesAndroidForAPhoto() {
        let layout = CardButtonLayout.default
        #expect(layout.buttons(in: .topLeft) == [.rotate])
        #expect(layout.buttons(in: .topRight) == [.fullscreen])
        #expect(layout.buttons(in: .bottomLeft) == [.download], "Immich is off by default, download is on")
        #expect(layout.buttons(in: .bottomRight) == [.fullResolution], "share is off, mute only shows on videos")
    }

    @Test func aVideoGetsMuteInsteadOfFullResolution() {
        let layout = CardButtonLayout.default
        #expect(layout.buttons(in: .bottomRight, isVideo: true) == [.mute])
        #expect(layout.buttons(in: .bottomLeft, isVideo: true) == [.download])
        #expect(layout.buttons(in: .topLeft, isVideo: true).isEmpty, "only images can be rotated")
    }

    @Test func everythingTurnedOnStacksInDeclarationOrder() {
        var layout = CardButtonLayout.default
        for button in CardButton.allCases {
            layout.show[button] = true
            layout.position[button] = .bottomRight
        }
        #expect(layout.buttons(in: .bottomRight) == [.fullscreen, .rotate, .immich, .download, .share, .fullResolution])
        #expect(layout.buttons(in: .bottomRight, isVideo: true) == [.fullscreen, .immich, .mute, .download, .share])
    }

    @Test func buttonsSharingACornerKeepAFixedOrder() {
        var layout = CardButtonLayout.default
        layout.show[.immich] = true
        layout.position[.immich] = .topLeft
        layout.position[.fullscreen] = .topLeft
        #expect(layout.buttons(in: .topLeft) == [.fullscreen, .rotate, .immich])
        #expect(layout.buttons(in: .topRight).isEmpty)
    }

    @Test func hiddenButtonsTakeNoSpace() {
        var layout = CardButtonLayout.default
        layout.show[.rotate] = false
        #expect(layout.buttons(in: .topLeft).isEmpty)
    }
}

struct CardTapRulesTests {
    @Test(arguments: [
        (10.0, SwipeDecision.delete), (89.0, .delete),
        (150.0, nil), (90.0, nil), (210.0, nil),
        (211.0, .keep), (299.0, .keep),
    ] as [(Double, SwipeDecision?)])
    func edgesDecideAndTheMiddleDoesNot(x: Double, expected: SwipeDecision?) {
        #expect(CardTapRules.decision(atX: x, width: 300, tapToSwipe: true) == expected)
    }

    @Test func nothingHappensWhenTheSettingIsOff() {
        #expect(CardTapRules.decision(atX: 10, width: 300, tapToSwipe: false) == nil)
    }

    @Test func zeroWidthIsIgnored() {
        #expect(CardTapRules.decision(atX: 0, width: 0, tapToSwipe: true) == nil)
    }
}

struct SortingBarButtonOrderTests {
    @Test func defaultOrderMatchesAndroid() {
        #expect(SortingBarButton.order(from: "") == [.archive, .favorite, .album, .lock])
    }

    @Test func savedOrderDropsUnknownNamesAndAppendsMissingButtons() {
        #expect(SortingBarButton.order(from: "LOCK,NOPE,ALBUM,LOCK") == [.lock, .album, .archive, .favorite])
        #expect(SortingBarButton.saved([.lock, .album, .archive, .favorite]) == "LOCK,ALBUM,ARCHIVE,FAVORITE")
    }

    @Test func movingAmongShownButtonsKeepsHiddenOnesInPlace() {
        // Lock is hidden, so the list shows Archive, Favorite, Album; Album is dragged to the top.
        let order: [SortingBarButton] = [.archive, .lock, .favorite, .album]
        let moved = SortingBarButton.moving(order, shown: [.archive, .favorite, .album], from: [2], to: 0)
        #expect(moved == [.album, .lock, .archive, .favorite])
    }
}
