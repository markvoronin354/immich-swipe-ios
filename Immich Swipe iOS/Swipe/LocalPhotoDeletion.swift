import Foundation
import Photos

/// "Sync deletion with device" (Android's `LocalMediaRepository`, spec §3.6): after photos are deleted from
/// Immich, finds the same photos in this device's Photos library and asks iOS to delete them. iOS always
/// confirms first and moves them to Recently Deleted, so Android's trash-or-delete choice doesn't apply.
nonisolated enum LocalPhotoDeletion {
    /// Android allows the sizes to differ by up to 1 MB.
    static let sizeTolerance: Int64 = 1024 * 1024

    /// Only full access counts. With limited access most photos can't be seen, so matching would quietly
    /// miss them; that's treated as no access.
    static var hasAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
    }

    /// The local identifiers of the Photos items that match `assets`, as on Android: by original file name, with
    /// the sizes within 1 MB of each other. That means reading every item's resources, so it runs off the main actor.
    @concurrent
    static func localIdentifiers(matching assets: [Asset]) async -> [String] {
        guard !assets.isEmpty else { return [] }
        guard hasAccess else {
            AppLog.w("LocalPhotoDeletion", "No full access to Photos, so nothing is deleted from the device")
            return []
        }
        let started = Date()

        var byName: [String: [Asset]] = [:]
        for asset in assets {
            guard let name = asset.originalFileName.map(cleanName), !name.isEmpty else { continue }
            byName[name, default: []].append(asset)
        }
        guard !byName.isEmpty else { return [] }

        var matched: [String] = []
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        PHAsset.fetchAssets(with: options).enumerateObjects { item, _, _ in
            let resources = PHAssetResource.assetResources(for: item)
            guard let original = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first,
                  let candidates = byName[original.originalFilename] else { return }
            // Not public API, but the only way PhotoKit gives a resource's size without loading its data.
            let localSize = (original.value(forKey: "fileSize") as? NSNumber)?.int64Value
            if candidates.contains(where: { sizeMatches(immich: $0.fileSize, local: localSize) }) {
                matched.append(item.localIdentifier)
            }
        }

        AppLog.i("LocalPhotoDeletion", "Matched \(matched.count) Photos items out of \(assets.count) deleted assets in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return matched
    }

    /// Asks iOS to delete the items. iOS shows its own confirmation; cancelling it throws.
    static func delete(localIdentifiers: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil))
        }
    }

    /// The file name without any folders, as on Android.
    static func cleanName(_ name: String) -> String {
        String(name.split(separator: "/").last?.split(separator: "\\").last ?? "")
    }

    /// As on Android, an unknown size on the Immich side matches anything. An unknown local size only matches
    /// then, so a common name like IMG_0001.HEIC isn't enough on its own.
    static func sizeMatches(immich: Int64?, local: Int64?) -> Bool {
        guard let immich, immich != 0 else { return true }
        guard let local else { return false }
        return abs(immich - local) < sizeTolerance
    }
}
