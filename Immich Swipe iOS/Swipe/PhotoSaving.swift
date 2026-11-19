import Foundation
import Photos

/// Puts a downloaded file into the user's Photos library. A protocol so tests don't touch the real library.
@MainActor
protocol PhotoSaving {
    func save(fileAt url: URL, isVideo: Bool) async throws
}

struct PhotoLibraryAccessDenied: LocalizedError {
    var errorDescription: String? {
        String(localized: "Immich Swipe isn't allowed to add to your Photos library. You can allow it in Settings › Privacy & Security › Photos.")
    }
}

/// Saves to Photos with add-only access, so the app can never read anything in the library.
@MainActor
struct PhotoLibrarySaver: PhotoSaving {
    func save(fileAt url: URL, isVideo: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoLibraryAccessDenied() }

        // `@Sendable` keeps the closure off the main actor: Photos runs it on a background queue, and a
        // main-actor closure there traps at runtime under Swift 6.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            // The caller deletes its temporary file itself, so Photos must copy it.
            options.shouldMoveFile = false
            PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
        }
    }
}
