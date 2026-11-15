import Foundation
import Testing
@testable import Immich_Swipe_iOS

// Cases ported from the Android UrlPolicyTest.kt.
struct URLPolicyTests {
    @Test(arguments: [
        "https://photos.example.com",
        "https://203.0.113.10:2283",
    ])
    func httpsIsNeverFlagged(_ url: String) throws {
        #expect(!URLPolicy.isInsecureRemote(try #require(URL(string: url))))
    }

    @Test(arguments: [
        "http://10.0.0.10:2283",
        "http://192.168.1.5:2283",
        "http://172.16.0.2",
        "http://172.31.255.1",
        "http://127.0.0.1:2283",
        "http://100.64.0.7:2283",
        "http://169.254.1.1",
        "http://localhost:2283",
        "http://nas:2283",
        "http://immich.local",
        "http://photos.home.arpa",
        "http://box.tailnet-name.ts.net:2283",
        "http://[::1]:2283",
        "http://[fd12:3456::1]:2283",
        "http://[fe80::1]:2283",
    ])
    func httpOnPrivateNetworksIsAllowed(_ url: String) throws {
        #expect(!URLPolicy.isInsecureRemote(try #require(URL(string: url))))
    }

    @Test(arguments: [
        "http://photos.example.com",
        "http://203.0.113.10:2283",
        "http://172.32.0.1",  // just outside 172.16/12
        "http://172.15.0.1",
        "http://100.128.0.1", // just outside 100.64/10
        "http://[2001:db8::1]:2283",
    ])
    func httpToPublicHostsIsFlagged(_ url: String) throws {
        #expect(URLPolicy.isInsecureRemote(try #require(URL(string: url))))
    }
}

struct ServerURLNormalizationTests {
    @Test func stripsWhitespaceTrailingSlashAndAPISuffix() {
        #expect(ImmichClient.normalizedServerURL("  https://photos.example.com/api/ ")?.absoluteString == "https://photos.example.com")
    }

    @Test func keepsPortAndSubpath() {
        #expect(ImmichClient.normalizedServerURL("http://nas:2283")?.absoluteString == "http://nas:2283")
        #expect(ImmichClient.normalizedServerURL("https://example.com/immich")?.absoluteString == "https://example.com/immich")
    }

    @Test(arguments: ["", "not a url", "ftp://example.com", "https://"])
    func rejectsInvalidInput(_ text: String) {
        #expect(ImmichClient.normalizedServerURL(text) == nil)
    }
}
