import Testing
import HRDJCore

@Suite("Instant and Duration arithmetic")
struct ClockTests {
    @Test("Adding and subtracting a duration round-trips")
    func roundTrip() {
        let start = Instant.reference
        let later = start + .seconds(45)
        #expect(later - start == .seconds(45))
        #expect(later - .seconds(45) == start)
    }

    @Test("Differences are signed")
    func signedDifference() {
        let start = Instant.reference
        let earlier = start - .seconds(10)
        #expect(earlier - start == .seconds(-10))
        #expect(earlier < start)
    }

    @Test("Sub-second durations survive conversion")
    func subSecond() {
        let start = Instant.reference
        let later = start + .milliseconds(1500)
        #expect((later - start).inSeconds == 1.5)
        #expect((later - start).wholeNanoseconds == 1_500_000_000)
    }

    @Test("Whole nanoseconds truncate rather than round")
    func truncation() {
        // 1.5 ns has an attosecond remainder that must not round up to 2.
        let duration = Duration(secondsComponent: 0, attosecondsComponent: 1_500_000_000)
        #expect(duration.wholeNanoseconds == 1)
    }

    @Test("FakeClock advances only when told to")
    func fakeClockIsInert() {
        let clock = FakeClock()
        let first = clock.now
        #expect(clock.now == first)
        clock.advance(by: .seconds(20))
        #expect(clock.now - first == .seconds(20))
    }

    @Test("SystemClock is monotonic non-decreasing")
    func systemClockMonotonic() {
        let clock = SystemClock()
        let first = clock.now
        let second = clock.now
        #expect(second >= first)
    }
}
