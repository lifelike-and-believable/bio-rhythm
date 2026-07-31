// Standard library only. See CLAUDE.md §2.

/// Boundary estimation. SPEC.md §7.1.
///
/// The whole commit schedule is expressed relative to the moment the current
/// track ends, and nothing tells us when that is. Polling at 1 Hz would answer
/// it and is unacceptable — battery, and the rate limit. So: derive the end
/// locally from one observation, run it forward against the monotonic clock,
/// and correct it whenever a poll happens to arrive.
///
/// ```
/// remainingAtObs = duration_ms - progress_ms
/// estimatedEnd   = observedAt + remainingAtObs
/// ```
///
/// Drift is bounded by the poll interval, because the estimate is rebuilt from
/// scratch on every observation rather than nudged toward the new value. §7.1
/// is explicit about that — "re-derive rather than smoothing" — and it matters
/// most in exactly the case smoothing would feel most natural: a seek. A
/// smoothed estimate after a 45-second scrub is wrong for several polls
/// afterwards, and wrong in a way that puts the commit window in the wrong
/// place. A re-derived one is right immediately.
///
/// A correction larger than `seekThreshold` is reported as a seek rather than
/// as drift. The estimate is handled identically either way; the distinction
/// exists because the caller wants to know — §11.3 logs it, and a seek is the
/// kind of manual input §6.6's override hold exists for.
///
/// ## What this type does not do
///
/// No polling, no scheduling, and no opinion about when to commit. It answers
/// "when does this track end, as far as anyone here knows" and reports what
/// changed since last time. `CommitScheduler` owns the rest.
public struct TrackClock: Hashable, Sendable {
    /// What an observation turned out to be. Returned rather than stored: the
    /// caller acts on it once and the model keeps only the estimate.
    public struct Observation: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// Nothing playable in the state — no track, or no `progress_ms`.
            /// The previous estimate is deliberately kept (see `observe`).
            case idle
            /// A different track ID than last time, or the first observation.
            /// Per-track state — the I1 commit guard above all — resets here.
            case started(trackID: String)
            /// Same track, correction within `seekThreshold`.
            case continued
            /// Same track, correction beyond `seekThreshold`. §7.1 treats this
            /// as evidence of a seek.
            case seekDetected
        }

        public let kind: Kind
        /// How far this observation moved the estimated end. Positive means the
        /// track now ends *later* than previously believed. Nil for `idle` and
        /// `started`, where there was no previous estimate to move.
        ///
        /// This is §11.3's `estimatedEndDriftMs`.
        public let drift: Duration?

        public var isTrackChange: Bool {
            if case .started = kind { return true }
            return false
        }
    }

    /// §7.1: "any single-poll correction larger than 3 s".
    public let seekThreshold: Duration

    public private(set) var trackID: String?
    public private(set) var durationMillis: Int?
    public private(set) var estimatedEnd: Instant?
    public private(set) var lastObservedAt: Instant?
    /// From the last observation. I4 forbids enqueueing while this is false,
    /// and the scheduler needs somewhere to read it from.
    public private(set) var isPlaying: Bool = false

    public init(seekThreshold: Duration = .seconds(3)) {
        self.seekThreshold = seekThreshold
    }

    public var isEstablished: Bool { estimatedEnd != nil }

    /// Time until the estimated end. **Signed** — negative once the estimate
    /// has passed, which the scheduler needs in order to notice it has missed
    /// the window rather than waiting forever for a positive number.
    public func remaining(at now: Instant) -> Duration? {
        guard let estimatedEnd else { return nil }
        return estimatedEnd - now
    }

    /// The projection of `GET /v1/me/player` this project uses (§4.2).
    @discardableResult
    public mutating func observe(_ state: PlaybackState, at now: Instant) -> Observation {
        observe(
            trackID: state.track?.id,
            durationMillis: state.track?.durationMillis,
            progressMillis: state.progressMillis,
            isPlaying: state.isPlaying,
            at: now
        )
    }

    @discardableResult
    public mutating func observe(
        trackID id: String?,
        durationMillis duration: Int?,
        progressMillis progress: Int?,
        isPlaying playing: Bool,
        at now: Instant
    ) -> Observation {
        isPlaying = playing
        lastObservedAt = now

        guard let id, let duration, let progress else {
            // A 204, a podcast episode, or a state with a null progress. None
            // of those is evidence that the track ended, so the estimate is
            // kept rather than cleared: dropping it would make the scheduler
            // forget a commit window it is in the middle of, and one empty
            // response mid-track is a network event, not a musical one.
            return Observation(kind: .idle, drift: nil)
        }

        let derived = now + .milliseconds(max(0, duration - progress))

        guard id == trackID, let previous = estimatedEnd else {
            trackID = id
            durationMillis = duration
            estimatedEnd = derived
            return Observation(kind: .started(trackID: id), drift: nil)
        }

        let correction = derived - previous

        // §7.1: re-derive, never smooth. The assignment is the whole rule.
        estimatedEnd = derived
        durationMillis = duration

        let magnitude = correction < .zero ? .zero - correction : correction
        return Observation(
            kind: magnitude > seekThreshold ? .seekDetected : .continued,
            drift: correction
        )
    }

    /// Clears everything. Session teardown, not track change — a track change
    /// is handled by `observe` returning `.started`.
    public mutating func reset() {
        trackID = nil
        durationMillis = nil
        estimatedEnd = nil
        lastObservedAt = nil
        isPlaying = false
    }
}
