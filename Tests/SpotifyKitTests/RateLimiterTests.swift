import Testing
import HRDJCore
import SpotifyKit

@Suite("Rate limiter — SPEC.md §9.4")
struct RateLimiterTests {
    @Test("The burst goes out immediately")
    func burstIsFree() async {
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 10, clock: FakeClock())
        for _ in 0..<10 {
            #expect(await limiter.reserve() == .zero)
        }
    }

    @Test("Past the burst, callers are told to wait the refill interval")
    func waitAfterBurst() async {
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 10, clock: FakeClock())
        for _ in 0..<10 {
            _ = await limiter.reserve()
        }
        // 60/minute is one per second, so the eleventh waits a second.
        #expect(await limiter.reserve() == .seconds(1))
    }

    @Test("Queued callers wait behind each other, not alongside")
    func waitsAccumulate() async {
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 2, clock: FakeClock())
        _ = await limiter.reserve()
        _ = await limiter.reserve()
        // If the deficit were clamped at zero, these would both come back as
        // one second and then fire simultaneously.
        #expect(await limiter.reserve() == .seconds(1))
        #expect(await limiter.reserve() == .seconds(2))
        #expect(await limiter.reserve() == .seconds(3))
    }

    @Test("Time refills the bucket")
    func refill() async {
        let clock = FakeClock()
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 5, clock: clock)
        for _ in 0..<5 {
            _ = await limiter.reserve()
        }
        #expect(await limiter.reserve() > .zero)

        clock.advance(by: .seconds(10))
        #expect(await limiter.reserve() == .zero)
    }

    @Test("Refill never exceeds the burst capacity")
    func refillClamps() async {
        let clock = FakeClock()
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 3, clock: clock)
        clock.advance(by: .seconds(600))
        for _ in 0..<3 {
            #expect(await limiter.reserve() == .zero)
        }
        #expect(await limiter.reserve() > .zero)
    }

    @Test("Retry-After is honoured absolutely, even with permits in hand")
    func retryAfterOverridesAvailablePermits() async {
        let clock = FakeClock()
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 10, clock: clock)

        await limiter.penalise(retryAfter: .seconds(30))
        #expect(await limiter.reserve() == .seconds(30))

        clock.advance(by: .seconds(20))
        #expect(await limiter.reserve() == .seconds(10))

        clock.advance(by: .seconds(10))
        #expect(await limiter.reserve() == .zero)
    }

    @Test("A shorter penalty does not shorten a longer one already in force")
    func penaltiesDoNotShrink() async {
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 10, clock: FakeClock())
        await limiter.penalise(retryAfter: .seconds(60))
        await limiter.penalise(retryAfter: .seconds(5))
        #expect(await limiter.reserve() == .seconds(60))
    }

    @Test("A 429 with no Retry-After still pauses briefly")
    func missingRetryAfterStillPauses() async {
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 10, clock: FakeClock())
        await limiter.penalise(retryAfter: nil)
        #expect(await limiter.reserve() > .zero)
    }
}
