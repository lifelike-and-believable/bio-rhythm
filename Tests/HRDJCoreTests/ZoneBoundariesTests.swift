import Testing
import HRDJCore

@Suite("Zone boundaries — SPEC.md §6.1")
struct ZoneBoundariesTests {
    @Test("Thresholds are percentages of maxHR, rounded to whole bpm")
    func thresholdsFromMaxHR() {
        let boundaries = ZoneBoundaries(maxHR: 185)
        // 0.34 → 62.9 → 63, 0.60 → 111, 0.70 → 129.5 → 130, 0.82 → 151.7 → 152
        #expect(boundaries.thresholds == [63, 111, 130, 152])
    }

    @Test("maxHR is taken as given, never derived")
    func maxHRIsExplicit() {
        // §6.1 is emphatic: the owner sets this, it is not computed from age.
        // A configuration that quietly guessed would produce zones that look
        // plausible and are wrong, which is the worst failure available here.
        #expect(ZoneBoundaries(maxHR: 200).maxHR == 200)
        #expect(ZoneBoundaries(maxHR: 160).thresholds == [54, 96, 112, 131])
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
        // Just the three §6.1 percentages, so this stays a test of the
        // rounding and nothing else.
        let boundaries = ZoneBoundaries(maxHR: maxHR, fractions: [0.60, 0.70, 0.82])
        #expect(boundaries.thresholds == expected)
    }

    @Test("Each zone starts at its threshold")
    func zoneAtBoundaries() {
        let boundaries = ZoneBoundaries(maxHR: 185)  // [63, 111, 130, 152]

        #expect(boundaries.zone(for: 62) == .meditation)
        #expect(boundaries.zone(for: 63) == .z1)
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
        #expect(boundaries.zone(for: 62.9) == .meditation)
        #expect(boundaries.zone(for: 63.0) == .z1)
        #expect(boundaries.zone(for: 129.9) == .z2)
        #expect(boundaries.zone(for: 130.0) == .z3)
        #expect(boundaries.zone(for: 151.999) == .z3)
    }

    @Test("Lower bounds round-trip, and the bottom zone starts at zero")
    func lowerBounds() {
        let boundaries = ZoneBoundaries(maxHR: 185)

        #expect(boundaries.lowerBound(of: .meditation) == 0)
        #expect(boundaries.lowerBound(of: .z1) == 63)
        #expect(boundaries.lowerBound(of: .z2) == 111)
        #expect(boundaries.lowerBound(of: .z3) == 130)
        #expect(boundaries.lowerBound(of: .z4) == 152)

        for zone in Zone.allCases {
            #expect(boundaries.zone(for: boundaries.lowerBound(of: zone)) == zone)
        }
    }

    // MARK: - Meditation zone

    @Test("The meditation ceiling scales with maxHR like every other threshold")
    func meditationCeilingIsAFraction() {
        // 0.34 was chosen to land on 62 at the owner's 182. The property that
        // matters is that it is a fraction: it moves with maxHR rather than
        // sitting at a fixed bpm. If this ever stops tracking, someone has
        // reintroduced an absolute threshold.
        #expect(ZoneBoundaries(maxHR: 182).thresholds.first == 62)
        #expect(ZoneBoundaries(maxHR: 176).thresholds.first == 60)
        #expect(ZoneBoundaries(maxHR: 200).thresholds.first == 68)
        #expect(ZoneBoundaries(maxHR: 160).thresholds.first == 54)
    }

    @Test("Thresholds stay ascending and distinct across every plausible maxHR")
    func thresholdsAreMonotonic() {
        // §6.3 walks the list one step at a time and §6.5 clamps on adjacency.
        // Both are meaningless if the list is out of order. Expressing the
        // meditation ceiling as a fraction rather than an absolute bpm is what
        // makes this hold for free — an absolute 62 would cross the Z2
        // threshold below maxHR 104.
        for maxHR in stride(from: 100, through: 220, by: 1) {
            let thresholds = ZoneBoundaries(maxHR: maxHR).thresholds
            #expect(thresholds == thresholds.sorted())
            #expect(Set(thresholds).count == thresholds.count)
        }
    }

    @Test("A misordered fractions array is sorted, not honoured")
    func misorderedFractionsAreNormalised() {
        // `zone(for:)` stops at the first threshold the heart rate does not
        // clear, so an out-of-order array would not fail — it would quietly
        // return the wrong zone. R-13 hands this array to a settings screen in
        // M4, so "the caller will pass it ascending" stops being true.
        let scrambled = ZoneBoundaries(maxHR: 182, fractions: [0.82, 0.34, 0.70, 0.60])
        let ordered = ZoneBoundaries(maxHR: 182)

        #expect(scrambled.fractions == ordered.fractions)
        #expect(scrambled.thresholds == ordered.thresholds)
        #expect(scrambled == ordered)

        for bpm in stride(from: 0, through: 240, by: 1) {
            #expect(scrambled.zone(for: bpm) == ordered.zone(for: bpm))
        }
    }

    @Test("Sorting is a no-op on an already-ordered configuration")
    func orderedFractionsAreUntouched() {
        let fractions = [0.30, 0.55, 0.72, 0.88]
        #expect(ZoneBoundaries(maxHR: 182, fractions: fractions).fractions == fractions)
    }

    @Test("The owner's own configuration produces the thresholds they can check")
    func ownerConfiguration() {
        // maxHR 182, the measured value. Worth pinning: these are the four
        // numbers that appear on the watch, and the owner will check them.
        // Default activity — Z1 — is the 62-to-109 band.
        let boundaries = ControlConfiguration(maxHR: 182).boundaries
        #expect(boundaries.thresholds == [62, 109, 127, 149])
        #expect(boundaries.zone(for: 61) == .meditation)
        #expect(boundaries.zone(for: 62) == .z1)
        #expect(boundaries.zone(for: 108) == .z1)
        #expect(boundaries.zone(for: 109) == .z2)
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
        #expect(configuration.zoneFractions == [0.34, 0.60, 0.70, 0.82])
        #expect(configuration.boundaries.thresholds == [63, 111, 130, 152])

        // Tunable, not fixed — R-13 requires every one of these to be editable
        // without a rebuild.
        configuration.maxHR = 190
        #expect(configuration.boundaries.thresholds == [65, 114, 133, 156])

        configuration.zoneFractions = [0.33, 0.60, 0.70, 0.82]
        #expect(configuration.boundaries.thresholds == [63, 114, 133, 156])
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
