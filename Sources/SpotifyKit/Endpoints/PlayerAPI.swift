import Foundation
import HRDJCore

/// The player endpoints from SPEC.md §4.2, and only those.
///
/// Withdrawn endpoints (§4.4) are not implemented and must not be added:
/// `/v1/audio-features`, `/v1/audio-analysis`, `/v1/recommendations`,
/// `/v1/artists/{id}/related-artists`, `/v1/browse/featured-playlists`,
/// batch `/v1/tracks`, `/v1/artists/{id}/top-tracks`, `/v1/markets`,
/// `/v1/users/{id}/playlists`. They return 403 for any app created after
/// 2024-11-27. If something here seems to need one, stop and ask.
public struct PlayerAPI: Sendable {
    private let api: SpotifyAPI

    public init(api: SpotifyAPI) {
        self.api = api
    }

    /// `GET /v1/me/player`. Primary state read.
    ///
    /// Returns 204 with an empty body when there is no active device, which is
    /// a normal condition rather than an error — it is what the watch sees
    /// before playback has been transferred to it.
    public func playbackState() async throws -> PlaybackState {
        let response = try await api.send(method: "GET", path: "/v1/me/player")
        guard response.status != 204, !response.body.isEmpty else {
            return PlaybackState(
                isPlaying: false,
                progressMillis: nil,
                track: nil,
                device: nil,
                shuffleState: false
            )
        }
        return try api.decode(PlayerStateDTO.self, from: response).asPlaybackState
    }

    /// `POST /v1/me/player/queue`. The only actuator the automatic controller
    /// is allowed to reach (§4.2, §5.3). Append-only: queued items cannot be
    /// removed or reordered, which is what makes the commit a one-shot
    /// decision (§7.3).
    public func enqueue(_ uri: TrackURI) async throws {
        try await api.send(
            method: "POST",
            path: "/v1/me/player/queue",
            query: ["uri": uri.rawValue]
        )
    }

    /// `GET /v1/me/player/queue`. Diagnostic and commit verification only.
    public func queue() async throws -> [PlayingTrack] {
        let response = try await api.send(method: "GET", path: "/v1/me/player/queue")
        guard response.status != 204, !response.body.isEmpty else { return [] }
        let dto = try api.decode(QueueResponseDTO.self, from: response)
        return (dto.queue ?? []).compactMap(\.asPlayingTrack)
    }

    /// `GET /v1/me/player/devices`. Device selection at session start.
    public func devices() async throws -> [PlaybackDevice] {
        let response = try await api.send(method: "GET", path: "/v1/me/player/devices")
        let dto = try api.decode(DevicesResponseDTO.self, from: response)
        return (dto.devices ?? []).map(\.asPlaybackDevice)
    }

    // MARK: - Session start and manual transport
    //
    // Everything below is reachable only from session setup and the manual UI.
    // None of it is exposed through `PlaybackReading` or `PlaybackQueueing`.

    /// `PUT /v1/me/player`. Transfer playback to the watch.
    public func transfer(toDevice device: DeviceID, startPlaying: Bool = false) async throws {
        struct Body: Encodable {
            let device_ids: [String]
            let play: Bool
        }
        let body = try JSONEncoder().encode(Body(device_ids: [device.rawValue], play: startPlaying))
        try await api.send(method: "PUT", path: "/v1/me/player", body: body)
    }

    /// `PUT /v1/me/player/shuffle`. Session start only.
    public func setShuffle(_ enabled: Bool) async throws {
        try await api.send(
            method: "PUT",
            path: "/v1/me/player/shuffle",
            query: ["state": enabled ? "true" : "false"]
        )
    }

    /// `PUT /v1/me/player/play` with `context_uri` = the fallback pool.
    /// Session start only, and never reachable from the controller (§7.3).
    public func play(context: ContextURI) async throws {
        struct Body: Encodable {
            let context_uri: String
        }
        let body = try JSONEncoder().encode(Body(context_uri: context.rawValue))
        try await api.send(method: "PUT", path: "/v1/me/player/play", body: body)
    }

    public func pause() async throws {
        try await api.send(method: "PUT", path: "/v1/me/player/pause")
    }

    public func next() async throws {
        try await api.send(method: "POST", path: "/v1/me/player/next")
    }

    public func previous() async throws {
        try await api.send(method: "POST", path: "/v1/me/player/previous")
    }

    public func seek(toMillis millis: Int) async throws {
        try await api.send(
            method: "PUT",
            path: "/v1/me/player/seek",
            query: ["position_ms": String(millis)]
        )
    }

    public func setVolume(percent: Int) async throws {
        try await api.send(
            method: "PUT",
            path: "/v1/me/player/volume",
            query: ["volume_percent": String(min(100, max(0, percent)))]
        )
    }
}
