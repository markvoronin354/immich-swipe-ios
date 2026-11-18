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
        #expect(layout.buttons(in: .bottomRight) == [.fullscreen, .info, .rotate, .immich, .download, .share, .fullResolution])
        #expect(layout.buttons(in: .bottomRight, isVideo: true) == [.fullscreen, .info, .immich, .mute, .download, .share])
    }

    @Test func buttonsSharingACornerKeepAFixedOrder() {
        var layout = CardButtonLayout.default
        layout.show[.immich] = true
        layout.position[.immich] = .topLeft
        layout.position[.fullscreen] = .topLeft
        #expect(layout.buttons(in: .topLeft) == [.fullscreen, .rotate, .immich])
        #expect(layout.buttons(in: .topRight).isEmpty)
    }

    /// Every photo button on, in one corner's row.
    private func row(of count: Int, in corner: IconPosition = .topLeft) -> CardButtonLayout {
        var layout = CardButtonLayout.default
        let photoButtons = CardButton.allCases.filter { CardButtonLayout.applies($0, toVideo: false) }
        for button in CardButton.allCases {
            layout.show[button] = photoButtons.prefix(count).contains(button)
            layout.position[button] = corner
        }
        layout.orientation = .horizontal
        layout.style = .separate
        return layout
    }

    @Test func buttonsThatFitKeepTheirSizeAndGap() {
        #expect(CardButtonLayout.default.metrics(fitting: CGSize(width: 345, height: 500)) == CardButtonLayout.fullMetrics)
    }

    @Test func aCrowdedRowClosesItsGapFirst() {
        // Six 48 pt buttons in 345 pt leave 57 pt for five gaps.
        let metrics = row(of: 6).metrics(fitting: CGSize(width: 345, height: 500))
        #expect(metrics.size == 48 && abs(metrics.spacing - 11.4) < 0.01)
    }

    @Test func aRowTooLongForAnyGapShrinksItsButtons() {
        // Seven buttons on an iPhone 17's card, as in the screenshot: 8 pt gaps, and buttons of (345 - 48) / 7.
        let metrics = row(of: 7).metrics(fitting: CGSize(width: 345, height: 500))
        #expect(metrics.spacing == 8 && abs(metrics.size - 297.0 / 7) < 0.01)
    }

    @Test func buttonsNeverShrinkBelowTheTightestSize() {
        #expect(row(of: 7).metrics(fitting: CGSize(width: 200, height: 500)) == CardButtonLayout.tightestMetrics)
    }

    @Test func connectedButtonsLeaveNoGapsInsideACorner() {
        var layout = row(of: 7)
        layout.style = .connected
        // Seven 48 pt buttons touching take 336 pt, which fits where separate ones had to shrink.
        #expect(layout.metrics(fitting: CGSize(width: 345, height: 500)) == CardButtonLayout.fullMetrics)
    }

    @Test func aConnectedRowTooLongForTheCardStillShrinks() {
        var layout = row(of: 7)
        layout.style = .connected
        let metrics = layout.metrics(fitting: CGSize(width: 300, height: 500))
        #expect(metrics.spacing == 8 && abs(metrics.size - 300.0 / 7) < 0.01)
    }

    @Test func connectedIsTheDefaultStyle() {
        #expect(CardButtonLayout.default.style == .connected)
    }

    @Test func twoCornersOnOneEdgeShareItsRoom() {
        var layout = row(of: 7)
        for button in [CardButton.download, .share, .fullResolution] { layout.position[button] = .topRight }
        // Four and three along the top, with a gap between the corners: the same as one row of seven.
        #expect(layout.metrics(fitting: CGSize(width: 345, height: 500)) == row(of: 7).metrics(fitting: CGSize(width: 345, height: 500)))
        #expect(layout.metrics(fitting: CGSize(width: 500, height: 345)) == CardButtonLayout.fullMetrics, "a row only needs the card's width")
    }

    @Test func hiddenButtonsTakeNoSpace() {
        var layout = CardButtonLayout.default
        layout.show[.rotate] = false
        #expect(layout.buttons(in: .topLeft).isEmpty)
    }
}

struct CardTapRulesTests {
    @Test(arguments: [
        (10.0, Edge.leading), (89.0, .leading),
        (150.0, nil), (90.0, nil), (210.0, nil),
        (211.0, .trailing), (299.0, .trailing),
    ] as [(Double, Edge?)])
    func edgesSwipeAndTheMiddleDoesNot(x: Double, expected: Edge?) {
        #expect(CardTapRules.edge(atX: x, width: 300, tapToSwipe: true) == expected)
    }

    @Test func nothingHappensWhenTheSettingIsOff() {
        #expect(CardTapRules.edge(atX: 10, width: 300, tapToSwipe: false) == nil)
    }

    @Test func zeroWidthIsIgnored() {
        #expect(CardTapRules.edge(atX: 0, width: 0, tapToSwipe: true) == nil)
    }
}

struct SwipeMappingTests {
    @Test func defaultsMatchAndroid() {
        let mapping = SwipeMapping.default
        #expect(mapping == SwipeMapping(left: .delete, right: .keep, up: .details, down: .undo))
        #expect(mapping.action(toward: .leading) == .delete && mapping.action(toward: .trailing) == .keep)
    }

    @Test func pickingTheOtherSidesActionSwapsTheSides() {
        let mapping = SwipeMapping.default.settingLeft(.keep)
        #expect(mapping.left == .keep && mapping.right == .delete)
        let back = mapping.settingRight(.keep)
        #expect(back.left == .delete && back.right == .keep)
    }

    @Test func pickingAFreeActionLeavesTheOtherSide() {
        let mapping = SwipeMapping.default.settingRight(.favorite)
        #expect(mapping.left == .delete && mapping.right == .favorite)
    }

    @Test func upAndDownMayRepeatASidesAction() {
        var mapping = SwipeMapping.default
        mapping.down = .delete
        #expect(mapping.contains(.delete) && !mapping.contains(.archive))
    }

    @Test func eachDirectionOffersAndroidsChoices() {
        #expect(!SwipeAction.sideChoices.contains(.undo) && !SwipeAction.sideChoices.contains(.details))
        #expect(SwipeAction.downChoices.contains(.undo) && !SwipeAction.downChoices.contains(.details))
        #expect(SwipeAction.upChoices.contains(.details) && !SwipeAction.upChoices.contains(.undo))
        #expect(SwipeAction.favorite.decision == .keep && SwipeAction.undo.decision == nil)
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
