// Standard library only. See CLAUDE.md §2.

/// The zones as bpm thresholds. SPEC.md §6.1.
///
/// Four thresholds, five zones: below the first is Meditation, at or above the
/// last is Z4. The upper four come from `[0.60, 0.70, 0.82] × maxHR`, rounded
/// to whole bpm.
///
/// ## Why the meditation threshold is absolute
///
/// Every other boundary here is a fraction of `maxHR`, because effort above
/// aerobic scales with an individual's ceiling. The bottom of the range does
/// not work that way: a resting or meditative heart rate is set by the floor,
/// not the ceiling, and two people with the same resting HR can have maxHRs
/// twenty beats apart. Expressing 62 bpm as a fraction would tie it to the
/// wrong number — at maxHR 182 it is 34%, and anyone re-measuring their maxHR
/// upward would find their meditation threshold drifting up with it, which is
/// backwards.
///
/// So it is carried as an absolute bpm. This is a deliberate divergence from
/// §6.1's "all zones are percentages of maxHR" and is recorded as such.
///
/// ## Degenerate configurations
///
/// The threshold list has to stay ascending or `zone(for:)` becomes
/// order-dependent nonsense. If the configured meditation ceiling is not
/// strictly below the Z2 threshold — which needs a `maxHR` at or below about
/// 103, or a hand-edited value — it is dropped, `meditationCeilingBPM` reports
/// `nil`, and the range degrades to §6.1's original four zones rather than to
/// something silently wrong. `lowestZone` is the honest answer to "what is the
/// bottom of this configuration".
///
/// ## What this is not
///
/// This is the *raw* mapping only. Hysteresis (§6.3), the dwell requirement
/// (§6.4), and the one-step limit (§6.5) sit on top of it and arrive with
/// `ZoneModel` in M2. A screen driven straight off `zone(for:)` will flicker
/// when HR sits on a threshold — that flicker is precisely what §6.3 exists to
/// remove, and it is worth seeing once before it is smoothed away.
public struct ZoneBoundaries: Hashable, Sendable {
    public let maxHR: Int
    /// Lower bounds of Z2, Z3, Z4 as fractions of `maxHR`.
    public let fractions: [Double]
    /// The bpm at or above which the meditation zone has been left, or `nil`
    /// when the configured value was unusable and the zone is unreachable.
    public let meditationCeilingBPM: Int?
    /// Lower bounds of every zone above `lowestZone`, in whole bpm, ascending.
    public let thresholds: [Int]

    public init(
        maxHR: Int,
        fractions: [Double] = [0.60, 0.70, 0.82],
        meditationCeilingBPM: Int? = 62
    ) {
        self.maxHR = maxHR
        self.fractions = fractions

        let percentageThresholds = fractions.map { Self.threshold(maxHR: maxHR, fraction: $0) }
        let usableCeiling: Int? = {
            guard let ceiling = meditationCeilingBPM, ceiling > 0 else { return nil }
            guard let first = percentageThresholds.first else { return ceiling }
            return ceiling < first ? ceiling : nil
        }()

        self.meditationCeilingBPM = usableCeiling
        self.thresholds = usableCeiling.map { [$0] + percentageThresholds } ?? percentageThresholds
    }

    /// The bottom zone of this configuration: `.meditation` normally, `.z1`
    /// when the meditation threshold was dropped.
    public var lowestZone: Zone {
        meditationCeilingBPM == nil ? .z1 : .meditation
    }

    /// `fraction × maxHR`, rounded to whole bpm (§6.1).
    ///
    /// The intermediate normalisation is not decoration. None of 0.60, 0.70 or
    /// 0.82 is exactly representable, so some products land a hair below a
    /// half: 175 × 0.70 is 122.49999999999999, which rounds to 122 while
    /// anyone computing 70% of 175 by hand gets 123. Rounding to the nearest
    /// thousandth first removes the representation error without touching any
    /// value that was genuinely between two bpm.
    ///
    /// One bpm sits well inside the ±2.5% hysteresis margin, so this changes no
    /// behaviour that matters. It matters because the owner sets `maxHR` and
    /// will check the thresholds against their own arithmetic, and a table that
    /// disagrees with them by one costs more trust than it costs to fix.
    static func threshold(maxHR: Int, fraction: Double) -> Int {
        let product = Double(maxHR) * fraction
        let normalised = (product * 1000).rounded() / 1000
        return Int(normalised.rounded())
    }

    /// The zone a heart rate falls in, with no hysteresis and no memory.
    public func zone(for bpm: Double) -> Zone {
        var zone = lowestZone
        for (index, threshold) in thresholds.enumerated() {
            guard bpm >= Double(threshold) else { break }
            // Defensive: a configuration with more thresholds than there are
            // zones above `lowestZone` would otherwise index past Z4.
            guard let next = Zone(rawValue: lowestZone.rawValue + index + 1) else { break }
            zone = next
        }
        return zone
    }

    public func zone(for bpm: Int) -> Zone {
        zone(for: Double(bpm))
    }

    /// The lower bound of a zone in bpm. The bottom zone's is zero — §6.1 gives
    /// it a lower bound of 0% rather than a threshold of its own.
    public func lowerBound(of zone: Zone) -> Int {
        let index = zone.rawValue - lowestZone.rawValue - 1
        guard index >= 0, index < thresholds.count else { return 0 }
        return thresholds[index]
    }
}
