/// Wire types for the playlist endpoints in SPEC.md §4.3.
///
/// **The Feb 2026 rename is the load-bearing detail here.** Per §4.3:
///
///     GET /v1/playlists/{id}/tracks  →  GET /v1/playlists/{id}/items
///     tracks               →  items          (the object on a playlist)
///     tracks.tracks        →  items.items    (the paging array)
///     tracks.tracks.track  →  items.items.item
///
/// So a playlist item wrapper carries `item`, not `track`. Pre-2026 model
/// knowledge says `track` and is wrong.
///
/// These shapes are inferred from the spec, not captured. V-1 is the check
/// that they are right, and it also answers whether Prompted Playlists return
/// an `items` object at all. Do not build §8 on top of this until V-1 is
/// answered — SPEC.md §12 says as much.

struct PagingDTO<Element: Decodable & Sendable>: Decodable, Sendable {
    var items: [Element]?
    var limit: Int?
    var offset: Int?
    var total: Int?
    var next: String?
}

/// One entry in a playlist's item list. The track lives under `item`.
struct PlaylistItemDTO: Decodable, Sendable {
    var item: TrackObjectDTO?
    var isLocal: Bool?
    var addedAt: String?

    enum CodingKeys: String, CodingKey {
        case item
        case isLocal = "is_local"
        case addedAt = "added_at"
    }
}

/// `GET /v1/playlists/{id}` — metadata, with the nested `items` paging object.
struct PlaylistDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var uri: String?
    var owner: PlaylistOwnerDTO?
    /// Present only for playlists owned by the authenticated user (§4.3).
    var items: PagingDTO<PlaylistItemDTO>?
}

struct PlaylistOwnerDTO: Decodable, Sendable {
    var id: String?
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// `GET /v1/me/playlists` — pool discovery during setup.
struct SimplifiedPlaylistDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var uri: String?
    var owner: PlaylistOwnerDTO?
}
