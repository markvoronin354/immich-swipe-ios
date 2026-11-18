import Foundation
import Testing
@testable import Immich_Swipe_iOS

/// Stands in for the Immich server. Replies with queued responses and records each request.
final class MockServer: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var path: String
        var apiKey: String?
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [(status: Int, body: String)] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func reset(responses: [(Int, String)] = []) {
        lock.withLock {
            queued = responses.map { (status: $0.0, body: $0.1) }
            recorded = []
        }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let reply: (status: Int, body: String) = Self.lock.withLock {
            Self.recorded.append(Recorded(
                method: request.httpMethod ?? "",
                path: request.url?.path() ?? "",
                apiKey: request.value(forHTTPHeaderField: "x-api-key"),
                body: Self.bodyText(of: request)
            ))
            return Self.queued.isEmpty ? (204, "") : Self.queued.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession moves the body into a stream before it reaches a URLProtocol.
    private static func bodyText(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Collects connection events from the client's callback.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConnectionEvent] = []
    func append(_ event: ConnectionEvent) { lock.withLock { events.append(event) } }
    var all: [ConnectionEvent] { lock.withLock { events } }
}

// Serialized because MockServer's state is shared.
@Suite(.serialized)
struct ImmichClientTests {
    let events = EventLog()
    let client: ImmichClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockServer.self]
        let events = events
        client = ImmichClient(
            serverURL: URL(string: "https://photos.example.com")!,
            apiKey: "KEY",
            session: URLSession(configuration: configuration),
            retry: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1)),
            onEvent: { events.append($0) }
        )
    }

    @Test func namesTheKeysMissingPermissions() async {
        MockServer.reset(responses: [(200, #"{"permissions":["asset.read","album.read"]}"#)])
        let missing = await client.missingPermissions()
        #expect(!missing.contains("asset.read") && !missing.contains("album.read"))
        #expect(missing.contains("album.create") && missing.contains("user.read"))

        MockServer.reset(responses: [(200, #"{"permissions":["all"]}"#)])
        #expect(await client.missingPermissions().isEmpty)

        // A server that doesn't answer counts as missing nothing, so nothing is warned about by mistake.
        MockServer.reset(responses: [(404, "")])
        #expect(await client.missingPermissions().isEmpty)
    }

    @Test func readsTheMissingPermissionFromAForbiddenAnswer() {
        let refused = ImmichError.http(status: 403, message: "Missing required permission: album.create")
        #expect(refused.missingPermission == "album.create")
        #expect(ImmichError.http(status: 403, message: "Forbidden").missingPermission == nil)
        #expect(ImmichError.http(status: 500, message: "Missing required permission: album.create").missingPermission == nil)
    }

    @Test func sendsAPIKeyAndRetriesTransientFailures() async throws {
        MockServer.reset(responses: [(503, ""), (200, #"{"id":"u1","email":"me@example.com","name":"Me"}"#)])
        let user = try await client.getMyUser()

        #expect(user.id == "u1")
        #expect(MockServer.requests.count == 2)
        #expect(MockServer.requests.allSatisfy { $0.apiKey == "KEY" && $0.path == "/api/users/me" })
        #expect(events.all == [.serverUnavailable(status: 503), .online])
    }

    @Test func doesNotRetryAlbumCreation() async throws {
        MockServer.reset(responses: [(503, #"{"message":"busy","statusCode":503}"#)])
        await #expect(throws: ImmichError.http(status: 503, message: "busy")) {
            _ = try await client.createAlbum(name: "Trip")
        }
        #expect(MockServer.requests.count == 1)
    }

    @Test func retriesSearchEvenThoughItIsAPost() async throws {
        MockServer.reset(responses: [(429, ""), (200, #"{"assets":{"items":[],"total":0,"nextPage":null,"nextCursor":null}}"#)])
        _ = try await client.searchAssets(MetadataSearch())
        #expect(MockServer.requests.count == 2)
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        MockServer.reset(responses: [(502, ""), (502, ""), (502, ""), (200, "{}")])
        await #expect(throws: ImmichError.http(status: 502, message: nil)) {
            _ = try await client.getMyUser()
        }
        #expect(MockServer.requests.count == 3)
    }

    @Test func authErrorIsNotRetriedAndCarriesServerMessage() async throws {
        MockServer.reset(responses: [(401, #"{"message":["Invalid API key"],"statusCode":401}"#)])
        await #expect(throws: ImmichError.http(status: 401, message: "Invalid API key")) {
            _ = try await client.getMyUser()
        }
        #expect(MockServer.requests.count == 1)
        #expect(events.all == [.authenticationFailed(status: 401)])
    }

    @Test func rotationUsesPutOrDeleteOnEdits() async throws {
        MockServer.reset()
        try await client.editAsset(id: "a1", rotation: 90)
        try await client.editAsset(id: "a1", rotation: -90)
        try await client.editAsset(id: "a1", rotation: 360)

        let requests = MockServer.requests
        #expect(requests.map(\.method) == ["PUT", "PUT", "DELETE"])
        #expect(requests.allSatisfy { $0.path == "/api/assets/a1/edits" })
        #expect(requests[0].body.contains(#""angle":90"#) && requests[0].body.contains(#""action":"rotate""#))
        #expect(requests[1].body.contains(#""angle":270"#))
        #expect(requests[2].body.isEmpty)
    }

    @Test func descriptionIsSentToTheAsset() async throws {
        MockServer.reset()
        try await client.updateAsset(id: "a1", description: "At the beach")
        try await client.updateAsset(id: "a1", description: "")

        let requests = MockServer.requests
        #expect(requests.map(\.method) == ["PUT", "PUT"])
        #expect(requests.allSatisfy { $0.path == "/api/assets/a1" })
        #expect(requests[0].body.contains(#""description":"At the beach""#))
        #expect(requests[1].body.contains(#""description":"""#))
    }

    @Test func deleteSendsIDsInBodyAndTrashesByDefault() async throws {
        MockServer.reset()
        try await client.deleteAssets(ids: ["a1", "a2"])
        let request = try #require(MockServer.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/api/assets")
        #expect(request.body.contains(#""ids":["a1","a2"]"#))
        #expect(request.body.contains(#""force":false"#))
    }

    @Test func updateIsChunkedBy500() async throws {
        MockServer.reset()
        try await client.updateAssets(ids: (0..<1001).map(String.init), visibility: .archive)
        #expect(MockServer.requests.count == 3)
        #expect(MockServer.requests.allSatisfy { $0.method == "PUT" && $0.body.contains(#""visibility":"archive""#) })
    }

    @Test func mediaURLs() {
        #expect(client.url(for: .preview(assetID: "a1")).absoluteString == "https://photos.example.com/api/assets/a1/thumbnail?size=preview&edited=true")
        #expect(client.url(for: .original(assetID: "a1")).absoluteString == "https://photos.example.com/api/assets/a1/original")
        #expect(client.authorizedRequest(for: .videoPlayback(assetID: "a1")).value(forHTTPHeaderField: "x-api-key") == "KEY")
    }
}

/// Redirects `/api/...` to the URL in `target`, then records what reaches the redirected request.
final class RedirectingServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var target = ""
    nonisolated(unsafe) private static var keys: [String: String?] = [:]

    static func reset(redirectTo url: String) {
        lock.withLock { target = url; keys = [:] }
    }

    /// The API key each host received, `.some(nil)` when it got none.
    static var keysByHost: [String: String?] { lock.withLock { keys } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let target = Self.lock.withLock {
            Self.keys[url.host() ?? ""] = request.value(forHTTPHeaderField: "x-api-key")
            return Self.target
        }
        if url.path().hasPrefix("/api/") {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!
            // Carry the headers over, as URLSession does for a real redirect.
            var next = request
            next.url = URL(string: target)!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"u1","email":"me@example.com"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct APIKeyRedirectGuardTests {
    let client: ImmichClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingServer.self]
        client = ImmichClient(serverURL: URL(string: "https://photos.example.com")!, apiKey: "KEY", session: URLSession(configuration: configuration), retry: .none)
    }

    @Test func keyIsDroppedOnRedirectToAnotherHost() async throws {
        RedirectingServer.reset(redirectTo: "https://evil.example.net/steal")
        _ = try await client.getMyUser()
        #expect(RedirectingServer.keysByHost["photos.example.com"] == .some("KEY"))
        #expect(RedirectingServer.keysByHost["evil.example.net"] == .some(nil))
    }

    @Test func keyIsKeptOnRedirectWithinTheServer() async throws {
        RedirectingServer.reset(redirectTo: "https://photos.example.com:443/moved")
        _ = try await client.getMyUser()
        #expect(RedirectingServer.keysByHost["photos.example.com"] == .some("KEY"))
    }

    @Test func sameOriginNeedsSchemeHostAndPort() {
        let base = URL(string: "https://photos.example.com/api")!
        #expect(APIKeyRedirectGuard.isSameOrigin(URL(string: "https://Photos.Example.com:443/x")!, base))
        #expect(!APIKeyRedirectGuard.isSameOrigin(URL(string: "http://photos.example.com/x")!, base))
        #expect(!APIKeyRedirectGuard.isSameOrigin(URL(string: "https://photos.example.com:8443/x")!, base))
        #expect(!APIKeyRedirectGuard.isSameOrigin(URL(string: "https://photos.example.com.evil.net/x")!, base))
    }
}
