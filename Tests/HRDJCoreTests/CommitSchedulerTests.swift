import Testing
import HRDJCore

/// SPEC.md §7.2, and invariants I1–I4 from the same section.
///
/// CLAUDE.md: "Invariants I1–I6 (§7.2) each have a test. If you change the
/// commit scheduler, the tests come first." I1–I4 are the four that live here;
/// I5 is in `ZoneModelTests` and I6 is a compile-time property asserted in
/// `ProtocolSeparationTests`.
@Suite("Commit scheduler — SPEC.md §7.2")
struct CommitSchedulerTests {
    private var configuration: ControlConfiguration { ControlConfiguration(maxHR: 182) }
    private func scheduler() -> CommitScheduler { CommitScheduler(configuration: configuration) }

    private func t(_ seconds: Double) -> Instant {
        Instant.reference + .milliseconds(Int(seconds * 1000))
    }

    /// A scheduler with a track loaded and the window not yet open.
    private func started(remaining: Duration = .seconds(180)) -> CommitScheduler {
        var scheduler = self.scheduler()
        scheduler.trackChanged(to: "abc", remaining: remaining, at: t(0))
        return scheduler
    }

    private func isAttempt(_ decision: CommitScheduler.Decision) -> Bool {
        if case .attempt = decision { return true }
        return false
    }

    // MARK: - I1: at most one successful enqueue per track

    @Test("I1 — a committed track admits no further attempts")
    func invariantI1() {
        var scheduler = started()
        scheduler.recordAttempt(at: t(160))
        scheduler.recordSuccess(at: t(160))

        #expect(scheduler.state == .committed)

        // Every remaining moment of the window, including the slots that would
        // otherwise be retries.
        for remaining in [20.0, 14.0, 9.0, 6.0] {
            let decision = scheduler.decision(
                remaining: .seconds(remaining),
                isPlaying: true,
                at: t(200)
            )
            #expect(decision == .wait(.settled))
        }
        #expect(scheduler.nextEvaluation(remaining: .seconds(10), at: t(200)) == nil)
    }

    @Test("I1 — only a track change reopens the guard")
    func trackChangeReopens() {
        var scheduler = started()
        scheduler.recordAttempt(at: t(160))
        scheduler.recordSuccess(at: t(160))
        #expect(scheduler.state == .committed)

        scheduler.trackChanged(to: "xyz", remaining: .seconds(200), at: t(180))

        #expect(scheduler.state == .observing)
        #expect(scheduler.attempts == 0)
        #expect(scheduler.trackID == "xyz")
        #expect(isAttempt(scheduler.decision(remaining: .seconds(18), isPlaying: true, at: t(360))))
    }

    @Test("I1 — a missed track also admits nothing further")
    func missedIsTerminal() {
        var scheduler = started()
        scheduler.recordAbandon(at: t(100))

        #expect(scheduler.state == .missed)
        #expect(scheduler.decision(remaining: .seconds(15), isPlaying: true, at: t(101)) == .wait(.settled))
    }

    // MARK: - I2: nothing before COMMIT_OPEN

    @Test("I2 — no attempt before estimatedEnd − COMMIT_OPEN")
    func invariantI2() {
        let scheduler = started()

        // Every tenth of a second from three minutes out down to the window.
        var remaining = 180.0
        while remaining > 20.0 {
            let decision = scheduler.decision(
                remaining: .seconds(remaining),
                isPlaying: true,
                at: t(0)
            )
            #expect(decision == .wait(.windowNotOpen))
            remaining -= 0.1
        }
    }

    @Test("I2 — the window opens at exactly COMMIT_OPEN")
    func windowOpensAtTwenty() {
        let scheduler = started()

        #expect(scheduler.decision(remaining: .seconds(20.001), isPlaying: true, at: t(0)) == .wait(.windowNotOpen))
        #expect(scheduler.decision(remaining: .seconds(20), isPlaying: true, at: t(0)) == .attempt(number: 1))
    }

    @Test("I2 — a short track waits for the window rather than committing early")
    func shortTrackDoesNotCommitEarly() {
        // §6.7 reads "commit immediately" below SHORT_TRACK_THRESHOLD (25 s).
        // Taken literally that contradicts I2. The scheduler wakes early
        // instead — see D-6.
        var scheduler = self.scheduler()
        scheduler.trackChanged(to: "abc", remaining: .seconds(23), at: t(0))

        #expect(scheduler.startedShort)
        #expect(scheduler.decision(remaining: .seconds(23), isPlaying: true, at: t(0)) == .wait(.windowNotOpen))

        // But it does not sleep through the window: the next evaluation is
        // three seconds out, not a full HEARTBEAT_POLL.
        #expect(scheduler.nextEvaluation(remaining: .seconds(23), at: t(0)) == .seconds(3))
    }

    // MARK: - I3: nothing after COMMIT_DEADLINE

    @Test("I3 — no attempt after estimatedEnd − COMMIT_DEADLINE")
    func invariantI3() {
        let scheduler = started()

        var remaining = 5.9
        while remaining > -60 {
            let decision = scheduler.decision(
                remaining: .seconds(remaining),
                isPlaying: true,
                at: t(0)
            )
            #expect(decision == .abandon)
            remaining -= 0.1
        }
    }

    @Test("I3 — the deadline itself is still inside the window")
    func deadlineIsInclusive() {
        // §6.7: "COMMIT_DEADLINE | T−6 s | After this, abandon". At T−6 there
        // is still a commit to be had.
        let scheduler = started()
        #expect(scheduler.decision(remaining: .seconds(6), isPlaying: true, at: t(0)) == .attempt(number: 1))
        #expect(scheduler.decision(remaining: .seconds(5.999), isPlaying: true, at: t(0)) == .abandon)
    }

    // MARK: - I4: nothing while paused

    @Test("I4 — no attempt while is_playing is false")
    func invariantI4() {
        let scheduler = started()

        for remaining in [20.0, 17.0, 14.0, 9.0, 6.0] {
            let decision = scheduler.decision(
                remaining: .seconds(remaining),
                isPlaying: false,
                at: t(0)
            )
            #expect(decision == .wait(.notPlaying))
        }
    }

    @Test("I4 — a track paused through its whole window is abandoned, not stuck")
    func pausedThroughTheWindow() {
        var scheduler = started()

        #expect(scheduler.decision(remaining: .seconds(15), isPlaying: false, at: t(0)) == .wait(.notPlaying))
        // The deadline check runs before the playing check on purpose: a paused
        // track still runs out of window, and treating "not playing" as the
        // first answer would leave the machine sitting in .committing forever.
        #expect(scheduler.decision(remaining: .seconds(2), isPlaying: false, at: t(0)) == .abandon)

        scheduler.recordAbandon(at: t(0))
        #expect(scheduler.state == .missed)
    }

    // MARK: - The retry schedule

    @Test("One attempt per slot, at COMMIT_OPEN, RETRY_1 and RETRY_2")
    func retrySlots() {
        var scheduler = started()

        #expect(scheduler.decision(remaining: .seconds(20), isPlaying: true, at: t(0)) == .attempt(number: 1))
        scheduler.recordAttempt(at: t(0))
        scheduler.recordFailure(at: t(0))
        #expect(scheduler.state == .committing)

        // Still slot 0 — no second attempt here, however often we ask.
        #expect(scheduler.decision(remaining: .seconds(18), isPlaying: true, at: t(2)) == .wait(.awaitingNextSlot))
        #expect(scheduler.decision(remaining: .seconds(15), isPlaying: true, at: t(5)) == .wait(.awaitingNextSlot))

        #expect(scheduler.decision(remaining: .seconds(14), isPlaying: true, at: t(6)) == .attempt(number: 2))
        scheduler.recordAttempt(at: t(6))
        scheduler.recordFailure(at: t(6))

        #expect(scheduler.decision(remaining: .seconds(10), isPlaying: true, at: t(10)) == .wait(.awaitingNextSlot))
        #expect(scheduler.decision(remaining: .seconds(9), isPlaying: true, at: t(11)) == .attempt(number: 3))
    }

    @Test("A burst of polls inside one slot yields exactly one attempt")
    func burstOfPolls() {
        var scheduler = started()
        var attemptsIssued = 0
        var second = 0.0

        // Poll every 100 ms across the whole window. Three slots exist, so
        // three attempts should come out — not thirty.
        var remaining = 20.0
        while remaining >= 6.0 {
            let decision = scheduler.decision(
                remaining: .seconds(remaining),
                isPlaying: true,
                at: t(second)
            )
            if isAttempt(decision) {
                attemptsIssued += 1
                scheduler.recordAttempt(at: t(second))
                scheduler.recordFailure(at: t(second))
            }
            remaining -= 0.1
            second += 0.1
        }

        #expect(attemptsIssued == 3)
        #expect(scheduler.attempts == 3)
    }

    @Test("Once every slot is spent the miss is declared, not idled toward")
    func exhaustedSlotsAbandonImmediately() {
        var scheduler = started()
        for at in [0.0, 6.0, 11.0] {
            scheduler.recordAttempt(at: t(at))
            scheduler.recordFailure(at: t(at))
        }

        // Still two seconds of window left by the clock, but nothing can
        // happen in them. Waiting would change only the timestamp on the log
        // line, and would leave the caller polling a machine with no move.
        #expect(scheduler.decision(remaining: .seconds(8), isPlaying: true, at: t(13)) == .abandon)
    }

    @Test("A success on the third attempt still commits")
    func successOnLastRetry() {
        var scheduler = started()
        scheduler.recordAttempt(at: t(0))
        scheduler.recordFailure(at: t(0))
        scheduler.recordAttempt(at: t(6))
        scheduler.recordFailure(at: t(6))

        #expect(scheduler.decision(remaining: .seconds(9), isPlaying: true, at: t(11)) == .attempt(number: 3))
        scheduler.recordAttempt(at: t(11))
        scheduler.recordSuccess(at: t(11))

        #expect(scheduler.state == .committed)
        #expect(scheduler.attempts == 3)
    }

    // MARK: - Poll scheduling

    @Test("Far from the boundary the wake-up is the heartbeat poll")
    func heartbeatWhileObserving() {
        let scheduler = started()
        #expect(scheduler.nextEvaluation(remaining: .seconds(180), at: t(0)) == .seconds(30))
    }

    @Test("Approaching the window, the wake-up lands exactly on COMMIT_OPEN")
    func wakesAtCommitOpen() {
        let scheduler = started()
        // §7.1: "then at COMMIT_OPEN (needed anyway)". 45 s out is inside one
        // heartbeat of the window, so the heartbeat must not overshoot it.
        #expect(scheduler.nextEvaluation(remaining: .seconds(45), at: t(0)) == .seconds(25))
        #expect(scheduler.nextEvaluation(remaining: .seconds(51), at: t(0)) == .seconds(30))
    }

    @Test("Inside the window the wake-up is the next unused slot")
    func wakesAtNextSlot() {
        var scheduler = started()
        scheduler.recordAttempt(at: t(0))
        scheduler.recordFailure(at: t(0))

        // One attempt spent, so the next thing that can happen is RETRY_1.
        #expect(scheduler.nextEvaluation(remaining: .seconds(18), at: t(0)) == .seconds(4))

        scheduler.recordAttempt(at: t(4))
        scheduler.recordFailure(at: t(4))
        #expect(scheduler.nextEvaluation(remaining: .seconds(14), at: t(4)) == .seconds(5))
    }

    @Test("An overdue decision is evaluated at once rather than scheduled")
    func overdueEvaluatesNow() {
        var scheduler = started()
        // Past the deadline.
        #expect(scheduler.nextEvaluation(remaining: .seconds(3), at: t(0)) == .zero)

        // Or out of slots.
        for at in [0.0, 6.0, 11.0] {
            scheduler.recordAttempt(at: t(at))
            scheduler.recordFailure(at: t(at))
        }
        #expect(scheduler.nextEvaluation(remaining: .seconds(8), at: t(13)) == .zero)
    }

    @Test("Without an estimate the scheduler falls back to the heartbeat")
    func noEstimate() {
        let scheduler = started()
        #expect(scheduler.decision(remaining: nil, isPlaying: true, at: t(0)) == .wait(.noEstimate))
        #expect(scheduler.nextEvaluation(remaining: nil, at: t(0)) == .seconds(30))
    }

    @Test("Before any track there is nothing to decide")
    func idle() {
        let scheduler = self.scheduler()
        #expect(scheduler.state == .idle)
        #expect(scheduler.decision(remaining: .seconds(10), isPlaying: true, at: t(0)) == .wait(.noTrack))
        #expect(scheduler.nextEvaluation(remaining: .seconds(10), at: t(0)) == nil)
    }

    // MARK: - Whole tracks

    @Test("A well-behaved track commits once, at COMMIT_OPEN")
    func happyPath() {
        var scheduler = self.scheduler()
        scheduler.trackChanged(to: "abc", remaining: .seconds(210), at: t(0))

        var attempts = 0
        var second = 0.0
        while second <= 210 {
            let remaining = Duration.seconds(210 - second)
            let decision = scheduler.decision(remaining: remaining, isPlaying: true, at: t(second))
            switch decision {
            case .attempt:
                attempts += 1
                scheduler.recordAttempt(at: t(second))
                scheduler.recordSuccess(at: t(second))
            case .abandon:
                scheduler.recordAbandon(at: t(second))
            case .wait:
                break
            }
            second += 1
        }

        #expect(attempts == 1)
        #expect(scheduler.state == .committed)
    }

    @Test("A track whose every attempt fails ends MISSED, never COMMITTED")
    func allAttemptsFail() {
        var scheduler = self.scheduler()
        scheduler.trackChanged(to: "abc", remaining: .seconds(210), at: t(0))

        var attempts = 0
        var second = 0.0
        while second <= 210 {
            let remaining = Duration.seconds(210 - second)
            switch scheduler.decision(remaining: remaining, isPlaying: true, at: t(second)) {
            case .attempt:
                attempts += 1
                scheduler.recordAttempt(at: t(second))
                scheduler.recordFailure(at: t(second))
            case .abandon:
                scheduler.recordAbandon(at: t(second))
            case .wait:
                break
            }
            second += 1
        }

        #expect(attempts == 3)
        #expect(scheduler.state == .missed)
    }

    @Test("I1–I4 hold across a randomised session with injected failures")
    func invariantsUnderAdversarialConditions() {
        // §14.2 asks for these checked adversarially rather than by example:
        // randomised poll timing, randomised pauses, randomised failures.
        var seed: UInt64 = 0xC0FFEE
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }

        for session in 0..<40 {
            var scheduler = self.scheduler()
            let duration = Double(120 + next(180))
            scheduler.trackChanged(to: "track-\(session)", remaining: .seconds(duration), at: t(0))

            var successes = 0
            var attemptRemainings: [Double] = []
            var second = 0.0

            while second <= duration + 30 {
                let remainingValue = duration - second
                let isPlaying = next(10) > 1        // paused roughly 20% of polls
                let decision = scheduler.decision(
                    remaining: .seconds(remainingValue),
                    isPlaying: isPlaying,
                    at: t(second)
                )
                switch decision {
                case .attempt:
                    // I2 and I3, asserted at the moment of the attempt.
                    #expect(remainingValue <= 20.0)
                    #expect(remainingValue >= 6.0)
                    // I4.
                    #expect(isPlaying)
                    attemptRemainings.append(remainingValue)
                    scheduler.recordAttempt(at: t(second))
                    if next(3) == 0 {
                        scheduler.recordSuccess(at: t(second))
                        successes += 1
                    } else {
                        scheduler.recordFailure(at: t(second))
                    }
                case .abandon:
                    scheduler.recordAbandon(at: t(second))
                case .wait:
                    break
                }
                second += Double(1 + next(3))
            }

            // I1: never more than one success per track.
            #expect(successes <= 1)
            #expect(attemptRemainings.count <= 3)
            // Attempts walk toward the boundary, never away from it.
            #expect(attemptRemainings == attemptRemainings.sorted(by: >))
        }
    }
}
