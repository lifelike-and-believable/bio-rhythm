import Testing
import HRDJCore

/// SPEC.md §6.3–§6.6, and invariant I5 from §7.2.
///
/// Every test here drives explicit `Instant`s rather than a clock, because the
/// model takes its time as a parameter — there is no hidden `now` to fake.
@Suite("Zone model — SPEC.md §6.3–§6.6")
struct ZoneModelTests {
    /// maxHR 182: thresholds 62 / 109 / 127 / 149, margin 4.55 bpm.
    private var configuration: ControlConfiguration { ControlConfiguration(maxHR: 182) }

    private func model() -> ZoneModel { ZoneModel(configuration: configuration) }

    private func t(_ seconds: Double) -> Instant {
        Instant.reference + .milliseconds(Int(seconds * 1000))
    }

    /// Feeds one heart rate every second from `from` to `to`, so dwell
    /// accumulates the way a real 1 Hz sample stream makes it.
    private func hold(
        _ model: inout ZoneModel,
        bpm: Double,
        from start: Double,
        to end: Double
    ) {
        var second = start
        while second <= end {
            model.observe(hr: bpm, at: t(second))
            second += 1
        }
    }

    // MARK: - Seeding

    @Test("The first observation seeds the zone from the raw §6.1 mapping")
    func seeding() {
        var model = self.model()
        #expect(model.currentZone == nil)
        #expect(model.targetZone(at: t(0)) == nil)

        model.observe(hr: 130, at: t(0))

        // Straight to Z3, not a walk up from Z1. A session that starts at tempo
        // effort should not spend three tracks catching up.
        #expect(model.currentZone == .z3)
    }

    @Test("Seeding ignores hysteresis, which has nothing to be relative to")
    func seedingIgnoresMargin() {
        // 110 is 1 bpm over the Z2 floor of 109 — inside the 4.55 margin, so
        // hysteresis would refuse the move. There is no zone to move *from*.
        var model = self.model()
        model.observe(hr: 110, at: t(0))
        #expect(model.currentZone == .z2)
    }

    // MARK: - §6.3 Hysteresis

    @Test("Entering a zone requires clearing its floor by MARGIN")
    func entryRequiresMargin() {
        let model = self.model()
        // Z2's floor is 109; margin is 4.55, so entry needs > 113.55.
        #expect(model.hysteresisZone(for: 109, from: .z1) == .z1)
        #expect(model.hysteresisZone(for: 113.55, from: .z1) == .z1)
        #expect(model.hysteresisZone(for: 113.6, from: .z1) == .z2)
    }

    @Test("Leaving a zone requires dropping below its floor by MARGIN")
    func exitRequiresMargin() {
        let model = self.model()
        // Still Z2 down to 104.45, then Z1.
        #expect(model.hysteresisZone(for: 109, from: .z2) == .z2)
        #expect(model.hysteresisZone(for: 104.45, from: .z2) == .z2)
        #expect(model.hysteresisZone(for: 104.4, from: .z2) == .z1)
    }

    @Test("The margin band belongs to whichever zone you were already in")
    func marginBandIsAsymmetric() {
        let model = self.model()
        // The whole point of §6.3: the same heart rate maps to two different
        // zones depending on where you came from. That is not a bug to be
        // rounded away, it is the anti-flapping mechanism.
        for bpm in [105.0, 109.0, 113.0] {
            #expect(model.hysteresisZone(for: bpm, from: .z1) == .z1)
            #expect(model.hysteresisZone(for: bpm, from: .z2) == .z2)
        }
    }

    @Test("Hysteresis never proposes more than one step")
    func hysteresisIsSingleStep() {
        let model = self.model()
        for zone in Zone.allCases {
            for bpm in stride(from: 30.0, through: 240.0, by: 0.5) {
                let proposed = model.hysteresisZone(for: bpm, from: zone)
                #expect(abs(proposed.rawValue - zone.rawValue) <= 1)
            }
        }
    }

    @Test("The top and bottom zones have nowhere further to go")
    func endZonesAreTerminal() {
        let model = self.model()
        #expect(model.hysteresisZone(for: 300, from: .z4) == .z4)
        #expect(model.hysteresisZone(for: 0, from: .meditation) == .meditation)
    }

    // MARK: - §6.4 Dwell

    @Test("A proposed zone is not eligible until it has held for DWELL")
    func dwellGatesTheChange() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))
        #expect(model.currentZone == .z1)

        hold(&model, bpm: 120, from: 1, to: 19)
        // Proposed since t=1, so at t=19 only 18 s have passed.
        #expect(model.targetZone(at: t(19)) == .z1)
        #expect(model.dwellSatisfied(at: t(19)) == false)

        #expect(model.targetZone(at: t(21)) == .z2)
        #expect(model.dwellSatisfied(at: t(21)) == true)
    }

    @Test("Dwell resets when the proposal returns to the current zone")
    func dwellResetsOnAgreement() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))

        hold(&model, bpm: 120, from: 1, to: 15)   // 14 s of Z2
        model.observe(hr: 100, at: t(16))          // back to agreement
        #expect(model.dwellElapsed(at: t(16)) == nil)

        hold(&model, bpm: 120, from: 17, to: 30)   // 13 s of Z2 again
        // 27 s of Z2 in total, but never 20 s continuously.
        #expect(model.targetZone(at: t(30)) == .z1)
    }

    @Test("Dwell resets when the proposal changes direction")
    func dwellResetsOnDirectionChange() {
        var model = self.model()
        model.observe(hr: 120, at: t(0))
        #expect(model.currentZone == .z2)

        hold(&model, bpm: 135, from: 1, to: 15)    // proposing Z3
        model.observe(hr: 100, at: t(16))          // now proposing Z1
        #expect(model.candidate == .z1)
        #expect(model.dwellElapsed(at: t(16)) == .seconds(0))

        // The 15 s already served toward Z3 must not count toward Z1.
        #expect(model.targetZone(at: t(21)) == .z2)
        #expect(model.targetZone(at: t(37)) == .z1)
    }

    @Test("A gap in the samples breaks dwell continuity")
    func dwellResetsOnMissingData() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))

        hold(&model, bpm: 120, from: 1, to: 18)
        model.observe(hr: nil, at: t(19))          // window went stale

        // §6.2: hold the zone. §6.4 wants the proposal held *continuously*, and
        // a gap is not evidence that it was.
        #expect(model.currentZone == .z1)
        #expect(model.dwellElapsed(at: t(19)) == nil)
        #expect(model.targetZone(at: t(25)) == .z1)
    }

    @Test("A ten-second spike never changes the zone")
    func spikesAreRejected() {
        // §14.1's `spiky.json` in miniature: Z4 excursions from a Z2 baseline.
        var model = self.model()
        model.observe(hr: 120, at: t(0))

        var second = 1.0
        for _ in 0..<6 {
            hold(&model, bpm: 175, from: second, to: second + 9)      // 10 s spike
            hold(&model, bpm: 120, from: second + 10, to: second + 29) // 20 s baseline
            second += 30
        }

        #expect(model.currentZone == .z2)
        #expect(model.targetZone(at: t(second)) == .z2)
    }

    @Test("Heart rate oscillating around a boundary produces no change at all")
    func boundaryOscillationIsInert() {
        // §14.1 calls `boundary_oscillation.json` the most important test in
        // the suite. Z2's floor is 109; ±3 bpm around it stays inside the 4.55
        // margin in both directions, so nothing should ever become eligible.
        var model = self.model()
        model.observe(hr: 109, at: t(0))
        #expect(model.currentZone == .z2)

        var second = 1.0
        while second <= 900 {           // 15 minutes
            let bpm = 109 + (second.truncatingRemainder(dividingBy: 2) == 0 ? 3.0 : -3.0)
            model.observe(hr: bpm, at: t(second))
            #expect(model.candidate == nil)
            #expect(model.targetZone(at: t(second)) == .z2)
            second += 1
        }
        #expect(model.currentZone == .z2)
    }

    // MARK: - §6.5 Step limit and invariant I5

    @Test("A sprint from Z1 to Z4 walks up one zone per commit")
    func sprintWalksUp() {
        // §6.5's own example. HR is pinned well into Z4 the whole time; the
        // model still refuses to arrive there in one move.
        var model = self.model()
        model.observe(hr: 100, at: t(0))
        #expect(model.currentZone == .z1)

        var second = 1.0
        var zones: [Zone] = []
        for _ in 0..<4 {
            hold(&model, bpm: 175, from: second, to: second + 25)
            second += 26
            model.recordCommit(at: t(second))
            zones.append(model.currentZone ?? .meditation)
            second += 1
        }

        #expect(zones == [.z2, .z3, .z4, .z4])
    }

    @Test("I5 — the zone delta between consecutive commits is in {-1, 0, +1}")
    func invariantI5() {
        // §7.2. Driven adversarially: heart rates chosen to swing across the
        // whole range as fast as the sampler allows.
        var model = self.model()
        var seed: UInt64 = 0x5DEECE66D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let spread = Double(seed >> 33).truncatingRemainder(dividingBy: 210)
            return 30 + spread
        }

        model.observe(hr: 100, at: t(0))
        var previousCommit = model.currentZone
        var second = 1.0

        for _ in 0..<2_000 {
            model.observe(hr: next(), at: t(second))
            second += 1

            if second.truncatingRemainder(dividingBy: 30) == 0 {
                model.recordCommit(at: t(second))
                let committed = model.currentZone
                if let previous = previousCommit, let committed {
                    #expect(abs(committed.rawValue - previous.rawValue) <= 1)
                }
                previousCommit = committed
            }
        }
    }

    @Test("Observation alone never moves the zone — only a commit does")
    func observationDoesNotCommit() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))

        hold(&model, bpm: 175, from: 1, to: 300)   // five minutes at Z4 effort

        // The music is still where the last commit left it. This is what makes
        // "walks up over three tracks" true rather than aspirational.
        #expect(model.currentZone == .z1)
        #expect(model.targetZone(at: t(300)) == .z2)
    }

    @Test("A commit that does not move the zone keeps the dwell in progress")
    func neutralCommitPreservesDwell() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))

        hold(&model, bpm: 120, from: 1, to: 10)    // 9 s toward Z2
        model.recordCommit(at: t(11))              // nothing eligible yet

        #expect(model.currentZone == .z1)
        // Commits land every ~3 minutes and DWELL is 20 s. Discarding earned
        // confirmation here would be invisible and wrong.
        #expect(model.dwellElapsed(at: t(11)) == .seconds(10))
        #expect(model.targetZone(at: t(21)) == .z2)
    }

    // MARK: - §6.6 Override

    @Test("An override pins the target zone indefinitely")
    func overridePinsTheZone() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))
        model.beginOverride()

        hold(&model, bpm: 175, from: 2, to: 170)

        #expect(model.isOverridden)
        #expect(model.targetZone(at: t(170)) == .z1)
        model.recordCommit(at: t(170))
        #expect(model.currentZone == .z1)
    }

    @Test("The hold does not expire on its own")
    func overrideDoesNotExpire() {
        // The property this replaced: §6.6 used to release the zone after
        // OVERRIDE_HOLD. On a deliberate lock that is the wrong behaviour —
        // 180 s is an arbitrary interval, and the music starts moving again at
        // a moment the owner did not choose and may not notice.
        var model = self.model()
        model.observe(hr: 100, at: t(0))
        model.beginOverride()

        hold(&model, bpm: 175, from: 2, to: 600)   // ten minutes at Z4 effort

        #expect(model.isOverridden)
        #expect(model.targetZone(at: t(600)) == .z1)
        #expect(model.targetZone(at: t(86_400)) == .z1)
    }

    @Test("Resume auto is the only way out, and dwell starts fresh after it")
    func resumeAutoIsTheOnlyExit() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))
        model.beginOverride()

        hold(&model, bpm: 175, from: 2, to: 300)
        model.resumeAuto()
        #expect(model.isOverridden == false)

        // Nothing accumulated during the hold, so the change is not eligible
        // the instant control comes back — that would be most of the way to
        // not having had a hold at all.
        #expect(model.targetZone(at: t(301)) == .z1)

        hold(&model, bpm: 175, from: 302, to: 330)
        #expect(model.targetZone(at: t(330)) == .z2)
    }

    @Test("A manual zone lock pins the chosen zone and stays put")
    func manualZoneLock() {
        var model = self.model()
        model.observe(hr: 100, at: t(0))

        model.lockZone(.z4)
        #expect(model.currentZone == .z4)
        #expect(model.isOverridden)

        hold(&model, bpm: 60, from: 2, to: 600)
        #expect(model.targetZone(at: t(600)) == .z4)
    }

    // MARK: - Traces

    @Test("A ramp up produces a monotonic non-decreasing zone sequence")
    func rampUpIsMonotonic() {
        // §14.1's `ramp_up.json`: 55 → 175 bpm over 20 minutes, starting below
        // MEDITATION_CEILING so the whole Z0 → Z4 climb is exercised.
        var model = self.model()
        var committed: [Zone] = []
        var second = 0.0

        while second <= 1200 {
            let bpm = 55 + (175 - 55) * (second / 1200)
            model.observe(hr: bpm, at: t(second))
            if second > 0, second.truncatingRemainder(dividingBy: 180) == 0 {
                model.recordCommit(at: t(second))
                if let zone = model.currentZone { committed.append(zone) }
            }
            second += 1
        }

        #expect(model.currentZone != nil)
        #expect(committed == committed.sorted())
        #expect(committed.first == .meditation || committed.first == .z1)
        #expect(committed.last == .z4)

        for (previous, current) in zip(committed, committed.dropFirst()) {
            #expect(current.rawValue - previous.rawValue <= 1)
        }
    }

    @Test("A ramp down produces a monotonic non-increasing zone sequence")
    func rampDownIsMonotonic() {
        var model = self.model()
        var committed: [Zone] = []
        var second = 0.0

        while second <= 1200 {
            let bpm = 175 - (175 - 55) * (second / 1200)
            model.observe(hr: bpm, at: t(second))
            if second > 0, second.truncatingRemainder(dividingBy: 180) == 0 {
                model.recordCommit(at: t(second))
                if let zone = model.currentZone { committed.append(zone) }
            }
            second += 1
        }

        #expect(committed == committed.sorted(by: >))
        #expect(committed.first == .z4)

        for (previous, current) in zip(committed, committed.dropFirst()) {
            #expect(previous.rawValue - current.rawValue <= 1)
        }
    }
}
