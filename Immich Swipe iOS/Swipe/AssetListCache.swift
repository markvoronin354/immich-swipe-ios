import Foundation

/// Each deck's asset listing, kept on the device between visits (spec §2.2 `album_assets`, §3.5).
///
/// A reopened deck shows its whole pile right away, already sorted, while the server is checked for
/// changes. One file per user and album, holding the assets in the order they arrived.
nonisolated struct AssetListCache: Sendable {
    let directory: URL

    static let shared = AssetListCache(directory: .cachesDirectory.appending(path: "AlbumAssets", directoryHint: .isDirectory))

    /// The saved listing, or empty when there is none or it can't be read.
    @concurrent func assets(userID: String, albumID: String) async -> [Asset] {
        Self.read(file(userID: userID, albumID: albumID)) ?? []
    }

    /// A listing that fails to save only costs a full reload next time, so errors are ignored.
    @concurrent func save(_ assets: [Asset], userID: String, albumID: String) async {
        let url = file(userID: userID, albumID: albumID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(assets).write(to: url, options: .atomic)
    }

    /// Drops assets from every listing saved for the user, once they're deleted or locked.
    @concurrent func remove(assetIDs: Set<String>, userID: String) async {
        let folder = directory.appending(path: userID, directoryHint: .isDirectory)
        guard !assetIDs.isEmpty, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files {
            guard let assets = Self.read(url) else { continue }
            let kept = assets.filter { !assetIDs.contains($0.id) }
            if kept.count != assets.count { try? JSONEncoder().encode(kept).write(to: url, options: .atomic) }
        }
    }

    private func file(userID: String, albumID: String) -> URL {
        directory.appending(path: userID, directoryHint: .isDirectory).appending(path: "\(albumID).json")
    }

    private static func read(_ url: URL) -> [Asset]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Asset].self, from: data)
    }
}
