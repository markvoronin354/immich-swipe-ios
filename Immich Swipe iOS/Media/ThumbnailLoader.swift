import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads authenticated Immich images and downsamples them for display.
///
/// `AsyncImage` can't send the `x-api-key` header, so images go through here instead. Decoded images
/// are kept in memory, HTTP responses on disk via `URLCache`, and simultaneous requests for the same
/// image share one download.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let session: URLSession
    /// NSCache is thread-safe, so views can read it without hopping onto the actor.
    private nonisolated(unsafe) let memory = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage, Error>] = [:]
    /// Memory-cache keys per URL, so one photo's images can be dropped when it changes on the server.
    private var keysByURL: [String: Set<String>] = [:]

    struct UndecodableImage: Error {}

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            self.session = URLSession(configuration: configuration)
        }
        memory.countLimit = 400
    }

    private nonisolated static func key(for request: URLRequest, maxPixelSize: Int) -> String {
        "\(request.url?.absoluteString ?? "")#\(maxPixelSize)"
    }

    /// The image if it is already decoded in memory. Synchronous, so a card can draw it on its first frame
    /// instead of showing a spinner for the frame it takes to ask the actor.
    nonisolated func cachedImage(for request: URLRequest, maxPixelSize: Int) -> CGImage? {
        memory.object(forKey: Self.key(for: request, maxPixelSize: maxPixelSize) as NSString)
    }

    /// The image for `request`, no larger than `maxPixelSize` on its longest side.
    func image(for request: URLRequest, maxPixelSize: Int) async throws -> CGImage {
        let key = Self.key(for: request, maxPixelSize: maxPixelSize)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return try await running.value }

        let session = session
        let task = Task<CGImage, Error> {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImmichError.http(status: http.statusCode, message: nil)
            }
            guard let image = Self.downsample(data, maxPixelSize: maxPixelSize, typeHint: Self.typeHint(for: response)) else { throw UndecodableImage() }
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let image = try await task.value
        memory.setObject(image, forKey: key as NSString)
        if let url = request.url?.absoluteString { keysByURL[url, default: []].insert(key) }
        return image
    }

    /// Bytes the image cache is using on disk.
    var diskUsage: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }

    /// Empties both caches. Images are downloaded again as needed.
    func clearCache() {
        memory.removeAllObjects()
        keysByURL = [:]
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    /// Forgets cached copies of these images, memory and disk, after the photo changed on the server.
    func invalidate(_ requests: [URLRequest]) {
        for request in requests {
            if let url = request.url?.absoluteString {
                for key in keysByURL.removeValue(forKey: url) ?? [] { memory.removeObject(forKey: key as NSString) }
            }
            session.configuration.urlCache?.removeCachedResponse(for: request)
        }
    }

    /// Decodes straight to the target size, so a large original never sits in memory at full resolution.
    private static func downsample(_ data: Data, maxPixelSize: Int, typeHint: String?) -> CGImage? {
        var sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let typeHint { sourceOptions[kCGImageSourceTypeIdentifierHint] = typeHint }
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The file type of a downloaded original, from its file name or else its MIME type. Without it, ImageIO
    /// reads many RAW files (NEF, for one) as plain TIFF and returns only their tiny embedded thumbnail.
    private static func typeHint(for response: URLResponse) -> String? {
        let fromName = response.suggestedFilename
            .map { ($0 as NSString).pathExtension }
            .flatMap { $0.isEmpty ? nil : UTType(filenameExtension: $0) }
        let fromMIME = response.mimeType.flatMap { UTType(mimeType: $0) }
        return [fromName, fromMIME].compactMap { $0 }.first { !$0.isDynamic }?.identifier
    }
}
