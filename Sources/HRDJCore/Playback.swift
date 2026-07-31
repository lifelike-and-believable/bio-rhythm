// Standard library only. See CLAUDE.md §2.

/// SPEC.md §5.3 — structural enforcement of the never-interrupt guarantee (R-2).
///
/// Three protocols, deliberately separated. `Controller.init` (M2) accepts
/// `PlaybackReading & PlaybackQueueing` and nothing else, so a skip call from
/// control logic is a compile error rather than a bug.
///
/// Do not add transport methods to `PlaybackReading` or `PlaybackQueueing`.
/// That is CLAUDE.md non-negotiable #1 and it is the whole mechanism.
///
/// **These live in `HRDJCore`, not `SpotifyKit` — the resolution of D-1.**
/// §5.2's file layout put them in `SpotifyKit`, which cannot survive contact
/// with M2: `Controller` lives here and has to name its own dependency, and
/// CLAUDE.md non-negotiable #2 forbids this module importing anything but the
/// standard library. Dependency inversion resolves it. `SpotifyKit` already
/// depends on `HRDJCore` and now conforms to these; nothing about the
/// separation in §5.3 changes, only which module declares it.
///
/// Every type here is deliberately free of Spotify vocabulary beyond the URI
/// strings themselves. A different backend would conform to the same three
/// protocols, which is what §15 means by keeping the rewrite contained.

public struct TrackURI: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct ContextURI: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// A playlist ID is what configuration stores; the play call needs a URI.
    public init(playlistID: String) { self.rawValue = "spotify:playlist:\(playlistID)" }
}

public struct DeviceID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct PlaybackDevice: Hashable, Sendable {
    public let id: DeviceID?
    public let name: String
    public let type: String
    public let isActive: Bool

    public init(id: DeviceID?, name: String, type: String, isActive: Bool) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
    }
}

public struct PlayingTrack: Hashable, Sendable {
    public let id: String
    public let uri: TrackURI
    public let title: String
    public let artists: [String]
    public let durationMillis: Int

    public init(id: String, uri: TrackURI, title: String, artists: [String], durationMillis: Int) {
        self.id = id
        self.uri = uri
        self.title = title
        self.artists = artists
        self.durationMillis = durationMillis
    }

    public var primaryArtist: String { artists.first ?? "" }
}

/// The projection of `GET /v1/me/player` this project uses. SPEC.md §4.2.
public struct PlaybackState: Hashable, Sendable {
    public let isPlaying: Bool
    public let progressMillis: Int?
    public let track: PlayingTrack?
    public let device: PlaybackDevice?
    public let shuffleState: Bool

    public init(
        isPlaying: Bool,
        progressMillis: Int?,
        track: PlayingTrack?,
        device: PlaybackDevice?,
        shuffleState: Bool
    ) {
        self.isPlaying = isPlaying
        self.progressMillis = progressMillis
        self.track = track
        self.device = device
        self.shuffleState = shuffleState
    }

    /// Milliseconds left in the current track, if both figures are known.
    /// Input to the boundary estimate in §7.1.
    public var remainingMillis: Int? {
        guard let track, let progressMillis else { return nil }
        return max(0, track.durationMillis - progressMillis)
    }
}

public protocol PlaybackReading: Sendable {
    func playbackState() async throws -> PlaybackState
}

public protocol PlaybackQueueing: Sendable {
    func enqueue(_ uri: TrackURI) async throws
}

// NOT visible to Controller. Injected only into manual UI view models.
public protocol PlaybackTransport: Sendable {
    func play(context: ContextURI, shuffle: Bool) async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(toMillis: Int) async throws
    func setVolume(percent: Int) async throws
    func transfer(toDevice: DeviceID) async throws
}
