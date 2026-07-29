import Foundation
import HRDJCore
import SpotifyKit

/// Wires SpotifyKit together for the watch.
///
/// Note what is exposed and what is not. `reader` is the narrow
/// `PlaybackReading & PlaybackQueueing` composition that the M2 controller
/// will receive; `transport` is the same object, typed for the manual UI. The
/// controller must be handed `reader`, never `client` (SPEC.md §5.3, R-2).
struct SpotifyStack {
    let refresher: TokenRefresher
    let player: PlayerAPI
    let playlists: PlaylistAPI

    private let client: SpotifyPlayerClient

    init(configuration: SpotifyAuthConfiguration, store: any TokenStore, clock: any HRDJCore.Clock = SystemClock()) {
        let transport = URLSessionTransport()
        let refresher = TokenRefresher(
            client: AuthorizationClient(configuration: configuration, transport: transport),
            store: store,
            clock: clock
        )
        let api = SpotifyAPI(
            transport: transport,
            refresher: refresher,
            limiter: RateLimiter(clock: clock)
        )

        self.refresher = refresher
        self.player = PlayerAPI(api: api)
        self.playlists = PlaylistAPI(api: api)
        self.client = SpotifyPlayerClient(player: self.player)
    }

    /// What the automatic controller is allowed to see.
    var reader: any PlaybackReading & PlaybackQueueing { client }

    /// What manual UI view models are allowed to see.
    var transport: any PlaybackTransport { client }
}
