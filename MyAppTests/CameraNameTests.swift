import Foundation
import Testing
@testable import Immich_Swipe_iOS

struct CameraNameTests {
    @Test(arguments: [
        ("NIKON CORPORATION", "NIKON D7000", "NIKON D7000"),
        ("Canon", "Canon EOS R5", "Canon EOS R5"),
        ("PENTAX Corporation", "PENTAX K-5", "PENTAX K-5"),
        ("Apple", "iPhone 15 Pro", "Apple iPhone 15 Pro"),
        ("SONY", "ILCE-7M3", "SONY ILCE-7M3"),
        ("OLYMPUS IMAGING CORP.", "E-M5", "OLYMPUS E-M5"),
        ("OLYMPUS OPTICAL CO.,LTD", "C960Z,D460Z", "OLYMPUS C960Z,D460Z"),
        ("SAMSUNG ELECTRONICS CO., LTD.", "SM-G991B", "Galaxy S21 (SM-G991B)"),
        ("Eastman Kodak Company", "KODAK EASYSHARE C813", "KODAK EASYSHARE C813"),
        ("Leica Camera AG", "LEICA Q2", "LEICA Q2"),
        ("FUJIFILM", "X-T3", "FUJIFILM X-T3"),
        ("samsung", "SM-G900A", "Galaxy S5 (SM-G900A)"),
        ("SAMSUNG", "SAMSUNG-SM-G900A", "Galaxy S5 (SM-G900A)"),
        ("SAMSUNG", "GT-I9300", "Galaxy S III (GT-I9300)"),
        ("SAMSUNG ELECTRONICS CO., LTD.", "SM-J810F", "Galaxy J8 (SM-J810F)"),
        ("samsung", "SM-X999Z", "samsung SM-X999Z"),
    ])
    func combinesMakeAndModel(make: String, model: String, expected: String) {
        #expect(MetadataPanel.cameraName(make: make, model: model) == expected)
    }

    @Test func handlesMissingParts() {
        #expect(MetadataPanel.cameraName(make: nil, model: nil) == nil)
        #expect(MetadataPanel.cameraName(make: "  ", model: "") == nil)
        #expect(MetadataPanel.cameraName(make: "NIKON CORPORATION", model: nil) == "NIKON")
        #expect(MetadataPanel.cameraName(make: nil, model: "iPhone 15 Pro") == "iPhone 15 Pro")
        // A make that is only a company word is kept rather than emptied.
        #expect(MetadataPanel.cameraName(make: "Imaging", model: "X1") == "Imaging X1")
    }
}

struct MetadataDateTests {
    /// 1 May 2024 in the panel's long style.
    private var firstOfMay: String {
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = .gmt
        return Date(timeIntervalSince1970: 1_714_521_600).formatted(style)
    }

    /// As on Android, the date written before the time, whatever the time and offset after it.
    @Test(arguments: ["2024-05-01T23:30:00.000-05:00", "2024-05-01T00:30:00Z", "2024-05-01T12:00:00.123456+14:00", "2024-05-01"])
    func showsTheWrittenDateWithoutMovingItToAnotherDay(fileCreatedAt: String) {
        #expect(MetadataPanel.dateText(fileCreatedAt: fileCreatedAt) == firstOfMay)
    }

    @Test func anUnreadableDateShowsTheTextBeforeTheTime() {
        #expect(MetadataPanel.dateText(fileCreatedAt: "sometime") == "sometime")
        #expect(MetadataPanel.dateText(fileCreatedAt: "2024-13-45T10:00:00Z") == "2024-13-45")
    }
}
