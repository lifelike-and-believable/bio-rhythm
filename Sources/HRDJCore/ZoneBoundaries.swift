// Standard library only. See CLAUDE.md §2.

/// The four zones as bpm thresholds. SPEC.md §6.1.
///
/// `boundaries = [0.60, 0.70, 0.82] × maxHR`, rounded to whole bpm. Three
/// thresholds, four zones: below the first is Z1, at or above the last is Z4.
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
    /// Lower bounds of Z2, Z3, Z4 in whole bpm, ascending.
    public let thresholds: [Int]

    public init(maxHR: Int, fractions: [Double] = [0.60, 0.70, 0.82]) {
        self.maxHR = maxHR
        self.fractions = fractions
        self.thresholds = fractions.map { Self.threshold(maxHR: maxHR, fraction: $0) }
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
        var zone = Zone.z1
        for (index, threshold) in thresholds.enumerated() {
            guard bpm >= Double(threshold) else { break }
            // Defensive: a configuration with more than three thresholds would
            // otherwise index past Z4.
            guard let next = Zone(rawValue: index + 1) else { break }
            zone = next
        }
        return zone
    }

    public func zone(for bpm: Int) -> Zone {
        zone(for: Double(bpm))
    }

    /// The lower bound of a zone in bpm. Z1's is zero — §6.1 gives it a lower
    /// bound of 0% rather than a threshold of its own.
    public func lowerBound(of zone: Zone) -> Int {
        guard zone.rawValue > 0, zone.rawValue <= thresholds.count else { return 0 }
        return thresholds[zone.rawValue - 1]
    }
}
