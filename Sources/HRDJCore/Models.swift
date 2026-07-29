// Standard library only. See CLAUDE.md §2.

/// The four energy tiers. SPEC.md §6.1.
///
/// The raw value is the zone index used throughout the control law: boundaries
/// are indexed by it, and the step limit (§6.5) arithmetic operates on it.
public enum Zone: Int, CaseIterable, Hashable, Sendable, Comparable, Codable {
    case z1 = 0
    case z2 = 1
    case z3 = 2
    case z4 = 3

    public var label: String {
        switch self {
        case .z1: "Recovery"
        case .z2: "Aerobic"
        case .z3: "Tempo"
        case .z4: "Hard"
        }
    }

    public static func < (lhs: Zone, rhs: Zone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One heart rate reading with the time it was taken.
public struct HRSample: Hashable, Sendable {
    public let at: Instant
    public let bpm: Int

    public init(at: Instant, bpm: Int) {
        self.at = at
        self.bpm = bpm
    }

    /// §6.2: samples outside this range are rejected before insertion into the
    /// window. Sensor dropout and contact loss produce values well outside it.
    public static let plausibleBPM: ClosedRange<Int> = 30...240

    public var isPlausible: Bool {
        Self.plausibleBPM.contains(bpm)
    }
}

/// A track, as much of one as the control law needs to know.
///
/// Intentionally free of Spotify types: HRDJCore does not import SpotifyKit, so
/// the URI is carried as an opaque string and the app layer does the mapping.
public struct TrackRef: Hashable, Sendable, Codable {
    /// Spotify track ID. Identity for the per-track commit guard (I1).
    public let id: String
    /// Spotify track URI, the value handed to `enqueue`.
    public let uri: String
    public let title: String
    /// Primary artist. Used by the artist-clustering rule in §8.
    public let primaryArtist: String
    public let durationMillis: Int

    public init(id: String, uri: String, title: String, primaryArtist: String, durationMillis: Int) {
        self.id = id
        self.uri = uri
        self.title = title
        self.primaryArtist = primaryArtist
        self.durationMillis = durationMillis
    }
}

/// One of the four configured pools. SPEC.md §8.
public enum PoolID: String, CaseIterable, Hashable, Sendable, Codable {
    case z1 = "Z1"
    case z2 = "Z2"
    case z3 = "Z3"
    case z4 = "Z4"

    /// Pool IDs are a deliberate 1:1 mirror of zones (§8). Keep this mapping
    /// explicit so adding a future zone cannot silently reshuffle playlists.
    public var zone: Zone {
        switch self {
        case .z1: .z1
        case .z2: .z2
        case .z3: .z3
        case .z4: .z4
        }
    }
}

extension Zone {
    /// Pool IDs are a deliberate 1:1 mirror of zones (§8). Keep this mapping
    /// explicit so adding a future zone cannot silently reshuffle playlists.
    public var poolID: PoolID {
        switch self {
        case .z1: .z1
        case .z2: .z2
        case .z3: .z3
        case .z4: .z4
        }
    }
}

/// The record of a single automatic decision. SPEC.md §11.3.
///
/// This is the tuning instrument for §6.7 and a first-class deliverable, not
/// debug output. It carries no wall-clock timestamp: HRDJCore has no wall
/// clock, so the logging layer stamps `t` when it serialises the record.
///
/// Not populated until M2 — the observe-only loop is what produces these. The
/// shape is fixed here so the log format does not drift once it starts
/// carrying data worth comparing across sessions.
public struct Decision: Hashable, Sendable, Codable {
    public enum Event: String, Hashable, Sendable, Codable {
        /// A commit attempt was made for the next track.
        case commit
        /// The commit window closed without a successful enqueue.
        case commitMiss = "commit_miss"
        /// The selected zone changed.
        case zoneChange = "zone_change"
        /// No fresh HR sample was available at decision time.
        case hrSampleGap = "hr_sample_gap"
        /// Automatic control was suspended after manual input.
        case overrideSet = "override_set"
        /// Automatic control resumed before the override hold expired.
        case overrideCleared = "override_cleared"
        /// Network failures suspended commits.
        case degradedEnter = "degraded_enter"
        /// Playback reads recovered and commits may resume.
        case degradedExit = "degraded_exit"
        /// The target pool had no eligible candidate.
        case poolStarvation = "pool_starvation"
        /// A track change was detected before the estimated boundary.
        case manualSkip = "manual_skip"
        /// A workout-control session started.
        case sessionStart = "session_start"
        /// A workout-control session ended.
        case sessionEnd = "session_end"
    }

    public enum Outcome: String, Hashable, Sendable, Codable {
        /// The attempted action completed.
        case success
        /// The attempted action failed and may be retried or logged as a miss.
        case failure
        /// The action was deliberately not attempted under current conditions.
        case skipped
    }

    /// Monotonic time of the decision. Excluded from the encoded form: the
    /// `"t"` field in §11.3 is a wall-clock stamp and only the app layer has a
    /// wall clock. The writer emits `"t"` alongside these fields.
    public var at: Instant = .reference
    public var event: Event

    public var hrInstant: Int?
    public var hrWindowMean: Double?
    public var windowSampleCount: Int?

    public var currentZone: Zone?
    public var rawZone: Zone?
    public var dwellSeconds: Double?
    public var eligibleZone: Zone?
    public var targetZone: Zone?
    public var overrideActive: Bool?

    public var trackID: String?
    public var trackRemainingMillis: Int?
    public var estimatedEndDriftMillis: Int?

    public var selectedURI: String?
    public var selectedFromPool: PoolID?
    public var attempt: Int?
    public var outcome: Outcome?
    public var httpStatus: Int?

    public init(at: Instant, event: Event) {
        self.at = at
        self.event = event
    }

    /// Field names are fixed by SPEC.md §11.3. The log is compared across
    /// sessions and tuning depends on it, so the wire names are pinned here
    /// rather than left to synthesis from Swift property names.
    private enum CodingKeys: String, CodingKey {
        case event
        case hrInstant
        case hrWindowMean
        case windowSampleCount
        case currentZone
        case rawZone
        case dwellSeconds
        case eligibleZone
        case targetZone
        case overrideActive
        case trackID = "trackId"
        case trackRemainingMillis = "trackRemainingMs"
        case estimatedEndDriftMillis = "estimatedEndDriftMs"
        case selectedURI = "selectedUri"
        case selectedFromPool
        case attempt
        case outcome
        case httpStatus
    }
}
