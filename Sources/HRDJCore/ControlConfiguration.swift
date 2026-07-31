// Standard library only. See CLAUDE.md §2.

/// Every tunable in SPEC.md §6.7, in one place.
///
/// R-13 requires these to be editable without a rebuild, so they are values
/// carried in a struct rather than literals at call sites. The defaults here
/// are the spec's defaults.
///
/// **Do not change a default without log evidence.** §6.7's numbers are to be
/// tuned from real session telemetry during M2, against the traces the
/// observe-only loop produces. Adjusting them beforehand is guesswork wearing
/// the costume of improvement (CLAUDE.md non-negotiable #4).
///
/// Constants for stages that do not exist yet are still declared, because R-13
/// asks for the whole surface and because a config that grows a field per
/// milestone is a config nobody can diff across sessions.
public struct ControlConfiguration: Hashable, Sendable {
    // MARK: Observation (§6.2)

    /// Trailing mean window.
    public var window: Duration = .seconds(45)
    /// Freshness bound. A window whose newest sample is older than this
    /// reports no observation at all, and the zone is held.
    public var staleSample: Duration = .seconds(10)

    // MARK: Zone selection (§6.1, §6.3, §6.4, §6.5)

    /// Set explicitly by the owner. §6.1 is emphatic that this is not computed
    /// from age.
    public var maxHR: Int
    /// Lower bounds as a fraction of `maxHR`, for Z1, Z2, Z3, Z4. Ascending.
    ///
    /// The first entry is `MEDITATION_CEILING` — the Z0/Z1 boundary, 62 bpm at
    /// maxHR 182. Unlike the three above it, that one is a personal choice
    /// rather than a §6.7 tuning constant, so non-negotiable #4 does not hold
    /// it hostage to M2 logs: it belongs with `maxHR`. It should still move on
    /// evidence — sit still, watch the number, and put it above where you
    /// actually settle.
    public var zoneFractions: [Double] = ZoneBoundaries.defaultFractions
    /// Hysteresis half-width, as a fraction of `maxHR`. Entering a zone
    /// requires more than leaving it; that asymmetry is the point (§6.3).
    public var marginFraction: Double = 0.025
    /// Continuous confirmation before a zone change becomes eligible.
    public var dwell: Duration = .seconds(20)
    /// Zones per commit. A sprint from Z1 to Z4 walks up over three tracks.
    public var maxStep: Int = 1

    // MARK: Override (§6.6)

    /// **Dormant.** §6.6's hold no longer expires — `ZoneModel` explains why —
    /// so nothing reads this today.
    ///
    /// Kept rather than deleted because the timeout was never wrong in general,
    /// only wrong for a *deliberate* lock. When R-10 skip detection lands
    /// (D-7), an inferred override is exactly the case that wants an expiry: a
    /// false positive that never lapsed would disable auto-control for the rest
    /// of a session. The constant will be waiting, at the value §6.7 gives it.
    public var overrideHold: Duration = .seconds(180)

    // MARK: Commit timing (§6.7), all relative to the estimated track end

    public var commitOpen: Duration = .seconds(20)
    public var commitRetry1: Duration = .seconds(14)
    public var commitRetry2: Duration = .seconds(9)
    /// Past this point the commit is abandoned and a miss is logged.
    public var commitDeadline: Duration = .seconds(6)
    /// Below this much remaining, commit immediately instead of scheduling.
    public var shortTrackThreshold: Duration = .seconds(25)

    // MARK: Polling (§7.1)

    public var heartbeatPoll: Duration = .seconds(30)
    public var boundaryConfirm: [Duration] = [.seconds(2), .seconds(6)]

    public init(maxHR: Int) {
        self.maxHR = maxHR
    }

    public var boundaries: ZoneBoundaries {
        ZoneBoundaries(maxHR: maxHR, fractions: zoneFractions)
    }

    /// §6.3: `MARGIN = 0.025 × maxHR`, roughly 4–5 bpm for most values.
    public var marginBPM: Double {
        marginFraction * Double(maxHR)
    }
}
