import Foundation

// Request and response bodies for the JSON endpoints in docs/PORTING_SPEC.md §1.2.
// Optional properties that are nil are left out of the encoded JSON.

/// Body for `POST /search/metadata`.
nonisolated struct MetadataSearch: Encodable, Hashable, Sendable {
    var albumIds: [String]?
    var isNotInAlbum: Bool?
    var visibility: AssetVisibility?
    var type: AssetType?
    var isFavorite: Bool?
    var withExif: Bool? = true
    /// Deprecated since server v3.2.0 but still honoured; kept so older servers sort the same way.
    var order: SortDirection?
    var size: Int? = 500
    /// Page number for servers before v3.2.0.
    var page: Int?
    /// Paging token for servers from v3.2.0. Takes the place of `page` when set.
    var cursor: String?

    enum SortDirection: String, Encodable, Sendable { case asc, desc }

    /// Search filters only, as accepted by `POST /search/statistics`.
    var statistics: StatisticsSearch {
        StatisticsSearch(albumIds: albumIds, isNotInAlbum: isNotInAlbum, visibility: visibility, type: type, isFavorite: isFavorite)
    }
}

/// Body for `POST /search/statistics`.
nonisolated struct StatisticsSearch: Encodable, Hashable, Sendable {
    var albumIds: [String]?
    var isNotInAlbum: Bool?
    var visibility: AssetVisibility?
    var type: AssetType?
    var isFavorite: Bool?
}

nonisolated struct SearchPage: Decodable, Sendable {
    var items: [Asset]
    var total: Int
    var nextPage: String?
    var nextCursor: String?

    var hasMore: Bool { nextCursor != nil || nextPage != nil }
}

nonisolated struct SearchResponse: Decodable, Sendable {
    var assets: SearchPage
}

nonisolated struct SearchStatistics: Decodable, Sendable {
    var total: Int
}

nonisolated struct CreateAlbumRequest: Encodable, Sendable {
    var albumName: String
    var description: String?
    var assetIds: [String]?
}

nonisolated struct BulkIDsRequest: Encodable, Sendable {
    var ids: [String]
}

nonisolated struct DeleteAssetsRequest: Encodable, Sendable {
    var ids: [String]
    /// False moves assets to the Immich trash; true deletes them permanently.
    var force: Bool
}

/// Body for `PUT /assets/{id}`. An empty description clears it.
nonisolated struct UpdateAssetRequest: Encodable, Sendable {
    var description: String
}

nonisolated struct UpdateAssetsRequest: Encodable, Sendable {
    var ids: [String]
    var isFavorite: Bool?
    var visibility: AssetVisibility?
}

/// Body for `PUT /assets/{id}/edits` with a single rotation.
nonisolated struct RotateEditRequest: Encodable, Sendable {
    struct Edit: Encodable, Sendable {
        struct Parameters: Encodable, Sendable { var angle: Int }
        var action = "rotate"
        var parameters: Parameters
    }

    var edits: [Edit]

    init(angle: Int) {
        edits = [Edit(parameters: .init(angle: angle))]
    }
}
