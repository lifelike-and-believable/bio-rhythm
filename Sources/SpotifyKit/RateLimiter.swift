import HRDJCore

/// Conservative client-side token bucket. SPEC.md §9.4.
///
/// Spotify does not publish exact limits, so the defaults are the spec's
/// suggestion (60 requests/minute, burst 10) rather than anything measured.
/// V-2 is the measurement that would justify changing them.
///
/// `reserve()` returns the delay the caller should wait rather than sleeping
/// itself. That keeps the actor free, and it keeps tests deterministic: a fake
/// clock can assert the computed delay without any real time passing.
public actor RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private let clock: any HRDJCore.Clock

    private var tokens: Double
    private var lastRefill: Instant
    /// Set by `penalise(retryAfter:)` on a 429. Honoured absolutely (§9.4).
    private var penaltyUntil: Instant?

    public init(
        permitsPerMinute: Int = 60,
        burst: Int = 10,
        clock: any HRDJCore.Clock = SystemClock()
    ) {
        self.capacity = Double(burst)
        self.refillPerSecond = Double(permitsPerMinute) / 60.0
        self.clock = clock
        self.tokens = Double(burst)
        self.lastRefill = clock.now
    }

    /// Consumes one permit and returns how long to wait before sending.
    /// Zero when the request may go out immediately.
    public func reserve() -> Duration {
        let now = clock.now
        refill(to: now)

        var wait = Duration.zero
        if let penaltyUntil, penaltyUntil > now {
            wait = penaltyUntil - now
        }
        if tokens < 1 {
            let deficitSeconds = (1 - tokens) / refillPerSecond
            wait = max(wait, .seconds(deficitSeconds))
        }
        // Allowed to go negative: a deficit is what makes concurrent callers
        // queue behind each other instead of all being told to wait the same
        // amount and then firing together.
        tokens -= 1
        return wait
    }

    /// Applies a server-instructed pause. Every reservation made from now until
    /// the penalty expires waits at least that long.
    public func penalise(retryAfter: Duration?) {
        let pause = retryAfter ?? .seconds(1)
        let until = clock.now + pause
        if let current = penaltyUntil, current > until { return }
        penaltyUntil = until
    }

    /// Diagnostic only.
    public var availablePermits: Double {
        let now = clock.now
        var projected = tokens + (now - lastRefill).inSeconds * refillPerSecond
        projected = min(capacity, projected)
        return projected
    }

    private func refill(to now: Instant) {
        let elapsed = (now - lastRefill).inSeconds
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
    }
}
