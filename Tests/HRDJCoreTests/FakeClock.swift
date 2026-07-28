import Foundation
import HRDJCore

/// The clock every HRDJCore test runs against. No test may use real time:
/// CLAUDE.md §2 requires the control logic to be drivable by a fake clock and
/// a synthetic HR trace, and a test that sleeps is a test that flakes.
///
/// `Clock` must be qualified — the standard library exports one too.
final class FakeClock: HRDJCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Instant

    init(start: Instant = .reference) {
        self.current = start
    }

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        current = current + duration
    }

    func set(to instant: Instant) {
        lock.lock()
        defer { lock.unlock() }
        current = instant
    }
}
