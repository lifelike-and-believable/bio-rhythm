import Foundation
import Testing
import HRDJCore
@testable import SpotifyKit

/// Decoding against **captured** responses. SPEC.md §14.3.
///
/// The fixtures directory is empty at M0 and these tests report a known issue
/// until it is filled. That is deliberate: CLAUDE.md forbids hand-writing
/// fixtures, and the post-Feb-2026 field names in `DTOs/` are inferred from
/// SPEC.md §4.3 rather than observed. Hand-written JSON here would test the
/// inference against itself and prove nothing.
///
/// Run `Scripts/capture-fixtures.sh` with a user token to populate it. The
/// playlist-items capture is also the evidence for V-1.
@Suite("DTO decoding against captured fixtures")
struct FixtureDecodingTests {
    private func fixture(_ name: String) -> Data? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func pending(_ name: String) {
        withKnownIssue("No captured \(name).json yet — see Tests/SpotifyKitTests/Fixtures/README.md") {
            Issue.record("fixture \(name).json is missing")
        }
    }

    @Test("player-state.json decodes to a usable playback state")
    func playerState() throws {
        guard let data = fixture("player-state") else { return pending("player-state") }

        let dto = try JSONDecoder().decode(PlayerStateDTO.self, from: data)
        let state = dto.asPlaybackState

        let track = try #require(state.track, "captured state should have been taken while a track was playing")
        #expect(track.id.isEmpty == false)
        #expect(track.durationMillis > 0)
        #expect(state.progressMillis != nil)
        // §7.1 cannot estimate a boundary without both of these.
        #expect(state.remainingMillis != nil)
    }

    @Test("playlist-items.json uses the Feb 2026 field names")
    func playlistItems() throws {
        guard let data = fixture("playlist-items") else { return pending("playlist-items") }

        let page = try JSONDecoder().decode(PagingDTO<PlaylistItemDTO>.self, from: data)
        let items = try #require(page.items)
        #expect(items.isEmpty == false)

        // The whole point of V-1: entries carry `item`, not `track`, and the
        // playlist is readable at all. If this fails against a Prompted
        // Playlist capture, §8 needs the manual-duplication fallback.
        let first = try #require(items.first)
        let track = try #require(first.item, "entry has no `item` — check whether the field is still `track`")
        #expect(track.id != nil)
        #expect(track.durationMs != nil)
    }

    @Test("devices.json decodes")
    func devices() throws {
        guard let data = fixture("devices") else { return pending("devices") }

        let dto = try JSONDecoder().decode(DevicesResponseDTO.self, from: data)
        let devices = try #require(dto.devices)
        #expect(devices.isEmpty == false)
        #expect(devices.allSatisfy { $0.name != nil })
    }

    @Test("queue.json decodes")
    func queue() throws {
        guard let data = fixture("queue") else { return pending("queue") }

        let dto = try JSONDecoder().decode(QueueResponseDTO.self, from: data)
        #expect(dto.queue != nil)
    }

    @Test("playlist.json exposes the nested items object")
    func playlist() throws {
        guard let data = fixture("playlist") else { return pending("playlist") }

        let dto = try JSONDecoder().decode(PlaylistDTO.self, from: data)
        #expect(dto.id != nil)
        // §4.3: only playlists owned by the authenticated user return an
        // `items` object. If this is nil for a Prompted Playlist, that is the
        // V-1 answer and it is a bad one.
        #expect(dto.items != nil)
    }
}
