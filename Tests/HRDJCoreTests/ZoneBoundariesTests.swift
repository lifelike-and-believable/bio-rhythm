import Testing
import HRDJCore

@Suite("Zone boundaries — SPEC.md §6.1")
struct ZoneBoundariesTests {
    @Test("Thresholds are percentages of maxHR, rounded to whole bpm")
    func thresholdsFromMaxHR() {
        let boundaries = ZoneBoundaries(maxHR: 185)
        // 62 absolute, then 0.60 → 111, 0.70 → 129.5 → 130, 0.82 → 151.7 → 152
        #expect(boundaries.thresholds == [62, 111, 130, 152])
    }

    @Test("maxHR is taken as given, never derived")
    func maxHRIsExplicit() {
        // §6.1 is emphatic: the owner sets this, it is not computed from age.
        // A configuration that quietly guessed would produce zones that look
        // plausible and are wrong, which is the worst failure available here.
        #expect(ZoneBoundaries(maxHR: 200).maxHR == 200)
        #expect(ZoneBoundaries(maxHR: 160).thresholds == [62, 96, 112, 131])
    }

    @Test(
        "Thresholds match decimal arithmetic, not binary representation error",
        arguments: [
            (185, [111, 130, 152]),
            (190, [114, 133, 156]),
            (200, [120, 140, 164]),
            // 175 × 0.70 is 122.49999999999999 as a Double. Rounded naively
            // that is 122; 70% of 175 is 122.5, which rounds to 123.
            (175, [105, 123, 144]),
            // 180 × 0.70 is 125.99999999999999, which must not become 125.
            (180, [108, 126, 148]),
        ]
    )
    func thresholdsMatchDecimalArithmetic(maxHR: Int, expected: [Int]) {
        // Meditation off, so this stays a test of the percentage arithmetic
        // and nothing else.
        let boundaries = ZoneBoundaries(maxHR: maxHR, meditationCeilingBPM: nil)
        #expect(boundaries.thresholds == expected)
    }

    @Test("Each zone starts at its threshold")
    func zoneAtBoundaries() {
        let boundaries = ZoneBoundaries(maxHR: 185)  // [62, 111, 130, 152]

        #expect(boundaries.zone(for: 61) == .meditation)
        #expect(boundaries.zone(for: 62) == .z1)
        #expect(boundaries.zone(for: 110) == .z1)
        #expect(boundaries.zone(for: 111) == .z2)
        #expect(boundaries.zone(for: 129) == .z2)
        #expect(boundaries.zone(for: 130) == .z3)
        #expect(boundaries.zone(for: 151) == .z3)
        #expect(boundaries.zone(for: 152) == .z4)
    }

    @Test("Extremes land in the end zones")
    func extremes() {
        let boundaries = ZoneBoundaries(maxHR: 185)

        #expect(boundaries.zone(for: 0) == .meditation)
        #expect(boundaries.zone(for: 40) == .meditation)
        #expect(boundaries.zone(for: 200) == .z4)
        #expect(boundaries.zone(for: 500) == .z4)
    }

    @Test("Fractional heart rates land where the integer thresholds say")
    func fractionalInput() {
        let boundaries = ZoneBoundaries(maxHR: 185)

        // The window mean is a Double, so this is the common case, not an edge.
        #expect(boundaries.zone(for: 61.9) == .meditation)
        #expect(boundaries.zone(for: 62.0) == .z1)
        #expect(boundaries.zone(for: 129.9) == .z2)
        #expect(boundaries.zone(for: 130.0) == .z3)
        #expect(boundaries.zone(for: 151.999) == .z3)
    }

    @Test("Lower bounds round-trip, and the bottom zone starts at zero")
    func lowerBounds() {
        let boundaries = ZoneBoundaries(maxHR: 185)

        #expect(boundaries.lowestZone == .meditation)
        #expect(boundaries.lowerBound(of: .meditation) == 0)
        #expect(boundaries.lowerBound(of: .z1) == 62)
        #expect(boundaries.lowerBound(of: .z2) == 111)
        #expect(boundaries.lowerBound(of: .z3) == 130)
        #expect(boundaries.lowerBound(of: .z4) == 152)

        for zone in Zone.allCases {
            #expect(boundaries.zone(for: boundaries.lowerBound(of: zone)) == zone)
        }
    }

    // MARK: - Meditation zone

    @Test("The meditation ceiling is absolute bpm, not a fraction of maxHR")
    func meditationCeilingIsAbsolute() {
        // The single property that distinguishes this from every other
        // threshold: raising maxHR must not move it. If it ever starts
        // tracking maxHR, someone has quietly reinterpreted 62 as a percentage.
        for maxHR in [160, 175, 182, 185, 200] {
            let boundaries = ZoneBoundaries(maxHR: maxHR)
            #expect(boundaries.meditationCeilingBPM == 62)
            #expect(boundaries.thresholds.first == 62)
            #expect(boundaries.zone(for: 61) == .meditation)
            #expect(boundaries.zone(for: 62) == .z1)
        }
    }

    @Test("A nil ceiling degrades to §6.1's original four zones")
    func meditationDisabled() {
        let boundaries = ZoneBoundaries(maxHR: 185, meditationCeilingBPM: nil)

        #expect(boundaries.meditationCeilingBPM == nil)
        #expect(boundaries.lowestZone == .z1)
        #expect(boundaries.thresholds == [111, 130, 152])
        #expect(boundaries.zone(for: 0) == .z1)
        #expect(boundaries.zone(for: 40) == .z1)
        #expect(boundaries.zone(for: 200) == .z4)
        #expect(boundaries.lowerBound(of: .z1) == 0)
        #expect(boundaries.lowerBound(of: .z4) == 152)

        // `.meditation` is unreachable rather than mis-mapped: nothing below
        // the Z1 floor should claim to be in a zone that has no threshold.
        for bpm in stride(from: 0, through: 240, by: 1) {
            #expect(boundaries.zone(for: bpm) != .meditation)
        }
    }

    @Test(
        "A ceiling that would break the ascending order is dropped, not honoured",
        arguments: [
            // 0.60 × 100 = 60, so a ceiling of 62 would sit above the Z2 floor
            // and make the threshold list non-monotonic.
            (100, 62),
            (103, 62),
            // Explicitly nonsensical values, from a hand-edited configuration.
            (185, 0),
            (185, -10),
            (185, 300),
        ]
    )
    func degenerateCeilingIsDropped(maxHR: Int, ceiling: Int) {
        let boundaries = ZoneBoundaries(maxHR: maxHR, meditationCeilingBPM: ceiling)

        #expect(boundaries.meditationCeilingBPM == nil)
        #expect(boundaries.lowestZone == .z1)
        #expect(boundaries.thresholds == boundaries.thresholds.sorted())
        #expect(boundaries.thresholds.count == 3)
    }

    @Test("Thresholds stay ascending across every plausible maxHR")
    func thresholdsAreMonotonic() {
        // §6.3 walks the list one step at a time and §6.5 clamps on adjacency.
        // Both are meaningless if the list is out of order, and the meditation
        // threshold is the one entry that does not scale with the others.
        for maxHR in stride(from: 120, through: 220, by: 1) {
            let boundaries = ZoneBoundaries(maxHR: maxHR)
            #expect(boundaries.thresholds == boundaries.thresholds.sorted())
            #expect(Set(boundaries.thresholds).count == boundaries.thresholds.count)
        }
    }

    @Test("A custom ceiling is honoured")
    func customCeiling() {
        let boundaries = ZoneBoundaries(maxHR: 182, meditationCeilingBPM: 55)

        #expect(boundaries.meditationCeilingBPM == 55)
        #expect(boundaries.zone(for: 54) == .meditation)
        #expect(boundaries.zone(for: 55) == .z1)
    }

    @Test("The owner's own configuration produces the thresholds they can check")
    func ownerConfiguration() {
        // maxHR 182, the measured value. Worth pinning: these are the four
        // numbers that appear on the watch, and the owner will check them.
        let boundaries = ControlConfiguration(maxHR: 182).boundaries
        #expect(boundaries.thresholds == [62, 109, 127, 149])
    }

    @Test("Configuration carries the §6.7 defaults and derives the boundaries")
    func configurationDefaults() {
        var configuration = ControlConfiguration(maxHR: 185)

        #expect(configuration.window == .seconds(45))
        #expect(configuration.staleSample == .seconds(10))
        #expect(configuration.dwell == .seconds(20))
        #expect(configuration.maxStep == 1)
        #expect(configuration.overrideHold == .seconds(180))
        #expect(configuration.commitOpen == .seconds(20))
        #expect(configuration.commitRetry1 == .seconds(14))
        #expect(configuration.commitRetry2 == .seconds(9))
        #expect(configuration.commitDeadline == .seconds(6))
        #expect(configuration.shortTrackThreshold == .seconds(25))
        #expect(configuration.heartbeatPoll == .seconds(30))
        #expect(configuration.boundaryConfirm == [.seconds(2), .seconds(6)])

        // §6.3: ≈4–5 bpm for most values, which is the whole reason 2.5% was
        // chosen over a fixed bpm figure.
        #expect(configuration.marginBPM == 4.625)
        #expect(configuration.meditationCeilingBPM == 62)
        #expect(configuration.boundaries.thresholds == [62, 111, 130, 152])

        // Tunable, not fixed — R-13 requires every one of these to be editable
        // without a rebuild.
        configuration.maxHR = 190
        #expect(configuration.boundaries.thresholds == [62, 114, 133, 156])

        configuration.meditationCeilingBPM = nil
        #expect(configuration.boundaries.thresholds == [114, 133, 156])
        #expect(configuration.boundaries.lowestZone == .z1)
    }

    @Test("The commit schedule stays ordered as the track runs out")
    func commitScheduleOrdering() {
        let configuration = ControlConfiguration(maxHR: 185)

        // All measured back from the estimated end, so a larger value is
        // earlier. §7.2's invariants I2 and I3 depend on this ordering holding.
        #expect(configuration.commitOpen > configuration.commitRetry1)
        #expect(configuration.commitRetry1 > configuration.commitRetry2)
        #expect(configuration.commitRetry2 > configuration.commitDeadline)
        #expect(configuration.shortTrackThreshold > configuration.commitOpen)
    }
}
