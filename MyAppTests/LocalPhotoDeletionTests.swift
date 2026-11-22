import Foundation
import Testing
@testable import Immich_Swipe_iOS

struct LocalPhotoDeletionTests {
    @Test func comparesOnlyTheFileName() {
        #expect(LocalPhotoDeletion.cleanName("IMG_0001.HEIC") == "IMG_0001.HEIC")
        #expect(LocalPhotoDeletion.cleanName("DCIM/100APPLE/IMG_0001.HEIC") == "IMG_0001.HEIC")
        #expect(LocalPhotoDeletion.cleanName(#"C:\Photos\IMG_0001.HEIC"#) == "IMG_0001.HEIC")
    }

    @Test func allowsSizesWithin1MBAsOnAndroid() {
        let size: Int64 = 3_000_000
        #expect(LocalPhotoDeletion.sizeMatches(immich: size, local: size))
        #expect(LocalPhotoDeletion.sizeMatches(immich: size, local: size + 1024 * 1024 - 1))
        #expect(!LocalPhotoDeletion.sizeMatches(immich: size, local: size + 1024 * 1024))
        #expect(!LocalPhotoDeletion.sizeMatches(immich: size, local: size - 1024 * 1024))
    }

    @Test func anUnknownImmichSizeMatchesButAnUnknownLocalOneDoesNot() {
        #expect(LocalPhotoDeletion.sizeMatches(immich: nil, local: 5))
        #expect(LocalPhotoDeletion.sizeMatches(immich: 0, local: nil))
        #expect(!LocalPhotoDeletion.sizeMatches(immich: 3_000_000, local: nil))
    }
}
