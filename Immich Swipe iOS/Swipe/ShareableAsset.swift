import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A photo or video that the share sheet can send on. The original is only downloaded when the person
/// actually picks where to send it, so showing the share sheet costs nothing.
nonisolated struct ShareableAsset: Transferable, Sendable {
    let client: ImmichClient
    let asset: Asset

    var fileName: String { ImmichClient.safeFileName(asset.originalFileName, fallback: asset.id) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { item in
            SentTransferredFile(try await item.download())
        }
        .exportingCondition { $0.asset.type == .video }

        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(try await item.download())
        }
        .exportingCondition { $0.asset.type != .video }
    }

    private func download() async throws -> URL {
        do {
            return try await client.downloadOriginal(of: asset)
        } catch {
            AppLog.e("Share", "Error sharing asset", error)
            throw error
        }
    }
}
