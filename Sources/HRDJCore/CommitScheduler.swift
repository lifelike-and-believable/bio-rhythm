// Standard library only. See CLAUDE.md §2.

/// The per-track commit state machine. SPEC.md §7.2.
///
/// One decision per track, taken as late as is safe. Late because the queue is
/// append-only (§7.3) — a queued track cannot be removed or reordered, so the
/// commit is a one-shot bet and the zone that informs it should be as fresh as
/// possible. Safe because a commit that lands after the boundary has already
/// passed does nothing at all.
///
/// ```
/// OBSERVING ──── remaining <= COMMIT_OPEN ────▶ COMMITTING ──success──▶ COMMITTED
///                                                   │
///                                    remaining < COMMIT_DEADLINE
///                                                   ▼
///                                                MISSED
/// ```
///
/// ## This type issues no network calls
///
/// It decides *whether an attempt should be made now* and records what came of
/// it. `Controller` owns the `enqueue` and hands the outcome back. That split
/// is what makes I1–I4 testable against a fake clock with no `FakeSpotify` in
/// the way, and it is why `decision(remaining:isPlaying:at:)` is pure — the
/// caller may ask as often as it likes.
///
/// ## Where the invariants live
///
/// - **I1** — at most one successful enqueue per track ID. `.committed` is
///   terminal for the track, and `trackChanged(to:at:)` is the only way out.
/// - **I2** — nothing before `estimatedEnd - COMMIT_OPEN`.
/// - **I3** — nothing after `estimatedEnd - COMMIT_DEADLINE`.
/// - **I4** — nothing while `is_playing == false`.
///
/// All four are properties of `decision(remaining:isPlaying:at:)`, which is a
/// single function with no hidden state, so the tests assert them directly
/// rather than through a simulated session.
public struct CommitScheduler: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// No track observed yet.
        case idle
        /// Accumulating HR; the commit window has not opened.
        case observing
        /// Inside the window. Attempts are allowed at the §6.7 slots.
        case committing
        /// Committed for this track. **No further writes** (I1).
        case committed
        /// Past `COMMIT_DEADLINE` without a success. The fallback context
        /// plays (§7.3) and the miss is logged.
        case missed
    }

    /// Why an evaluation produced no attempt. Carried so §11.3 can log the
    /// reason rather than an unexplained absence — "no commit happened" and
    /// "no commit was allowed to happen, because the track was paused" are
    /// very different lines in a trace being read three weeks later.
    public enum WaitReason: Hashable, Sendable {
        case noTrack
        case noEstimate
        /// I2. Still earlier than `COMMIT_OPEN`.
        case windowNotOpen
        /// I4.
        case notPlaying
        /// An attempt has already been made in this retry slot; the next one
        /// is not due yet.
        case awaitingNextSlot
        /// Terminal for this track: already committed, or already missed.
        case settled
    }

    public enum Decision: Hashable, Sendable {
        case wait(WaitReason)
        /// Attempt an `enqueue` now. `number` is 1-based and matches the §6.7
        /// slot: 1 at `COMMIT_OPEN`, 2 at `COMMIT_RETRY_1`, 3 at
        /// `COMMIT_RETRY_2`.
        case attempt(number: Int)
        /// Past `COMMIT_DEADLINE` with no success. Transition with
        /// `recordAbandon(at:)`.
        case abandon
    }

    public let configuration: ControlConfiguration

    public private(set) var state: State = .idle
    public private(set) var trackID: String?
    /// Attempts made for the current track, successful or not.
    public private(set) var attempts: Int = 0
    public private(set) var lastAttemptAt: Instant?
    public private(set) var trackStartedAt: Instant?
    /// Set when the track was first seen with less than `SHORT_TRACK_THRESHOLD`
    /// remaining. Carried for the log, not for the logic — see `nextEvaluation`.
    public private(set) var startedShort: Bool = false

    /// The §6.7 attempt slots, latest first. One attempt is permitted in each,
    /// so a burst of polls inside one slot cannot become a burst of enqueues.
    /// Derived rather than hardcoded so that R-13 editing the constants moves
    /// the slots with them.
    var slots: [Duration] {
        [configuration.commitOpen, configuration.commitRetry1, configuration.commitRetry2]
    }

    public init(configuration: ControlConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Track lifecycle

    /// A new track is playing. Resets everything per-track, including the I1
    /// guard — this is the only transition out of `.committed` or `.missed`.
    ///
    /// `remaining` is used only to record whether the track started short.
    public mutating func trackChanged(
        to newTrackID: String,
        remaining: Duration? = nil,
        at now: Instant
    ) {
        trackID = newTrackID
        state = .observing
        attempts = 0
        lastAttemptAt = nil
        trackStartedAt = now
        startedShort = remaining.map { $0 <= configuration.shortTrackThreshold } ?? false
    }

    /// Session teardown.
    public mutating func reset() {
        state = .idle
        trackID = nil
        attempts = 0
        lastAttemptAt = nil
        trackStartedAt = nil
        startedShort = false
    }

    // MARK: - The decision

    /// Whether to attempt a commit at `now`. Pure.
    ///
    /// `remaining` comes from `TrackClock.remaining(at:)` and is signed — a
    /// negative value means the estimate has already passed, which is exactly
    /// the case `.abandon` exists for.
    public func decision(remaining: Duration?, isPlaying: Bool, at now: Instant) -> Decision {
        // I1: terminal states admit nothing further for this track.
        guard state != .committed, state != .missed else { return .wait(.settled) }
        guard trackID != nil else { return .wait(.noTrack) }
        guard let remaining else { return .wait(.noEstimate) }

        // I3: past COMMIT_DEADLINE. Checked before the window test so a track
        // that ran past the deadline while paused is abandoned rather than
        // sitting in `.committing` forever.
        guard remaining >= configuration.commitDeadline else { return .abandon }

        // I2.
        guard remaining <= configuration.commitOpen else { return .wait(.windowNotOpen) }

        // I4. Deliberately after the deadline check: a paused track still runs
        // out of window, and pretending otherwise leaves the state machine
        // stuck.
        guard isPlaying else { return .wait(.notPlaying) }

        // Every slot used and still no success: the miss is already
        // determined, so say so now rather than idling until the deadline.
        // Waiting would change nothing except the timestamp on the log line,
        // and would leave the caller polling a state machine that has no
        // remaining move.
        guard attempts < slots.count else { return .abandon }

        // One attempt per slot.
        guard attempts <= slotIndex(remaining: remaining) else {
            return .wait(.awaitingNextSlot)
        }
        return .attempt(number: attempts + 1)
    }

    /// Which slot `remaining` falls in: 0 at `COMMIT_OPEN`, 1 at
    /// `COMMIT_RETRY_1`, 2 at `COMMIT_RETRY_2`.
    func slotIndex(remaining: Duration) -> Int {
        var index = 0
        for (position, slot) in slots.enumerated() where remaining <= slot {
            index = position
        }
        return index
    }

    // MARK: - Recording outcomes

    /// Call immediately before issuing the `enqueue`. Counts the attempt even
    /// if the call then throws, which is what keeps a failing network from
    /// retrying in a tight loop inside one slot.
    public mutating func recordAttempt(at now: Instant) {
        attempts += 1
        lastAttemptAt = now
        state = .committing
    }

    /// The `enqueue` returned success. Terminal for this track (I1).
    public mutating func recordSuccess(at now: Instant) {
        state = .committed
        lastAttemptAt = now
    }

    /// The `enqueue` failed. Stays in `.committing`; the next slot will retry
    /// if there is one left before the deadline.
    public mutating func recordFailure(at now: Instant) {
        state = .committing
        lastAttemptAt = now
    }

    /// Past the deadline with no success. Terminal for this track.
    public mutating func recordAbandon(at now: Instant) {
        state = .missed
        lastAttemptAt = lastAttemptAt ?? now
    }

    // MARK: - Poll scheduling

    /// When the controller should next evaluate this track, as a delay from
    /// `now`. Nil when there is nothing left to do before the next track.
    ///
    /// This is where `SHORT_TRACK_THRESHOLD` actually earns its place, and not
    /// in the way §6.7's one-line description suggests. Read literally —
    /// "commit immediately" at 25 s remaining — it would contradict I2, which
    /// forbids anything before 20 s. Five seconds of freshness is not worth
    /// giving up an invariant that has a test.
    ///
    /// The real hazard a short track presents is different: `HEARTBEAT_POLL` is
    /// 30 s, so a track first seen with 23 s left would not be looked at again
    /// until long after its deadline. The fix is to **wake early, not commit
    /// early** — hence the `min` below. A track with 23 s left schedules its
    /// next evaluation 3 s out, at the moment the window opens, rather than
    /// sleeping through the whole thing.
    ///
    /// Recorded as D-6 in `docs/verification.md`.
    public func nextEvaluation(remaining: Duration?, at now: Instant) -> Duration? {
        guard state != .committed, state != .missed, trackID != nil else { return nil }
        guard let remaining else { return configuration.heartbeatPoll }

        // Past the deadline, or out of slots: `.abandon` is due, so evaluate
        // at once rather than scheduling a wake-up for a decision already made.
        guard remaining >= configuration.commitDeadline else { return .zero }
        guard attempts < slots.count else { return .zero }

        // The next thing that can happen is the slot after the ones already
        // used. Before the window opens that is `COMMIT_OPEN` itself, which is
        // why this needs no separate branch.
        let target = remaining - slots[attempts]
        if target <= .zero { return .zero }
        return min(target, configuration.heartbeatPoll)
    }
}
