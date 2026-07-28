/// The concrete client. Conforms to all three protocols in §5.3.
///
/// The separation only works because of how this type is *injected*, not
/// because of what it conforms to: the controller's dependency is declared as
/// `PlaybackReading & PlaybackQueueing`, so control logic cannot name a
/// transport method even though this object has one. Manual UI view models get
/// the same instance typed as `PlaybackTransport`.
///
/// Never inject `SpotifyPlayerClient` into the controller as its concrete
/// type. That would hand it the transport surface and dissolve R-2.
public struct SpotifyPlayerClient: PlaybackReading, PlaybackQueueing, PlaybackTransport {
    private let player: PlayerAPI

    public init(player: PlayerAPI) {
        self.player = player
    }

    // MARK: PlaybackReading

    public func playbackState() async throws -> PlaybackState {
        try await player.playbackState()
    }

    // MARK: PlaybackQueueing

    public func enqueue(_ uri: TrackURI) async throws {
        try await player.enqueue(uri)
    }

    // MARK: PlaybackTransport

    public func play(context: ContextURI, shuffle: Bool) async throws {
        // §7.3: shuffle is set for the fallback context at session start, then
        // playback begins from it. Shuffle first, on the assumption that the
        // mode should be in effect before the context starts — untested, and
        // worth confirming alongside V-4.
        try await player.setShuffle(shuffle)
        try await player.play(context: context)
    }

    public func pause() async throws {
        try await player.pause()
    }

    public func next() async throws {
        try await player.next()
    }

    public func previous() async throws {
        try await player.previous()
    }

    public func seek(toMillis millis: Int) async throws {
        try await player.seek(toMillis: millis)
    }

    public func setVolume(percent: Int) async throws {
        try await player.setVolume(percent: percent)
    }

    public func transfer(toDevice device: DeviceID) async throws {
        try await player.transfer(toDevice: device)
    }
}
