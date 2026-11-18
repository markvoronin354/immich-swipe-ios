import Foundation

/// Errors raised by `ImmichClient` itself. Transport failures surface as `URLError`.
nonisolated enum ImmichError: Error, Equatable, LocalizedError {
    case invalidServerURL
    /// Non-2xx response. `message` is the server's error text when it sent one.
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "The server address isn't a valid URL."
        case .http(let status, let message):
            message.map { "\($0) (HTTP \(status))" } ?? "The server returned HTTP \(status)."
        }
    }
}

/// What a request revealed about the connection, for the status indicator (spec §1.1).
nonisolated enum ConnectionEvent: Equatable, Sendable {
    case online
    case authenticationFailed(status: Int)
    case serverUnavailable(status: Int)
    case serverError(status: Int)
    case dnsFailure
    case timedOut
    case noInternet
}

/// Retry rules from the Android `RetryInterceptor`: transient failures only, on replay-safe requests.
nonisolated struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var baseDelay: Duration = .milliseconds(500)

    static let `default` = RetryPolicy()
    static let none = RetryPolicy(maxAttempts: 1)

    static let retryableStatuses: Set<Int> = [429, 502, 503, 504]

    func delay(afterAttempt attempt: Int) -> Duration {
        baseDelay * (1 << (attempt - 1))
    }
}

/// A typed client for the Immich endpoints in docs/PORTING_SPEC.md §1.2.
/// Method names match the OpenAPI operationIds.
nonisolated struct ImmichClient: Sendable {
    let serverURL: URL
    let apiKey: String
    private let session: URLSession
    /// The account's custom headers, sent along with the key to this server only.
    let headers: [String: String]
    private let retry: RetryPolicy
    private let onEvent: (@Sendable (ConnectionEvent) -> Void)?

    init(
        serverURL: URL,
        apiKey: String,
        headers: [String: String] = [:],
        session: URLSession = .shared,
        retry: RetryPolicy = .default,
        onEvent: (@Sendable (ConnectionEvent) -> Void)? = nil
    ) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.headers = headers
        self.session = session
        self.retry = retry
        self.onEvent = onEvent
    }

    /// Turns what the user typed into a server root URL. Trims whitespace and trailing slashes, and
    /// drops a trailing `/api`, since the client adds that itself.
    static func normalizedServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.lowercased().hasSuffix("/api") { trimmed.removeLast(4) }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    // MARK: Server and users

    func getServerVersion() async throws -> ServerVersion {
        try await send(.get, "server/version")
    }

    func getMyUser() async throws -> User {
        try await send(.get, "users/me")
    }

    /// The permissions the API key was given, or nil when the server doesn't say.
    func getApiKeyPermissions() async -> [String]? {
        do {
            let info: ApiKeyInfo = try await send(.get, "api-keys/me")
            return info.permissions
        } catch {
            AppLog.w("Auth", "Could not read the API key's permissions: \(error.localizedDescription)")
            return nil
        }
    }

    /// The permissions the key lacks, best effort: a server that doesn't say counts as missing nothing.
    func missingPermissions() async -> [String] {
        guard let granted = await getApiKeyPermissions() else { return [] }
        return ApiKeyPermissions.missing(granted: granted)
    }

    // MARK: Albums

    /// All albums, or only those containing `assetID` when given.
    func getAllAlbums(containing assetID: String? = nil) async throws -> [Album] {
        try await send(.get, "albums", query: assetID.map { [URLQueryItem(name: "assetId", value: $0)] } ?? [])
    }

    func getAlbumInfo(id: String) async throws -> Album {
        try await send(.get, "albums/\(id)")
    }

    func createAlbum(name: String, description: String? = nil, assetIDs: [String]? = nil) async throws -> Album {
        try await logFailure("AlbumRepository", "Error creating album \(name)") {
            try await send(.post, "albums", body: CreateAlbumRequest(albumName: name, description: description, assetIds: assetIDs))
        }
    }

    @discardableResult
    func addAssetsToAlbum(id: String, assetIDs: [String]) async throws -> [BulkIDResult] {
        try await logFailure("AlbumRepository", "Error adding assets to album \(id)") {
            try await send(.put, "albums/\(id)/assets", body: BulkIDsRequest(ids: assetIDs))
        }
    }

    @discardableResult
    func removeAssetFromAlbum(id: String, assetIDs: [String]) async throws -> [BulkIDResult] {
        try await logFailure("AlbumRepository", "Error removing assets from album \(id)") {
            try await send(.delete, "albums/\(id)/assets", body: BulkIDsRequest(ids: assetIDs))
        }
    }

    // MARK: Search

    func searchAssets(_ search: MetadataSearch) async throws -> SearchPage {
        let response: SearchResponse = try await send(.post, "search/metadata", body: search)
        return response.assets
    }

    func searchAssetStatistics(_ search: StatisticsSearch) async throws -> Int {
        let response: SearchStatistics = try await send(.post, "search/statistics", body: search)
        return response.total
    }

    // MARK: Assets

    func getAssetInfo(id: String) async throws -> Asset {
        try await send(.get, "assets/\(id)")
    }

    func getAssetDuplicates() async throws -> [DuplicateGroup] {
        do {
            return try await send(.get, "duplicates")
        } catch {
            AppLog.e("AssetRepo", "Error fetching duplicates: \(error.localizedDescription)")
            throw error
        }
    }

    /// Moves assets to the Immich trash, or deletes them permanently when `force` is true.
    func deleteAssets(ids: [String], force: Bool = false) async throws {
        AppLog.i("AssetRepo", "Deleting \(ids.count) assets from Immich server...")
        do {
            try await sendWithoutResponse(.delete, "assets", body: DeleteAssetsRequest(ids: ids, force: force))
        } catch {
            AppLog.e("AssetRepo", "Failed to delete \(ids.count) assets from Immich server: \(error.localizedDescription)", error)
            throw error
        }
        AppLog.i("AssetRepo", "Successfully deleted \(ids.count) assets from Immich server")
    }

    /// Sets favourite and/or visibility. Sent in chunks of 500 ids, like the Android app.
    func updateAssets(ids: [String], isFavorite: Bool? = nil, visibility: AssetVisibility? = nil) async throws {
        AppLog.i("AssetRepo", "Updating \(ids.count) assets on Immich server (isFavorite=\(isFavorite.map(String.init) ?? "nil"), visibility=\(visibility.map { "\($0)" } ?? "nil"))...")
        do {
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                try await sendWithoutResponse(.put, "assets", body: UpdateAssetsRequest(ids: chunk, isFavorite: isFavorite, visibility: visibility))
            }
        } catch {
            AppLog.e("AssetRepo", "Failed to update \(ids.count) assets on Immich server: \(error.localizedDescription)", error)
            throw error
        }
        AppLog.i("AssetRepo", "Successfully updated \(ids.count) assets on Immich server")
    }

    /// Sets the asset's description; an empty string clears it.
    func updateAsset(id: String, description: String) async throws {
        try await sendWithoutResponse(.put, "assets/\(id)", body: UpdateAssetRequest(description: description))
    }

    /// Sets the asset's rotation. Zero removes the edit (the Android app never sent this case).
    func editAsset(id: String, rotation degrees: Int) async throws {
        let angle = ((degrees % 360) + 360) % 360
        do {
            if angle == 0 {
                try await sendWithoutResponse(.delete, "assets/\(id)/edits")
            } else {
                try await sendWithoutResponse(.put, "assets/\(id)/edits", body: RotateEditRequest(angle: angle))
            }
        } catch {
            AppLog.e("AssetRepo", "Failed to sync rotation for asset \(id): \(error.localizedDescription)", error)
            throw error
        }
        AppLog.i("AssetRepo", "Successfully synced asset rotation edits to Immich server for asset \(id)")
    }

    // MARK: Media

    enum Media: Sendable {
        case preview(assetID: String)
        case thumbnail(assetID: String)
        case original(assetID: String)
        case videoPlayback(assetID: String)
        case profileImage(userID: String)
    }

    /// Image and video URLs. Load them with `authorizedRequest(for:)` or `authorizationHeaders`.
    func url(for media: Media) -> URL {
        switch media {
        case .preview(let id):
            endpoint("assets/\(id)/thumbnail", query: [.init(name: "size", value: "preview"), .init(name: "edited", value: "true")])
        case .thumbnail(let id):
            endpoint("assets/\(id)/thumbnail", query: [.init(name: "size", value: "thumbnail"), .init(name: "edited", value: "true")])
        case .original(let id):
            endpoint("assets/\(id)/original")
        case .videoPlayback(let id):
            endpoint("assets/\(id)/video/playback")
        case .profileImage(let id):
            endpoint("users/\(id)/profile-image")
        }
    }

    /// Headers every request needs. Pass to `AVURLAsset` via `"AVURLAssetHTTPHeaderFieldsKey"`.
    var authorizationHeaders: [String: String] { headers.merging(["x-api-key": apiKey]) { _, key in key } }

    func authorizedRequest(for media: Media) -> URLRequest {
        var request = URLRequest(url: url(for: media))
        for (name, value) in authorizationHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Downloads the original file into a temporary folder, under its own file name, and returns where it is.
    /// The caller owns the file and should delete it when done.
    func downloadOriginal(of asset: Asset) async throws -> URL {
        let (downloaded, response) = try await session.download(for: authorizedRequest(for: .original(assetID: asset.id)), delegate: APIKeyRedirectGuard.shared)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: downloaded)
            throw ImmichError.http(status: http.statusCode, message: nil)
        }

        // One folder per asset, so two photos with the same file name can't overwrite each other.
        let folder = FileManager.default.temporaryDirectory.appending(path: "immich-downloads/\(asset.id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: Self.safeFileName(asset.originalFileName, fallback: asset.id))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    /// A file name that can't escape its folder or contain characters file systems reject.
    static func safeFileName(_ name: String?, fallback: String) -> String {
        let last = (name ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let trimmed = last.replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? fallback : trimmed
    }

    // MARK: Transport

    /// Logs a failure the way Android's repositories do, then passes it on.
    private func logFailure<T>(_ tag: String, _ message: String, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            AppLog.e(tag, message, error)
            throw error
        }
    }

    private enum Method: String {
        case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
    }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        let url = serverURL.appending(path: "api").appending(path: path)
        return query.isEmpty ? url : url.appending(queryItems: query)
    }

    private func send<Response: Decodable>(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil
    ) async throws -> Response {
        let data = try await perform(method, path, query: query, body: body)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendWithoutResponse(_ method: Method, _ path: String, body: (any Encodable)? = nil) async throws {
        _ = try await perform(method, path, body: body)
    }

    /// Sends the request, retrying transient failures when the request is safe to replay.
    @concurrent
    private func perform(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)?) async throws -> Data {
        var request = URLRequest(url: endpoint(path, query: query))
        request.httpMethod = method.rawValue
        for (name, value) in authorizationHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Search endpoints use POST but only read, so they're safe to send twice. Creating an album isn't.
        let replaySafe = method != .post || path.hasPrefix("search/")
        let urlPath = request.url?.path() ?? path
        var attempt = 1

        while true {
            do {
                let (data, response) = try await session.data(for: request, delegate: APIKeyRedirectGuard.shared)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                report(status: status)
                Self.log(status: status, on: urlPath)

                if replaySafe, attempt < retry.maxAttempts, RetryPolicy.retryableStatuses.contains(status) {
                    logRetry(method, urlPath, reason: "HTTP \(status)", attempt: attempt)
                    try await Task.sleep(for: retry.delay(afterAttempt: attempt))
                    attempt += 1
                    continue
                }
                guard (200..<300).contains(status) else {
                    throw ImmichError.http(status: status, message: Self.serverMessage(in: data))
                }
                return data
            } catch let error as URLError where error.code != .cancelled {
                report(error)
                // Debug only, as on Android: retries are logged below and callers log the final failure.
                AppLog.d("Retrofit", "Network error (\(error.code.rawValue)) on \(urlPath): \(error.localizedDescription)")
                guard replaySafe, attempt < retry.maxAttempts else { throw error }
                logRetry(method, urlPath, reason: error.localizedDescription, attempt: attempt)
                try await Task.sleep(for: retry.delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }

    /// Android's `RetrofitFactory` log levels for each kind of response. Tagged "Retrofit" to match its logs.
    private static func log(status: Int, on urlPath: String) {
        switch status {
        case 200..<300: break
        case 401, 403: AppLog.e("Retrofit", "Authentication error (\(status)) on \(urlPath)")
        case 404: AppLog.d("Retrofit", "Resource not found (404) on \(urlPath)")
        case 502, 503, 504: AppLog.e("Retrofit", "Server unavailable (\(status)) on \(urlPath)")
        case 500...: AppLog.w("Retrofit", "Server error (\(status)) on \(urlPath)")
        default: break
        }
    }

    private func logRetry(_ method: Method, _ urlPath: String, reason: String, attempt: Int) {
        let delay = retry.delay(afterAttempt: attempt).components
        let milliseconds = delay.seconds * 1000 + delay.attoseconds / 1_000_000_000_000_000
        AppLog.d("Retrofit", "Request \(method.rawValue) \(urlPath) failed (\(reason)). Retrying \(attempt + 1)/\(retry.maxAttempts) in \(milliseconds)ms")
    }

    private func report(status: Int) {
        guard let onEvent else { return }
        switch status {
        case 200..<300: onEvent(.online)
        case 401, 403: onEvent(.authenticationFailed(status: status))
        case 502, 503, 504: onEvent(.serverUnavailable(status: status))
        case 500...: onEvent(.serverError(status: status))
        default: break
        }
    }

    private func report(_ error: URLError) {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: onEvent?(.dnsFailure)
        case .timedOut: onEvent?(.timedOut)
        default: onEvent?(.noInternet)
        }
    }

    /// Immich errors look like `{"message": "...", "statusCode": 400}`; `message` may be an array.
    private static func serverMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return message }
        if let messages = object["message"] as? [String] { return messages.joined(separator: "; ") }
        return nil
    }
}

/// Keeps the API key, and the account's custom headers, on their own server, like Android's
/// `ImmichAuthInterceptor`. URLSession copies every header onto a redirect, so without this a redirect to
/// another host would receive them. Pass it as the per-request delegate of any request that carries `x-api-key`.
nonisolated final class APIKeyRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = APIKeyRedirectGuard()

    /// Headers the app sets on every request itself, which are fine to send on.
    private static let ordinaryHeaders: Set<String> = ["accept", "content-type", "content-length", "user-agent"]

    // The completion-handler form, because the async one crashes the Swift compiler.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              !Self.isSameOrigin(target, original) else { return completionHandler(request) }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "x-api-key")
        // The custom headers are whatever else the request carried beyond the ordinary ones.
        for name in task.originalRequest?.allHTTPHeaderFields?.keys ?? [:].keys where !Self.ordinaryHeaders.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        completionHandler(stripped)
    }

    /// Same scheme, host and port, with default ports filled in, as Android's `isSameOrigin`.
    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ url: URL) -> (String?, String?, Int?) {
            let scheme = url.scheme?.lowercased()
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
            return (scheme, url.host(percentEncoded: false)?.lowercased(), port)
        }
        return origin(a) == origin(b)
    }
}

nonisolated extension MetadataSearch {
    /// The request for the page after `page`, or nil on the last page.
    /// Uses the cursor on servers that return one (v3.2+) and page numbers otherwise.
    func next(after page: SearchPage) -> MetadataSearch? {
        var next = self
        if let cursor = page.nextCursor {
            next.cursor = cursor
            next.page = nil
        } else if let nextPage = page.nextPage, let number = Int(nextPage) {
            next.page = number
            next.cursor = nil
        } else {
            return nil
        }
        return next
    }
}
