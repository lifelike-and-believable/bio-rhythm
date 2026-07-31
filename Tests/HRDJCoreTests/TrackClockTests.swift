import Testing
import HRDJCore

/// SPEC.md §7.1.
@Suite("Track clock — SPEC.md §7.1")
struct TrackClockTests {
    private func t(_ seconds: Double) -> Instant {
        Instant.reference + .milliseconds(Int(seconds * 1000))
    }

    private func track(
        id: String = "abc",
        durationMillis: Int = 210_000
    ) -> PlayingTrack {
        PlayingTrack(
            id: id,
            uri: TrackURI("spotify:track:\(id)"),
            title: "Title",
            artists: ["Artist"],
            durationMillis: durationMillis
        )
    }

    private func state(
        id: String = "abc",
        durationMillis: Int = 210_000,
        progressMillis: Int?,
        isPlaying: Bool = true
    ) -> PlaybackState {
        PlaybackState(
            isPlaying: isPlaying,
            progressMillis: progressMillis,
            track: track(id: id, durationMillis: durationMillis),
            device: nil,
            shuffleState: true
        )
    }

    // MARK: - Deriving the estimate

    @Test("The estimate is observedAt plus what is left of the track")
    func derivesTheEnd() {
        var clock = TrackClock()
        // 210 s track, 30 s in, observed at t=100 → ends at t=280.
        let observation = clock.observe(state(progressMillis: 30_000), at: t(100))

        #expect(observation.kind == .started(trackID: "abc"))
        #expect(observation.drift == nil)
        #expect(clock.estimatedEnd == t(280))
        #expect(clock.isEstablished)
    }

    @Test("Remaining counts down against the clock between polls")
    func remainingCountsDown() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))

        #expect(clock.remaining(at: t(100)) == .seconds(180))
        #expect(clock.remaining(at: t(160)) == .seconds(120))
        #expect(clock.remaining(at: t(260)) == .seconds(20))
    }

    @Test("Remaining goes negative past the estimate rather than clamping")
    func remainingIsSigned() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))

        // The scheduler has to be able to notice it is past COMMIT_DEADLINE.
        // A value clamped at zero looks the same one second late as five
        // minutes late, and MISSED would never fire.
        #expect(clock.remaining(at: t(285)) == .seconds(-5))
    }

    @Test("Nothing is established before the first observation")
    func unestablished() {
        let clock = TrackClock()
        #expect(clock.isEstablished == false)
        #expect(clock.remaining(at: t(0)) == nil)
        #expect(clock.trackID == nil)
    }

    // MARK: - Corrections

    @Test("A perfectly-behaved poll produces no drift at all")
    func noDriftWhenTheClockAgrees() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))

        // 30 s later the track is 30 s further in. The estimate should not move.
        let observation = clock.observe(state(progressMillis: 60_000), at: t(130))

        #expect(observation.kind == .continued)
        #expect(observation.drift == .seconds(0))
        #expect(clock.estimatedEnd == t(280))
    }

    @Test("Small corrections are drift, and are applied in full")
    func smallCorrectionIsDrift() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))

        // Progress is 1 s behind where the local estimate expected, so the
        // track now ends 1 s later.
        let observation = clock.observe(state(progressMillis: 59_000), at: t(130))

        #expect(observation.kind == .continued)
        #expect(observation.drift == .seconds(1))
        #expect(clock.estimatedEnd == t(281))
    }

    @Test("A correction at exactly the threshold is still drift")
    func thresholdIsExclusive() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))

        // §7.1 says "larger than 3 s", so 3 s itself is not a seek.
        let observation = clock.observe(state(progressMillis: 57_000), at: t(130))
        #expect(observation.kind == .continued)
        #expect(observation.drift == .seconds(3))
    }

    @Test("A forward seek is reported as a seek and applied immediately")
    func forwardSeek() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))

        // Scrubbed forward 45 s: less of the track is left, so it ends sooner.
        let observation = clock.observe(state(progressMillis: 105_000), at: t(130))

        #expect(observation.kind == .seekDetected)
        #expect(observation.drift == .seconds(-45))
        // Re-derived, not smoothed: 210 - 105 = 105 s left from t=130.
        #expect(clock.estimatedEnd == t(235))
    }

    @Test("A backward seek is reported and applied the same way")
    func backwardSeek() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 90_000), at: t(100))
        #expect(clock.estimatedEnd == t(220))

        let observation = clock.observe(state(progressMillis: 30_000), at: t(110))

        #expect(observation.kind == .seekDetected)
        #expect(observation.drift == .seconds(70))
        #expect(clock.estimatedEnd == t(290))
    }

    @Test("Re-deriving beats smoothing on the poll after a seek")
    func rederivingSettlesImmediately() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))
        clock.observe(state(progressMillis: 105_000), at: t(130))   // seek

        // The very next well-behaved poll agrees exactly. A smoothed estimate
        // would still be converging here, and would put the commit window in
        // the wrong place for several polls after every scrub.
        let observation = clock.observe(state(progressMillis: 135_000), at: t(160))
        #expect(observation.kind == .continued)
        #expect(observation.drift == .seconds(0))
        #expect(clock.estimatedEnd == t(235))
    }

    // MARK: - Track changes

    @Test("A new track ID starts over")
    func trackChange() {
        var clock = TrackClock()
        clock.observe(state(id: "abc", progressMillis: 200_000), at: t(100))

        let observation = clock.observe(
            state(id: "xyz", durationMillis: 180_000, progressMillis: 0),
            at: t(115)
        )

        #expect(observation.kind == .started(trackID: "xyz"))
        #expect(observation.isTrackChange)
        // No drift on a track change — there was no previous estimate *of this
        // track* to correct.
        #expect(observation.drift == nil)
        #expect(clock.trackID == "xyz")
        #expect(clock.estimatedEnd == t(295))
    }

    @Test("The first observation is a track change too")
    func firstObservationIsAStart() {
        var clock = TrackClock()
        let observation = clock.observe(state(progressMillis: 0), at: t(0))
        #expect(observation.isTrackChange)
    }

    // MARK: - Degenerate states

    @Test("A state with no track keeps the estimate rather than dropping it")
    func emptyStatePreservesTheEstimate() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))

        let empty = PlaybackState(
            isPlaying: false,
            progressMillis: nil,
            track: nil,
            device: nil,
            shuffleState: false
        )
        let observation = clock.observe(empty, at: t(130))

        #expect(observation.kind == .idle)
        // A 204 mid-track is a network event, not a musical one. Clearing here
        // would make the scheduler forget a commit window it is inside.
        #expect(clock.estimatedEnd == t(280))
        #expect(clock.isPlaying == false)
    }

    @Test("A track with no progress figure cannot be estimated from")
    func missingProgress() {
        var clock = TrackClock()
        let observation = clock.observe(state(progressMillis: nil), at: t(0))

        #expect(observation.kind == .idle)
        #expect(clock.isEstablished == false)
    }

    @Test("Progress past the duration does not produce a negative remainder")
    func progressPastDuration() {
        var clock = TrackClock()
        clock.observe(state(durationMillis: 210_000, progressMillis: 215_000), at: t(100))
        #expect(clock.estimatedEnd == t(100))
    }

    // MARK: - Playing state and pausing

    @Test("isPlaying is recorded from every observation, including empty ones")
    func playingIsRecorded() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 1_000, isPlaying: true), at: t(0))
        #expect(clock.isPlaying)

        // I4 forbids enqueueing while this is false, so it has to survive a
        // state that carries nothing else usable.
        clock.observe(state(progressMillis: nil, isPlaying: false), at: t(10))
        #expect(clock.isPlaying == false)
    }

    @Test("A pause pushes the estimated end out on the next poll")
    func pauseExtendsTheEstimate() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))
        #expect(clock.estimatedEnd == t(280))

        // Paused for 60 s: progress has not moved, so the track now ends a
        // minute later. Large enough to read as a seek, which is honest — the
        // boundary moved discontinuously and the caller should know.
        let observation = clock.observe(state(progressMillis: 30_000, isPlaying: false), at: t(160))
        #expect(observation.kind == .seekDetected)
        #expect(clock.estimatedEnd == t(340))
    }

    // MARK: - Drift is bounded by the poll interval

    @Test("Thirty-second polling holds the estimate steady across a whole track")
    func driftStaysBounded() {
        // §7.1's claim is that drift is bounded by the poll interval. With an
        // honest player and a monotonic clock it should be zero, and the
        // estimate should still be exact at COMMIT_OPEN three minutes later.
        var clock = TrackClock()
        var second = 0.0
        clock.observe(state(progressMillis: 0), at: t(0))

        while second <= 180 {
            let observation = clock.observe(
                state(progressMillis: Int(second * 1000)),
                at: t(second)
            )
            #expect(observation.drift == .seconds(0))
            second += 30
        }

        #expect(clock.estimatedEnd == t(210))
        #expect(clock.remaining(at: t(190)) == .seconds(20))
    }

    @Test("Reset clears everything")
    func reset() {
        var clock = TrackClock()
        clock.observe(state(progressMillis: 30_000), at: t(100))
        clock.reset()

        #expect(clock.isEstablished == false)
        #expect(clock.trackID == nil)
        #expect(clock.isPlaying == false)
        #expect(clock.remaining(at: t(200)) == nil)
    }
}
