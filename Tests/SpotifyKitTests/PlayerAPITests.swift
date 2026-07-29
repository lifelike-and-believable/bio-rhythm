import Foundation
import Testing
import HRDJCore
import SpotifyKit

@Suite("Player endpoints — SPEC.md §4.2")
struct PlayerAPITests {
    private func makePlayer(transport: FakeTransport) -> PlayerAPI {
        let clock = FakeClock()
        return PlayerAPI(
            api: SpotifyAPI(
                transport: transport,
                refresher: makeRefresher(
                    transport: transport,
                    store: InMemoryTokenStore(refreshToken: "seed"),
                    clock: clock
                ),
                limiter: RateLimiter(permitsPerMinute: 60, burst: 10, clock: clock)
            )
        )
    }

    @Test("204 from /me/player means nothing is playing, not an error")
    func noActiveDevice() async throws {
        // This is what the watch sees before playback has been transferred to
        // it, so treating it as a failure would make session start look broken.
        let player = makePlayer(transport: FakeTransport(script: [HTTPResponse(status: 204)]))

        let state = try await player.playbackState()

        #expect(state.isPlaying == false)
        #expect(state.track == nil)
        #expect(state.device == nil)
        #expect(state.remainingMillis == nil)
    }

    @Test("enqueue posts the URI to the queue endpoint and nothing else")
    func enqueueUsesQueueEndpoint() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 204)])
        let player = makePlayer(transport: transport)

        try await player.enqueue(TrackURI("spotify:track:4iV5W9uYEdYUVa79Axb7Rh"))

        let requests = await transport.apiRequests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.url.hasPrefix("https://api.spotify.com/v1/me/player/queue?uri="))

        // R-2: the only actuator. If a commit ever issues a transport call,
        // this is where it would show up first.
        //
        // Compare parsed paths for equality rather than searching the whole
        // URL for a substring. An earlier version looked for "/play", which is
        // a substring of "/v1/me/player/queue" through "player" — and any
        // substring check stays vulnerable to the same thing from the other
        // direction, since a track URI lands in the query string.
        let paths = try requests.map { try #require(URL(string: $0.url)?.path) }
        let transportEndpoints: Set<String> = [
            "/v1/me/player/pause",
            "/v1/me/player/next",
            "/v1/me/player/previous",
            "/v1/me/player/seek",
            "/v1/me/player/volume",
            "/v1/me/player/play",
            "/v1/me/player/shuffle",
        ]
        #expect(paths.contains { transportEndpoints.contains($0) } == false)
        #expect(paths == ["/v1/me/player/queue"])
    }

    @Test("Transfer targets the requested device without starting playback")
    func transferDoesNotAutoPlay() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 204)])
        let player = makePlayer(transport: transport)

        try await player.transfer(toDevice: DeviceID("watch-device-id"))

        let request = try #require(await transport.apiRequests.first)
        #expect(request.method == "PUT")
        #expect(request.url == "https://api.spotify.com/v1/me/player")

        let body = try #require(request.body)
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        #expect(json["device_ids"] as? [String] == ["watch-device-id"])
        // §7.4 acquires the device first and starts the fallback context in a
        // separate, deliberate step.
        #expect(json["play"] as? Bool == false)
    }

    @Test("Volume is clamped to the API's range")
    func volumeClamped() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 204)])
        let player = makePlayer(transport: transport)

        try await player.setVolume(percent: 150)

        let request = try #require(await transport.apiRequests.first)
        #expect(request.url.contains("volume_percent=100"))
    }

    @Test("Session start sets shuffle before starting the context")
    func playSetsShuffleFirst() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 204)])
        let client = SpotifyPlayerClient(player: makePlayer(transport: transport))

        try await client.play(context: ContextURI(playlistID: "pool-z2"), shuffle: true)

        let urls = await transport.apiRequests.map(\.url)
        #expect(urls.count == 2)
        #expect(urls[0].contains("/v1/me/player/shuffle?state=true"))
        #expect(urls[1].hasSuffix("/v1/me/player/play"))
    }

    @Test("A playlist ID becomes a context URI")
    func contextURIFromPlaylistID() {
        #expect(ContextURI(playlistID: "37i9dQZF1DX").rawValue == "spotify:playlist:37i9dQZF1DX")
    }

    @Test("Remaining time comes from duration minus progress")
    func remainingTime() {
        let state = PlaybackState(
            isPlaying: true,
            progressMillis: 160_000,
            track: PlayingTrack(
                id: "t1",
                uri: TrackURI("spotify:track:t1"),
                title: "Something",
                artists: ["An Artist"],
                durationMillis: 180_000
            ),
            device: nil,
            shuffleState: true
        )
        // §7.1 feeds this straight into the boundary estimate.
        #expect(state.remainingMillis == 20_000)
    }

    @Test("Progress past duration clamps to zero rather than going negative")
    func remainingNeverNegative() {
        let state = PlaybackState(
            isPlaying: true,
            progressMillis: 200_000,
            track: PlayingTrack(
                id: "t1",
                uri: TrackURI("spotify:track:t1"),
                title: "Something",
                artists: [],
                durationMillis: 180_000
            ),
            device: nil,
            shuffleState: false
        )
        #expect(state.remainingMillis == 0)
    }
}
