import Testing
import HRDJCore

@Suite("HR window — SPEC.md §6.2")
struct HRWindowTests {
    /// Fills a window with one sample per second ending at `now`, oldest first.
    private func filled(
        bpm: [Int],
        endingAt now: Instant,
        spacing: Duration = .seconds(1)
    ) -> HRWindow {
        var window = HRWindow()
        for (offset, value) in bpm.reversed().enumerated() {
            let at = now - (spacing * offset)
            window.insert(HRSample(at: at, bpm: value))
        }
        return window
    }

    @Test("The observation is the arithmetic mean of the window")
    func meanOfWindow() {
        let now = Instant.reference + .seconds(100)
        let window = filled(bpm: [140, 150, 160], endingAt: now)

        #expect(window.observedHR(at: now) == 150)
        #expect(window.sampleCount(at: now) == 3)
    }

    @Test("Samples older than the window fall out")
    func evictsOldSamples() {
        var window = HRWindow(length: .seconds(45))
        let start = Instant.reference

        window.insert(HRSample(at: start, bpm: 100))
        window.insert(HRSample(at: start + .seconds(50), bpm: 200))

        // The 100 is 50 s behind the newest sample and no longer counts.
        #expect(window.observedHR(at: start + .seconds(50)) == 200)
        #expect(window.sampleCount(at: start + .seconds(50)) == 1)
    }

    @Test("A sample exactly at the window edge is still inside it")
    func windowEdgeIsInclusive() {
        var window = HRWindow(length: .seconds(45))
        let now = Instant.reference + .seconds(45)

        window.insert(HRSample(at: now - .seconds(45), bpm: 100))
        window.insert(HRSample(at: now, bpm: 200))

        #expect(window.sampleCount(at: now) == 2)
        #expect(window.observedHR(at: now) == 150)
    }

    @Test(
        "Implausible samples are rejected on the way in",
        arguments: [29, 241, 0, -5, 1000]
    )
    func rejectsImplausible(bpm: Int) {
        var window = HRWindow()
        let now = Instant.reference

        #expect(window.insert(HRSample(at: now, bpm: bpm)) == false)
        #expect(window.sampleCount(at: now) == 0)
        // Rejected samples must not count as freshness either, or a stuck
        // sensor emitting zeroes would look like a live one.
        #expect(window.isStale(at: now))
    }

    @Test("A plausible sample is accepted")
    func acceptsPlausible() {
        var window = HRWindow()
        let now = Instant.reference

        #expect(window.insert(HRSample(at: now, bpm: 30)))
        #expect(window.insert(HRSample(at: now, bpm: 240)))
        #expect(window.sampleCount(at: now) == 2)
    }

    @Test("A stale window reports nothing rather than a stale average")
    func staleWindowReportsNil() {
        var window = HRWindow(staleAfter: .seconds(10))
        let start = Instant.reference
        window.insert(HRSample(at: start, bpm: 150))

        // Inside the freshness bound: still a valid observation.
        #expect(window.observedHR(at: start + .seconds(10)) == 150)

        // Past it: §6.2 says report nil so the caller holds the zone. Returning
        // the last known mean here is exactly the bug this rule prevents — the
        // zone would keep moving on data that stopped arriving.
        #expect(window.observedHR(at: start + .seconds(11)) == nil)
        #expect(window.isStale(at: start + .seconds(11)))
    }

    @Test("An empty window is stale and has no observation")
    func emptyWindow() {
        let window = HRWindow()
        let now = Instant.reference

        #expect(window.isStale(at: now))
        #expect(window.observedHR(at: now) == nil)
        #expect(window.instantaneousBPM == nil)
        #expect(window.timeSinceNewest(at: now) == nil)
    }

    @Test("A 90-second dropout goes stale and recovers on the next sample")
    func dropoutAndRecovery() {
        // §14.1's dropout case, and §11.4's expected behaviour: hold the zone,
        // log the gap, keep attempting commits.
        var window = HRWindow()
        let start = Instant.reference
        for second in 0..<45 {
            window.insert(HRSample(at: start + .seconds(second), bpm: 150))
        }
        let lastSample = start + .seconds(44)

        #expect(window.observedHR(at: lastSample) == 150)

        let duringGap = lastSample + .seconds(90)
        #expect(window.observedHR(at: duringGap) == nil)
        #expect(window.timeSinceNewest(at: duringGap) == .seconds(90))

        // The sensor comes back. One fresh sample is enough to observe again,
        // and everything from before the gap has aged out of the window.
        window.insert(HRSample(at: duringGap, bpm: 120))
        #expect(window.observedHR(at: duringGap) == 120)
        #expect(window.sampleCount(at: duringGap) == 1)
    }

    @Test("Out-of-order delivery does not disturb the mean or the freshness check")
    func handlesOutOfOrderSamples() {
        var window = HRWindow()
        let start = Instant.reference

        // Delivered newest-first, which HealthKit does not promise not to do.
        window.insert(HRSample(at: start + .seconds(3), bpm: 180))
        window.insert(HRSample(at: start + .seconds(1), bpm: 120))
        window.insert(HRSample(at: start + .seconds(2), bpm: 150))

        let now = start + .seconds(3)
        #expect(window.observedHR(at: now) == 150)
        #expect(window.newest?.bpm == 180)
        #expect(window.isStale(at: now) == false)
    }

    @Test("A late sample older than the window is discarded, not counted")
    func lateSampleOutsideWindowIsDropped() {
        var window = HRWindow(length: .seconds(45))
        let start = Instant.reference

        window.insert(HRSample(at: start + .seconds(100), bpm: 160))
        window.insert(HRSample(at: start, bpm: 60))

        #expect(window.sampleCount(at: start + .seconds(100)) == 1)
        #expect(window.observedHR(at: start + .seconds(100)) == 160)
    }

    @Test("Instantaneous and mean are different numbers, and both are available")
    func instantaneousIsNotTheMean() {
        let now = Instant.reference + .seconds(10)
        let window = filled(bpm: [100, 100, 160], endingAt: now)

        // §11.3 logs hrInstant and hrWindowMean side by side precisely so the
        // lag introduced by the mean can be seen in the traces.
        #expect(window.instantaneousBPM == 160)
        #expect(window.observedHR(at: now) == 120)
    }

    @Test("Clearing drops everything")
    func clearing() {
        var window = HRWindow()
        let now = Instant.reference
        window.insert(HRSample(at: now, bpm: 150))

        window.removeAll()

        #expect(window.sampleCount(at: now) == 0)
        #expect(window.observedHR(at: now) == nil)
    }
}
