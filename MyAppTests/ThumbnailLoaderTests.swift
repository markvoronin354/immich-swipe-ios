import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Immich_Swipe_iOS

/// Serves GIFs by path: "/animated.gif" has two frames, "/still.gif" one.
private final class GIFServer: URLProtocol, @unchecked Sendable {
    static let files: [String: Data] = ["/animated.gif": gif(frames: 2), "/still.gif": gif(frames: 1)]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let data = Self.files[request.url?.path() ?? ""]
        let response = HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": "image/gif"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    /// A 4×4 GIF with the given number of frames, each a different grey.
    private static func gif(frames: Int) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        for index in 0..<frames {
            let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(gray: CGFloat(index) / CGFloat(max(frames, 1)), alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(destination, context.makeImage()!, properties)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

struct ThumbnailLoaderTests {
    private let loader: ThumbnailLoader = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GIFServer.self]
        return ThumbnailLoader(session: URLSession(configuration: configuration))
    }()

    private func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://gifs.example.com\(path)")!)
    }

    @Test func anAnimatedImageComesBackForPlayingAndAStillOneDoesNot() async throws {
        let animated = try await loader.animationData(for: request("/animated.gif"))
        #expect(animated == GIFServer.files["/animated.gif"])
        #expect(try await loader.animationData(for: request("/still.gif")) == nil)
    }

    @Test func theStillFrameStillLoadsForAnAnimatedImage() async throws {
        let image = try await loader.image(for: request("/animated.gif"), maxPixelSize: 100)
        #expect(image.width == 4 && image.height == 4)
    }

    @Test func aFailedDownloadThrows() async {
        await #expect(throws: ImmichError.http(status: 404, message: nil)) {
            try await loader.animationData(for: request("/missing.gif"))
        }
    }
}
