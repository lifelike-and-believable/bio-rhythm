import Foundation
import HRDJCore

/// The playlist endpoints from SPEC.md §4.3.
///
/// The path is `/items`, not `/tracks` — renamed in Feb 2026. Pre-2026 model
/// knowledge and most sample code on the internet are wrong about this.
public struct PlaylistAPI: Sendable {
    /// Spotify's per-page maximum for playlist items.
    public static let maxPageSize = 100

    private let api: SpotifyAPI

    public init(api: SpotifyAPI) {
        self.api = api
    }

    /// `GET /v1/me/playlists`. Pool discovery during setup.
    public func myPlaylists(limit: Int = 50, offset: Int = 0) async throws -> [(id: String, name: String)] {
        let response = try await api.send(
            method: "GET",
            path: "/v1/me/playlists",
            query: ["limit": String(limit), "offset": String(offset)]
        )
        let page = try api.decode(PagingDTO<SimplifiedPlaylistDTO>.self, from: response)
        return (page.items ?? []).compactMap { dto in
            guard let id = dto.id else { return nil }
            return (id: id, name: dto.name ?? "")
        }
    }

    /// `GET /v1/playlists/{id}`. Metadata.
    public func playlistName(id: String) async throws -> String {
        let response = try await api.send(method: "GET", path: "/v1/playlists/\(id)")
        return try api.decode(PlaylistDTO.self, from: response).name ?? ""
    }

    /// `GET /v1/playlists/{id}/items`, paginated to exhaustion.
    ///
    /// Applies the §8 ingest filter: entries with no track, non-track types,
    /// local files, and unplayable tracks are dropped here rather than
    /// downstream, so the pool only ever holds things that can actually play.
    /// The blocklist is applied by `PoolManager` (M4), not here.
    ///
    /// **Unverified against the live API.** V-1 asks whether Prompted
    /// Playlists return an `items` object at all; §8 must not be built on top
    /// of this until that is answered.
    public func items(playlistID: String, pageSize: Int = maxPageSize) async throws -> [TrackRef] {
        var collected: [TrackRef] = []
        var offset = 0

        while true {
            let response = try await api.send(
                method: "GET",
                path: "/v1/playlists/\(playlistID)/items",
                query: ["limit": String(pageSize), "offset": String(offset)]
            )
            let page = try api.decode(PagingDTO<PlaylistItemDTO>.self, from: response)
            let entries = page.items ?? []

            for entry in entries {
                if entry.isLocal == true { continue }
                guard let track = entry.item else { continue }
                if track.isLocal == true { continue }
                if (track.type ?? "track") != "track" { continue }
                if track.isPlayable == false { continue }
                guard let id = track.id, let uri = track.uri, let duration = track.durationMs else { continue }

                collected.append(
                    TrackRef(
                        id: id,
                        uri: uri,
                        title: track.name ?? "",
                        primaryArtist: track.artists?.first?.name ?? "",
                        durationMillis: duration
                    )
                )
            }

            offset += entries.count
            let total = page.total ?? offset
            if entries.isEmpty || page.next == nil || offset >= total {
                break
            }
        }

        return collected
    }
}
