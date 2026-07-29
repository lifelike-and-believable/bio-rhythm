// Standard library only. See CLAUDE.md §2.

/// Trailing statistics over recent heart rate samples. SPEC.md §6.2.
///
/// Four rules, and the fourth is the one that matters:
///
/// 1. Samples older than `length` (45 s) fall out of the window.
/// 2. Samples outside `HRSample.plausibleBPM` are rejected on the way in —
///    sensor dropout and contact loss produce values well outside it.
/// 3. `observedHR` is the arithmetic mean of what remains.
/// 4. If the newest sample is older than `staleAfter` (10 s), the window
///    reports **nothing** rather than a stale average. §6.2: on missing data
///    the caller holds the current zone. Never move a zone on a guess.
///
/// The trailing mean costs roughly 20 s of lag and buys near-total immunity to
/// noise. With one decision per track that lag is free (§15).
public struct HRWindow: Hashable, Sendable {
    public let length: Duration
    public let staleAfter: Duration

    /// Ascending by timestamp. Named `storage` rather than `samples` so it
    /// cannot be confused with `samples(at:)` at a glance or by the compiler.
    private var storage: [HRSample] = []

    public init(length: Duration = .seconds(45), staleAfter: Duration = .seconds(10)) {
        self.length = length
        self.staleAfter = staleAfter
    }

    public init(configuration: ControlConfiguration) {
        self.init(length: configuration.window, staleAfter: configuration.staleSample)
    }

    /// Inserts a sample. Returns false if it was rejected as implausible,
    /// which the caller may want to count — a run of rejections is a sensor
    /// problem, not a quiet nothing.
    @discardableResult
    public mutating func insert(_ sample: HRSample) -> Bool {
        guard sample.isPlausible else { return false }

        // Sorted insert rather than append: HealthKit delivers roughly 1 Hz but
        // makes no ordering promise across a delivery batch, and a trailing
        // mean has no reason to care which order they arrived in.
        let index = storage.firstIndex { $0.at > sample.at } ?? storage.endIndex
        storage.insert(sample, at: index)

        // Bound memory against the newest timestamp seen. Queries filter again
        // against their own `now`, so this is housekeeping, not the rule.
        if let newest = storage.last {
            let cutoff = newest.at - length
            storage.removeAll { $0.at < cutoff }
        }
        return true
    }

    public var newest: HRSample? { storage.last }

    /// The most recent reading, for display. Not the control input — §6.2 uses
    /// the mean, and §11.3 logs both so the two can be compared afterwards.
    public var instantaneousBPM: Int? { storage.last?.bpm }

    public func isStale(at now: Instant) -> Bool {
        guard let newest else { return true }
        return now - newest.at > staleAfter
    }

    public func samples(at now: Instant) -> [HRSample] {
        let cutoff = now - length
        return storage.filter { $0.at >= cutoff && $0.at <= now }
    }

    public func sampleCount(at now: Instant) -> Int {
        samples(at: now).count
    }

    /// The control input. Nil when the window is stale or empty — hold the
    /// zone, log `hr_sample_gap`, and carry on (§11.4).
    public func observedHR(at now: Instant) -> Double? {
        guard !isStale(at: now) else { return nil }
        let inWindow = samples(at: now)
        guard !inWindow.isEmpty else { return nil }
        let total = inWindow.reduce(0) { $0 + $1.bpm }
        return Double(total) / Double(inWindow.count)
    }

    /// How long since the last accepted sample. Nil when none has arrived.
    /// Drives the gap figure in `hr_sample_gap`.
    public func timeSinceNewest(at now: Instant) -> Duration? {
        guard let newest else { return nil }
        return now - newest.at
    }

    public mutating func removeAll() {
        storage.removeAll()
    }
}
