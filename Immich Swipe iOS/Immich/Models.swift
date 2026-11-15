import Foundation

// Wire models for the subset of the Immich API this app uses.
// Field names follow the server's JSON (see docs/PORTING_SPEC.md §2.1).
// They're `nonisolated` so they can be decoded and passed around off the main actor.

nonisolated enum AssetType: String, Codable, Sendable {
    case image = "IMAGE"
    case video = "VIDEO"
    case audio = "AUDIO"
    case other = "OTHER"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AssetType(rawValue: raw.uppercased()) ?? .other
    }
}

nonisolated enum AssetVisibility: String, Codable, Sendable {
    case archive, timeline, hidden, locked
}

nonisolated struct ExifInfo: Codable, Hashable, Sendable {
    var fileSizeInByte: Int64?
    var exifImageWidth: Int?
    var exifImageHeight: Int?
    var dateTimeOriginal: String?
    var orientation: String?
    var projectionType: String?
    /// Camera maker and model, e.g. "Apple" and "iPhone 15 Pro".
    var make: String?
    var model: String?
    /// The caption set in Immich; empty or absent when there is none.
    var description: String?
}

nonisolated struct Asset: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var ownerId: String
    var fileCreatedAt: String
    var type: AssetType
    /// Milliseconds. Older servers send a "H:MM:SS.ffffff" string, which is converted on decode.
    var durationMilliseconds: Int?
    var isFavorite: Bool
    var isArchived: Bool
    var isTrashed: Bool
    var isEdited: Bool
    /// Absent on old servers; `isArchived` is the fallback there.
    var visibility: AssetVisibility?
    var originalFileName: String?
    var checksum: String?
    var exifInfo: ExifInfo?

    /// Capture date when EXIF has one, else the file creation date. Sorting compares this as a string.
    var effectiveDate: String {
        if let original = exifInfo?.dateTimeOriginal, !original.isEmpty { return original }
        return fileCreatedAt
    }

    var isGIF: Bool { originalFileName?.lowercased().hasSuffix(".gif") ?? false }
    var isLocked: Bool { visibility == .locked }
    var fileSize: Int64? { exifInfo?.fileSizeInByte }

    private enum CodingKeys: String, CodingKey {
        case id, ownerId, fileCreatedAt, type, isFavorite, isArchived, isTrashed, isEdited
        case visibility, originalFileName, checksum, exifInfo
        case durationMilliseconds = "duration"
    }

    init(
        id: String,
        ownerId: String,
        fileCreatedAt: String,
        type: AssetType,
        durationMilliseconds: Int? = nil,
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false,
        isEdited: Bool = false,
        visibility: AssetVisibility? = nil,
        originalFileName: String? = nil,
        checksum: String? = nil,
        exifInfo: ExifInfo? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.fileCreatedAt = fileCreatedAt
        self.type = type
        self.durationMilliseconds = durationMilliseconds
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.isEdited = isEdited
        self.visibility = visibility
        self.originalFileName = originalFileName
        self.checksum = checksum
        self.exifInfo = exifInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decode(String.self, forKey: .ownerId)
        fileCreatedAt = try c.decode(String.self, forKey: .fileCreatedAt)
        type = try c.decode(AssetType.self, forKey: .type)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isTrashed = try c.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
        isEdited = try c.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
        visibility = try? c.decodeIfPresent(AssetVisibility.self, forKey: .visibility)
        originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName)
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum)
        exifInfo = try c.decodeIfPresent(ExifInfo.self, forKey: .exifInfo)

        if let ms = try? c.decodeIfPresent(Int.self, forKey: .durationMilliseconds) {
            durationMilliseconds = ms
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .durationMilliseconds) {
            durationMilliseconds = Asset.milliseconds(fromDuration: text)
        } else {
            durationMilliseconds = nil
        }
    }

    /// Parses the legacy "H:MM:SS.ffffff" duration format.
    static func milliseconds(fromDuration text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return Int(((hours * 3600 + minutes * 60 + seconds) * 1000).rounded())
    }
}

nonisolated struct Album: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var albumName: String
    var description: String?
    var assetCount: Int
    var albumThumbnailAssetId: String?

    static let virtualAllID = "virtual_all_assets"
    static let virtualOrphansID = "virtual_orphans"
    static let virtualDuplicatesID = "virtual_duplicates"

    /// Client-side pseudo-albums, plus the legacy "SKIP" album, which is always hidden.
    var isVirtual: Bool {
        [Self.virtualAllID, Self.virtualOrphansID, Self.virtualDuplicatesID].contains(id)
            || albumName.caseInsensitiveCompare("SKIP") == .orderedSame
    }
}

nonisolated struct User: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var email: String
    var name: String?
    var profileImagePath: String?
    var avatarColor: String?
    var quotaUsageInBytes: Int64?
    var quotaSizeInBytes: Int64?
}

nonisolated struct ServerVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

nonisolated struct DuplicateGroup: Codable, Hashable, Sendable {
    var duplicateId: String?
    var assets: [Asset]
}

nonisolated struct BulkIDResult: Codable, Hashable, Sendable {
    var id: String
    var success: Bool
    var error: String?
}
