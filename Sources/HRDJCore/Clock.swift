// Standard library only. No Foundation, no Date, no I/O. See CLAUDE.md §2.

/// A point on a monotonic timeline.
///
/// Deliberately *not* a wall-clock time. Nothing in the control law cares what
/// day it is; everything cares about elapsed intervals, and wall clocks jump.
/// The reference point is arbitrary and only comparisons/differences are
/// meaningful. Wall-clock stamps for telemetry (§11.3) are applied by the
/// logging layer in the app target, not here.
public struct Instant: Hashable, Comparable, Sendable {
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    /// The reference point of the timeline. Only useful as a test origin.
    public static let reference = Instant(nanoseconds: 0)

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public static func + (lhs: Instant, rhs: Duration) -> Instant {
        Instant(nanoseconds: lhs.nanoseconds + rhs.wholeNanoseconds)
    }

    public static func - (lhs: Instant, rhs: Duration) -> Instant {
        Instant(nanoseconds: lhs.nanoseconds - rhs.wholeNanoseconds)
    }

    /// Elapsed time from `rhs` to `lhs`. Negative if `lhs` precedes `rhs`.
    public static func - (lhs: Instant, rhs: Instant) -> Duration {
        .nanoseconds(lhs.nanoseconds - rhs.nanoseconds)
    }
}

extension Duration {
    /// Truncating conversion to whole nanoseconds.
    public var wholeNanoseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }

    /// Lossy conversion to seconds, for logging and threshold comparisons.
    public var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// The only source of time available to control logic.
///
/// Shadows `Swift.Clock` inside this module. Modules that import HRDJCore must
/// qualify the reference as `HRDJCore.Clock`, because the standard library's
/// `Clock` is always in scope and the unqualified name would be ambiguous.
/// The name is fixed by SPEC.md §5.2; see the note in docs/verification.md.
public protocol Clock: Sendable {
    var now: Instant { get }
}

/// Production clock, backed by the standard library's monotonic
/// `ContinuousClock`. Continuous rather than suspending: a watch that sleeps
/// mid-track has still consumed real track time, and the boundary estimate in
/// §7.1 must reflect that.
public struct SystemClock: Clock {
    private let origin: ContinuousClock.Instant

    public init() {
        self.origin = ContinuousClock.now
    }

    public var now: Instant {
        Instant(nanoseconds: origin.duration(to: ContinuousClock.now).wholeNanoseconds)
    }
}
