/// Wire types for the player endpoints in SPEC.md §4.2.
///
/// Field names are post-Feb-2026. `popularity` and `available_markets` are gone
/// from the track object (§4.4) and are deliberately not modelled — adding them
/// back would decode to nil forever and imply data that no longer exists.
///
/// Every shape here is *inferred from the spec*, not from a captured response.
/// `Tests/SpotifyKitTests/Fixtures` is empty until real captures land (see
/// Scripts/capture-fixtures.sh and V-1); until then these decoders are
/// unverified against the live API. Treat a decode failure on device as
/// evidence about the API, not necessarily about the code.

struct PlayerStateDTO: Decodable, Sendable {
    var device: DeviceDTO?
    var shuffleState: Bool?
    var isPlaying: Bool?
    var progressMs: Int?
    var item: TrackObjectDTO?

    enum CodingKeys: String, CodingKey {
        case device
        case shuffleState = "shuffle_state"
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
        case item
    }
}

struct TrackObjectDTO: Decodable, Sendable {
    var id: String?
    var uri: String?
    var name: String?
    var durationMs: Int?
    var artists: [ArtistRefDTO]?
    /// "track" or "episode". Podcast episodes appear here and are filtered out.
    var type: String?
    var isPlayable: Bool?
    var isLocal: Bool?

    enum CodingKeys: String, CodingKey {
        case id, uri, name, artists, type
        case durationMs = "duration_ms"
        case isPlayable = "is_playable"
        case isLocal = "is_local"
    }
}

struct ArtistRefDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var uri: String?
}

struct DeviceDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var type: String?
    var isActive: Bool?
    var isRestricted: Bool?
    var volumePercent: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
    }
}

struct DevicesResponseDTO: Decodable, Sendable {
    var devices: [DeviceDTO]?
}

/// `GET /v1/me/player/queue` — diagnostic and commit verification only (§4.2).
struct QueueResponseDTO: Decodable, Sendable {
    var currentlyPlaying: TrackObjectDTO?
    var queue: [TrackObjectDTO]?

    enum CodingKeys: String, CodingKey {
        case currentlyPlaying = "currently_playing"
        case queue
    }
}

// MARK: - Mapping to domain types

extension TrackObjectDTO {
    /// Nil unless this is a playable, non-local track with the fields the
    /// control law needs. §8 "filter on ingest" applies the same rules.
    var asPlayingTrack: PlayingTrack? {
        guard let id, let uri, let durationMs else { return nil }
        guard (type ?? "track") == "track" else { return nil }
        return PlayingTrack(
            id: id,
            uri: TrackURI(uri),
            title: name ?? "",
            artists: (artists ?? []).compactMap(\.name),
            durationMillis: durationMs
        )
    }
}

extension DeviceDTO {
    var asPlaybackDevice: PlaybackDevice {
        PlaybackDevice(
            id: id.map(DeviceID.init(_:)),
            name: name ?? "",
            type: type ?? "",
            isActive: isActive ?? false
        )
    }
}

extension PlayerStateDTO {
    var asPlaybackState: PlaybackState {
        PlaybackState(
            isPlaying: isPlaying ?? false,
            progressMillis: progressMs,
            track: item?.asPlayingTrack,
            device: device?.asPlaybackDevice,
            shuffleState: shuffleState ?? false
        )
    }
}
