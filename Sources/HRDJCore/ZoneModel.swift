// Standard library only. See CLAUDE.md §2.

/// Zone selection with memory. SPEC.md §6.3–§6.6.
///
/// `ZoneBoundaries` answers "which zone is this heart rate in" with no memory
/// at all, which is the right answer to a different question — driven straight
/// off it, a screen flickers whenever HR sits on a threshold. This type answers
/// "which zone should the *music* be in", which needs four things layered on
/// top:
///
/// 1. **Hysteresis (§6.3).** Entering a zone requires clearing its floor by
///    `MARGIN`; leaving requires dropping below it by the same. Asymmetric on
///    purpose.
/// 2. **Dwell (§6.4).** A proposed zone must hold *continuously* for `DWELL`
///    before it is eligible. Kills spikes.
/// 3. **Step limit (§6.5).** At most `MAX_STEP` zones per commit. A sprint
///    from Z1 to Z4 walks up over three tracks.
/// 4. **Override (§6.6).** After manual input, auto-control is suspended for
///    `OVERRIDE_HOLD` and the zone is pinned.
///
/// ## Two states, not one
///
/// `currentZone` is what the music currently reflects, and it moves **only at a
/// commit** — `observe(hr:at:)` never changes it. That separation is what makes
/// §6.5 mean what §6.5 says it means: "a sprint from Z1 to Z4 walks up over
/// three tracks" is only true if the zone advances per track rather than per
/// sample. It also makes invariant I5 (§7.2) a property of this type rather
/// than something the scheduler has to remember to enforce.
///
/// `targetZone(at:)` is a pure read: it answers "what would a commit right now
/// select" without mutating anything, so the scheduler can ask freely and the
/// M2 observe-only loop can log the answer without advancing the model.
///
/// ## Three decisions §6 does not make
///
/// Recorded in `docs/verification.md` as **D-5**, because each is a judgement
/// call and each is visible in the logs M2 exists to produce:
///
/// - **Seeding.** §6 never says which zone a session starts in. Starting
///   everyone at Z1 would make a session that begins at tempo effort walk up
///   over three tracks before the music caught up. The first observation seeds
///   `currentZone` from the raw §6.1 mapping with no hysteresis and no dwell;
///   every observation after that follows the rules.
/// - **Gaps break dwell.** §6.4 requires the candidate to differ
///   *continuously*. A stale window is not evidence of continuity, so a nil
///   observation resets the dwell timer rather than letting it accrue through
///   the gap. Conservative: it can only delay a zone change, never cause one.
/// - **Override resets dwell.** Otherwise a change confirmed during the hold
///   would fire the instant the hold lifted, which is most of the way to not
///   having had a hold. Twenty seconds of fresh confirmation is the cost.
public struct ZoneModel: Hashable, Sendable {
    public let configuration: ControlConfiguration
    /// Cached — `ControlConfiguration.boundaries` builds a new value each time,
    /// and this is read on every sample.
    public let boundaries: ZoneBoundaries

    /// The zone the music currently reflects. Nil until the first observation
    /// seeds it. Changes only in `recordCommit(at:)` and `lockZone(_:at:)`.
    public private(set) var currentZone: Zone?

    /// The zone §6.3 has been proposing, and since when. Nil when the proposal
    /// agrees with `currentZone` — there is nothing to confirm.
    public private(set) var candidate: Zone?
    public private(set) var candidateSince: Instant?

    /// §6.6. Nil when auto-control is live.
    public private(set) var overrideUntil: Instant?

    public init(configuration: ControlConfiguration) {
        self.configuration = configuration
        self.boundaries = configuration.boundaries
    }

    // MARK: - §6.3 Hysteresis

    /// The raw §6.1 mapping, with no memory. Exposed because M1's screen shows
    /// it and because seeding uses it.
    public func rawZone(for bpm: Double) -> Zone {
        boundaries.zone(for: bpm)
    }

    /// §6.3's `rawZone(h, n)`: at most one step from `current`, and only when
    /// the heart rate has cleared the relevant threshold by `MARGIN`.
    ///
    /// The margin is applied to the boundary being *crossed*, not to the zone
    /// being left, which is what makes the two directions asymmetric: the band
    /// between `threshold - MARGIN` and `threshold + MARGIN` belongs to
    /// whichever zone you were already in.
    public func hysteresisZone(for bpm: Double, from current: Zone) -> Zone {
        let thresholds = boundaries.thresholds
        let index = current.rawValue
        let margin = configuration.marginBPM

        // Up: the floor of the zone above is `thresholds[index]`. `topZone` is
        // the threshold count, so this is also the "already at the top" guard.
        if index < thresholds.count,
           bpm > Double(thresholds[index]) + margin,
           let above = Zone(rawValue: index + 1) {
            return above
        }

        // Down: this zone's own floor is `thresholds[index - 1]`.
        if index > 0,
           bpm < Double(thresholds[index - 1]) - margin,
           let below = Zone(rawValue: index - 1) {
            return below
        }

        return current
    }

    // MARK: - §6.4 Dwell

    /// How long the current candidate has been proposed. Nil when there is no
    /// candidate — which is the common case, since agreement clears it.
    public func dwellElapsed(at now: Instant) -> Duration? {
        guard let candidateSince else { return nil }
        return now - candidateSince
    }

    /// Whether the candidate has been held long enough to be eligible (§6.4).
    public func dwellSatisfied(at now: Instant) -> Bool {
        guard let elapsed = dwellElapsed(at: now) else { return false }
        return elapsed >= configuration.dwell
    }

    // MARK: - §6.6 Override

    public func isOverridden(at now: Instant) -> Bool {
        guard let overrideUntil else { return false }
        return now < overrideUntil
    }

    /// Remaining hold, for the §11.2 countdown. Nil when auto-control is live.
    public func overrideRemaining(at now: Instant) -> Duration? {
        guard let overrideUntil, now < overrideUntil else { return nil }
        return overrideUntil - now
    }

    /// Suspends auto-control for `OVERRIDE_HOLD`. §6.6 lists the three
    /// triggers: a detected manual skip, a manual zone change, and a manual
    /// pause/resume cycle.
    public mutating func beginOverride(at now: Instant) {
        overrideUntil = now + configuration.overrideHold
        clearCandidate()
    }

    /// §6.6's "resume auto" action. Clears the hold immediately.
    public mutating func resumeAuto() {
        overrideUntil = nil
    }

    /// A manual zone change: pins the zone *and* starts the hold, so the model
    /// does not immediately argue with the choice.
    public mutating func lockZone(_ zone: Zone, at now: Instant) {
        currentZone = zone
        beginOverride(at: now)
    }

    // MARK: - Advancing the model

    /// Feeds one observation. Returns `currentZone`, which this call never
    /// changes except to seed it.
    ///
    /// `hr` is `HRWindow.observedHR(at:)` — the trailing mean, nil when stale.
    @discardableResult
    public mutating func observe(hr: Double?, at now: Instant) -> Zone? {
        // §6.2: hold the zone on missing data, and do not let a gap count
        // toward §6.4's "continuously".
        guard let hr else {
            clearCandidate()
            return currentZone
        }

        guard let current = currentZone else {
            currentZone = rawZone(for: hr)
            clearCandidate()
            return currentZone
        }

        // §6.6: nothing accumulates while the hold is in force.
        guard !isOverridden(at: now) else {
            clearCandidate()
            return current
        }

        let proposed = hysteresisZone(for: hr, from: current)
        if proposed == current {
            // §6.4: "resets to zero whenever rawZone == currentZone".
            clearCandidate()
        } else if proposed != candidate {
            // Either the first proposal or a change of direction. §6.4 says
            // reset in both cases; a fresh candidate is the same thing.
            candidate = proposed
            candidateSince = now
        }
        return current
    }

    /// The zone a commit at `now` would select. Pure — call it as often as you
    /// like.
    ///
    /// Nil only before the first observation has seeded the model, which is
    /// also the condition under which there is nothing sensible to commit.
    public func targetZone(at now: Instant) -> Zone? {
        guard let current = currentZone else { return nil }
        // §6.6: "targetZone = currentZone unconditionally".
        guard !isOverridden(at: now) else { return current }
        guard let candidate, dwellSatisfied(at: now) else { return current }
        return stepLimited(candidate, from: current)
    }

    /// Records that a commit happened, advancing `currentZone` to the target.
    ///
    /// In M2 no `enqueue` is issued, but the model is still advanced — the
    /// point of the observe-only milestone is a log of the decisions the system
    /// *would* have made, and a model that never advanced would produce a log
    /// of the same decision over and over.
    ///
    /// Returns the zone now in force.
    @discardableResult
    public mutating func recordCommit(at now: Instant) -> Zone? {
        guard let target = targetZone(at: now), target != currentZone else {
            // A commit that does not move the zone must not discard a dwell in
            // progress: commits land roughly every three minutes and `DWELL`
            // is twenty seconds, so clearing here would throw away confirmation
            // the model has already earned.
            return currentZone
        }
        currentZone = target
        clearCandidate()
        return currentZone
    }

    // MARK: - §6.5 Step limit

    /// `clamp(proposed, current - MAX_STEP, current + MAX_STEP)`.
    ///
    /// Redundant today, and kept anyway. `hysteresisZone(for:from:)` already
    /// returns at most one step from `current`, so with `MAX_STEP = 1` this
    /// clamp can never fire. It is the enforcement point for invariant I5, and
    /// I5 is one of the guarantees the product rests on — a later change to
    /// §6.3 that widened its output would otherwise break I5 silently and at a
    /// distance. The test asserts the invariant, not this line.
    func stepLimited(_ proposed: Zone, from current: Zone) -> Zone {
        let step = max(0, configuration.maxStep)
        let clamped = min(max(proposed.rawValue, current.rawValue - step), current.rawValue + step)
        return Zone(rawValue: clamped) ?? current
    }

    private mutating func clearCandidate() {
        candidate = nil
        candidateSince = nil
    }
}
