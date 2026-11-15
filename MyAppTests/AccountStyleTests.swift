import Foundation
import SwiftUI
import Testing
@testable import Immich_Swipe_iOS

struct AvatarStyleTests {
    @Test func colourNamesMatchAndroid() {
        #expect(AvatarStyle.rgb(forColorName: "yellow") == 0xFFEB3B)
        #expect(AvatarStyle.rgb(forColorName: "PURPLE") == 0x9C27B0)
        #expect(AvatarStyle.rgb(forColorName: "grey") == AvatarStyle.rgb(forColorName: "gray"))
        #expect(AvatarStyle.rgb(forColorName: "teal") == 0x009688)
    }

    @Test func unknownOrMissingColourIsPurple() {
        #expect(AvatarStyle.rgb(forColorName: nil) == 0x9C27B0)
        #expect(AvatarStyle.rgb(forColorName: "chartreuse") == 0x9C27B0)
    }

    @Test(arguments: [("Family_Media", "F"), ("  mark", "M"), ("_ _7up", "7"), ("élan", "É")] as [(String, String)])
    func initialIsTheFirstLetterOrDigitUppercased(name: String, expected: String) {
        #expect(AvatarStyle.initial(of: name) == Character(expected))
    }

    @Test func noLetterMeansNoInitial() {
        #expect(AvatarStyle.initial(of: nil) == nil)
        #expect(AvatarStyle.initial(of: "") == nil)
        #expect(AvatarStyle.initial(of: "__ --") == nil)
    }

    @Test func lightColoursGetDarkTextAndDarkOnesGetWhite() {
        #expect(AvatarStyle.prefersDarkText(onRGB: AvatarStyle.rgb(forColorName: "yellow")))
        #expect(AvatarStyle.prefersDarkText(onRGB: AvatarStyle.rgb(forColorName: "lime")))
        #expect(!AvatarStyle.prefersDarkText(onRGB: AvatarStyle.rgb(forColorName: "purple")))
        #expect(!AvatarStyle.prefersDarkText(onRGB: AvatarStyle.rgb(forColorName: "indigo")))
        #expect(!AvatarStyle.prefersDarkText(onRGB: AvatarStyle.rgb(forColorName: "gray")))
    }
}

struct ConnectionLevelTests {
    @Test func theServerAnsweringFineIsOnline() {
        #expect(ConnectionLevel(.online) == .online)
    }

    @Test func aServerThatAnswersBadlyOrSlowlyIsAnIssue() {
        #expect(ConnectionLevel(.authenticationFailed(status: 401)) == .issues)
        #expect(ConnectionLevel(.serverUnavailable(status: 503)) == .issues)
        #expect(ConnectionLevel(.serverError(status: 500)) == .issues)
        #expect(ConnectionLevel(.timedOut) == .issues)
    }

    @Test func aServerThatCantBeReachedIsOffline() {
        #expect(ConnectionLevel(.dnsFailure) == .offline)
        #expect(ConnectionLevel(.noInternet) == .offline)
    }

    @Test func nothingCheckedYetIsUnknown() {
        #expect(ConnectionLevel(nil) == .unknown)
    }
}

@MainActor
struct NavigatorTests {
    @Test func openingSettingsPushesOneScreenAndResetClearsIt() {
        let navigator = Navigator()
        #expect(navigator.path.isEmpty)
        navigator.openSettings()
        #expect(navigator.path.count == 1)
        navigator.reset()
        #expect(navigator.path.isEmpty)
    }
}
