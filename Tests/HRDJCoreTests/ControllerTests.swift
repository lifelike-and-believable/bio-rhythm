import Testing
import HRDJCore

/// SPEC.md §7 wired together, and the M2 exit condition from §13: every
/// decision computed and logged, with `enqueue` withheld.
@Suite("Controller — SPEC.md §7")
struct ControllerTests {
    // MARK: - Doubles

    /// Conforms to the narrow composition only. Note what is *absent*: there is
    /// no `pause`, `next` or `seek` here, because the controller's dependency
    /// type could not call them if there were (I6).
    final class FakePlayback: PlaybackReading, PlaybackQueueing, @unchecked Sendable {
        var state: PlaybackState
        var failures = 0
        var enqueued: [TrackURI] = []
        var enqueueShouldFail = false

        init(state: PlaybackState) { self.state = state }

        struct Failure: Error {}

        func playbackState() async throws -> PlaybackState {
            if failures > 0 {
                failures -= 1
                throw Failure()
            }
            return state
        }

        func enqueue(_ uri: TrackURI) async throws {
            if enqueueShouldFail { throw Failure() }
            enqueued.append(uri)
        }
    }

    final class FakePools: PoolSelecting, @unchecked Sendable {
        var requested: [PoolID] = []
        var avoided: [[String]] = []
        var empty = false

        func selectTrack(from pool: PoolID, avoidingArtists: [String]) async throws -> PoolSelection? {
            requested.append(pool)
            avoided.append(avoidingArtists)
            guard !empty else { return nil }
            let track = TrackRef(
                id: "sel-\(pool.rawValue)-\(requested.count)",
                uri: "spotify:track:sel-\(pool.rawValue)-\(requested.count)",
                title: "Selected",
                primaryArtist: "Artist \(requested.count)",
                durationMillis: 200_000
            )
            return PoolSelection(track: track, pool: pool)
        }
    }

    final class Recorder: DecisionRecording, @unchecked Sendable {
        var decisions: [Decision] = []
        func record(_ decision: Decision) async { decisions.append(decision) }
        func events(_ event: Decision.Event) -> [Decision] { decisions.filter { $0.event == event } }
    }

    final class SteppableClock: HRDJCore.Clock, @unchecked Sendable {
        var now: Instant = .reference
        func advance(_ duration: Duration) { now = now + duration }
    }

    // MARK: - Fixtures

    private func state(
        id: String = "abc",
        durationMillis: Int = 210_000,
        progressMillis: Int,
        isPlaying: Bool = true
    ) -> PlaybackState {
        PlaybackState(
            isPlaying: isPlaying,
            progressMillis: progressMillis,
            track: PlayingTrack(
                id: id,
                uri: TrackURI("spotify:track:\(id)"),
                title: "Playing",
                artists: ["Someone"],
                durationMillis: durationMillis
            ),
            device: nil,
            shuffleState: true
        )
    }

    private struct Rig {
        let controller: Controller
        let playback: FakePlayback
        let pools: FakePools
        let recorder: Recorder
        let clock: SteppableClock
    }

    private func rig(actuationEnabled: Bool = false, progressMillis: Int = 0) -> Rig {
        let playback = FakePlayback(state: state(progressMillis: progressMillis))
        let pools = FakePools()
        let recorder = Recorder()
        let clock = SteppableClock()
        let controller = Controller(
            playback: playback,
            pools: pools,
            sink: recorder,
            clock: clock,
            configuration: ControlConfiguration(maxHR: 182),
            actuationEnabled: actuationEnabled
        )
        return Rig(
            controller: controller,
            playback: playback,
            pools: pools,
            recorder: recorder,
            clock: clock
        )
    }

    /// Feeds HR at 1 Hz and ticks once per second, keeping `progress_ms` in
    /// step with the clock so `TrackClock` sees an honest player.
    private func run(_ rig: Rig, seconds: Int, bpm: Int) async {
        for second in 0..<seconds {
            rig.playback.state = state(progressMillis: second * 1000)
            await rig.controller.ingest(HRSample(at: rig.clock.now, bpm: bpm))
            await rig.controller.tick()
            rig.clock.advance(.seconds(1))
        }
    }

    // MARK: - M2 is observe-only

    @Test("M2 computes and logs the commit but does not enqueue")
    func observeOnly() async {
        let rig = self.rig(actuationEnabled: false)
        await run(rig, seconds: 200, bpm: 120)

        let commits = rig.recorder.events(.commit)
        #expect(commits.count == 1)

        let commit = commits[0]
        // The decision is real: a pool was consulted and a track chosen.
        #expect(commit.selectedURI != nil)
        #expect(commit.selectedFromPool == .z2)
        #expect(commit.targetZone == .z2)
        #expect(commit.attempt == 1)
        // `skipped`, not `success` — a trace must not read as though the queue
        // was touched when it was not.
        #expect(commit.outcome == .skipped)

        #expect(rig.playback.enqueued.isEmpty)
    }

    @Test("With actuation enabled the same decision reaches the queue")
    func actuationEnabled() async {
        let rig = self.rig(actuationEnabled: true)
        await run(rig, seconds: 200, bpm: 120)

        let commits = rig.recorder.events(.commit)
        #expect(commits.count == 1)
        #expect(commits[0].outcome == .success)
        #expect(rig.playback.enqueued.count == 1)
        #expect(rig.playback.enqueued[0].rawValue == commits[0].selectedURI)
    }

    // MARK: - Timing

    @Test("The commit lands inside the §6.7 window, not before it")
    func commitLandsInTheWindow() async {
        let rig = self.rig()
        await run(rig, seconds: 200, bpm: 120)

        let commit = rig.recorder.events(.commit).first
        let remaining = commit?.trackRemainingMillis ?? -1
        // I2 and I3 together: 20 s down to 6 s.
        #expect(remaining <= 20_000)
        #expect(remaining >= 6_000)
    }

    @Test("Exactly one commit per track, however many times we tick")
    func oneCommitPerTrack() async {
        let rig = self.rig()
        await run(rig, seconds: 205, bpm: 120)
        #expect(rig.recorder.events(.commit).count == 1)
        #expect(rig.pools.requested.count == 1)
    }

    @Test("A new track reopens the guard and commits again")
    func secondTrackCommitsAgain() async {
        let rig = self.rig()
        await run(rig, seconds: 200, bpm: 120)
        #expect(rig.recorder.events(.commit).count == 1)

        // A different track ID, back at the start.
        for second in 0..<200 {
            rig.playback.state = state(id: "second", progressMillis: second * 1000)
            await rig.controller.ingest(HRSample(at: rig.clock.now, bpm: 120))
            await rig.controller.tick()
            rig.clock.advance(.seconds(1))
        }

        #expect(rig.recorder.events(.commit).count == 2)
    }

    // MARK: - Zone plumbing

    @Test("The pool follows the zone the heart rate puts us in")
    func poolFollowsZone() async {
        let rig = self.rig()
        await run(rig, seconds: 200, bpm: 160)   // Z4 territory at maxHR 182
        #expect(rig.pools.requested == [.z4])
    }

    @Test("A stale window logs the gap and holds the zone")
    func missingHeartRate() async {
        let rig = self.rig()
        // Two samples, then silence well past STALE_SAMPLE.
        await rig.controller.ingest(HRSample(at: rig.clock.now, bpm: 120))
        await rig.controller.tick()
        rig.clock.advance(.seconds(30))
        rig.playback.state = state(progressMillis: 30_000)
        await rig.controller.tick()

        #expect(rig.recorder.events(.hrSampleGap).count == 1)
        let zone = await rig.controller.zoneModel.currentZone
        #expect(zone == .z2)
    }

    @Test("Consecutive artists are passed to selection for §8's clustering rule")
    func artistsAreCarried() async {
        let rig = self.rig()
        await run(rig, seconds: 200, bpm: 120)
        #expect(rig.pools.avoided[0].isEmpty)

        for second in 0..<200 {
            rig.playback.state = state(id: "second", progressMillis: second * 1000)
            await rig.controller.ingest(HRSample(at: rig.clock.now, bpm: 120))
            await rig.controller.tick()
            rig.clock.advance(.seconds(1))
        }

        #expect(rig.pools.avoided.count == 2)
        #expect(rig.pools.avoided[1] == ["Artist 1"])
    }

    // MARK: - Failure paths

    @Test("An exhausted pool is logged as starvation, not as a commit")
    func poolStarvation() async {
        let rig = self.rig()
        rig.pools.empty = true
        await run(rig, seconds: 205, bpm: 120)

        // Three slots, three attempts, then the miss — not one attempt per
        // poll for the whole window.
        #expect(rig.recorder.events(.poolStarvation).count == 3)
        #expect(rig.recorder.events(.commitMiss).count == 1)
        #expect(rig.recorder.events(.commit).isEmpty)
    }

    @Test("Three consecutive read failures enter DEGRADED, and a success leaves it")
    func degraded() async {
        let rig = self.rig()
        rig.playback.failures = 3

        for _ in 0..<3 {
            await rig.controller.tick()
            rig.clock.advance(.seconds(30))
        }
        var degraded = await rig.controller.isDegraded
        #expect(degraded)
        #expect(rig.recorder.events(.degradedEnter).count == 1)

        await rig.controller.tick()
        degraded = await rig.controller.isDegraded
        #expect(degraded == false)
        #expect(rig.recorder.events(.degradedExit).count == 1)
    }

    @Test("A failing enqueue is recorded as a failure and retried in the next slot")
    func enqueueFailureRetries() async {
        let rig = self.rig(actuationEnabled: true)
        rig.playback.enqueueShouldFail = true
        await run(rig, seconds: 208, bpm: 120)

        let commits = rig.recorder.events(.commit)
        #expect(commits.count == 3)
        #expect(commits.allSatisfy { $0.outcome == .failure })
        #expect(rig.recorder.events(.commitMiss).count == 1)
        #expect(rig.playback.enqueued.isEmpty)
    }

    // MARK: - §6.6 override

    @Test("An override pins the zone and is logged both ways")
    func override() async {
        let rig = self.rig()
        await rig.controller.ingest(HRSample(at: rig.clock.now, bpm: 120))
        await rig.controller.tick()

        await rig.controller.registerManualInput()
        #expect(rig.recorder.events(.overrideSet).count == 1)

        await rig.controller.resumeAuto()
        #expect(rig.recorder.events(.overrideCleared).count == 1)
        let model = await rig.controller.zoneModel
        #expect(model.isOverridden(at: rig.clock.now) == false)
    }

    @Test("A manual zone lock takes effect immediately")
    func manualZoneLock() async {
        let rig = self.rig()
        await rig.controller.ingest(HRSample(at: rig.clock.now, bpm: 120))
        await rig.controller.tick()

        await rig.controller.registerManualInput(zone: .z4)
        let zone = await rig.controller.zoneModel.currentZone
        #expect(zone == .z4)
    }

    // MARK: - Telemetry shape

    @Test("Every record carries the context needed to read it on its own")
    func recordsAreSelfContained() async {
        let rig = self.rig()
        await run(rig, seconds: 200, bpm: 120)

        let commit = rig.recorder.events(.commit).first
        #expect(commit?.hrWindowMean != nil)
        #expect(commit?.windowSampleCount != nil)
        #expect(commit?.currentZone != nil)
        #expect(commit?.trackID == "abc")
        #expect(commit?.trackRemainingMillis != nil)
    }

    @Test("Session start and end bracket the log")
    func sessionBrackets() async {
        let rig = self.rig()
        await rig.controller.start()
        await run(rig, seconds: 5, bpm: 120)
        await rig.controller.stop()

        #expect(rig.recorder.decisions.first?.event == .sessionStart)
        #expect(rig.recorder.decisions.last?.event == .sessionEnd)
    }
}
