import Foundation
import HealthKit
import HRDJCore

/// Session lifecycle for M1: start a workout, feed HR into `HRWindow`, show
/// the zone, log continuously. SPEC.md §13.
///
/// **No actuation and no network writes.** M1 is observation only, and M2 is
/// observation only after it. The point of both is to accumulate real traces
/// before anything is allowed to drive playback (CLAUDE.md non-negotiable #4).
/// If you find yourself reaching for `PlaybackQueueing` here, you are in the
/// wrong milestone.
@MainActor
@Observable
final class WorkoutCoordinator {
    enum State: Equatable {
        case idle
        case starting
        case running
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Most recent reading, for the large number on screen.
    private(set) var instantaneousBPM: Int?
    /// The §6.2 trailing mean — the control input, and nil when stale.
    private(set) var observedHR: Double?
    /// Raw zone from the mean. No hysteresis until M2, so expect this to
    /// flicker on a threshold.
    private(set) var zone: Zone?
    private(set) var sampleCount = 0
    private(set) var isStale = false
    private(set) var startedAt: Date?

    var configuration: ControlConfiguration

    private let clock: any HRDJCore.Clock
    private let source: HealthKitSource
    private var window: HRWindow
    private var telemetry: TelemetryLog?
    /// Wall clock at the moment the monotonic clock read `sessionOrigin`, so
    /// HealthKit's `Date` stamps can be placed on the monotonic timeline.
    private var sessionOrigin: (wall: Date, instant: Instant)?
    private var wasStale = false

    init(
        configuration: ControlConfiguration,
        clock: any HRDJCore.Clock = SystemClock(),
        source: HealthKitSource = HealthKitSource()
    ) {
        self.configuration = configuration
        self.clock = clock
        self.source = source
        self.window = HRWindow(configuration: configuration)
    }

    func start() async {
        guard state == .idle || isFailed else { return }

        state = .starting
        window = HRWindow(configuration: configuration)
        sampleCount = 0

        source.onReading = { [weak self] reading in
            self?.ingest(reading)
        }
        source.onStateChange = { [weak self] sessionState in
            self?.apply(sessionState)
        }

        do {
            try await source.requestAuthorization(saveWorkout: false)
            try await source.start()

            let now = Date()
            sessionOrigin = (wall: now, instant: clock.now)
            startedAt = now
            telemetry = try? TelemetryLog(directory: TelemetryLog.defaultDirectory(), startedAt: now)

            state = .running
            log(.sessionStart)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        log(.sessionEnd)
        await source.stop(saveWorkout: false)
        await telemetry?.close()
        telemetry = nil
        sessionOrigin = nil
        state = .idle
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Sample ingestion

    private func ingest(_ reading: HealthKitSource.Reading) {
        guard let origin = sessionOrigin else { return }

        // HealthKit stamps readings with wall-clock dates; the control law runs
        // on a monotonic timeline. Anchor once at session start and offset from
        // there, so a wall-clock adjustment mid-workout cannot reorder samples.
        let offset = reading.date.timeIntervalSince(origin.wall)
        let at = origin.instant + .seconds(offset)

        let accepted = window.insert(HRSample(at: at, bpm: reading.bpm))
        if accepted {
            instantaneousBPM = reading.bpm
        }
        refreshDerived()
    }

    private func refreshDerived() {
        let now = clock.now
        observedHR = window.observedHR(at: now)
        sampleCount = window.sampleCount(at: now)
        isStale = window.isStale(at: now)

        if let observedHR {
            // §6.2: hold the zone on missing data. Leaving `zone` untouched
            // when the observation is nil is that rule, expressed as an
            // assignment that does not happen.
            zone = configuration.boundaries.zone(for: observedHR)
        }

        if isStale && !wasStale {
            log(.hrSampleGap)
        }
        wasStale = isStale
    }

    // MARK: - Telemetry

    private func log(_ event: Decision.Event) {
        guard let telemetry else { return }

        var decision = Decision(at: clock.now, event: event)
        decision.hrInstant = instantaneousBPM
        decision.hrWindowMean = observedHR
        decision.windowSampleCount = sampleCount
        decision.currentZone = zone

        Task { await telemetry.append(decision) }
    }

    private func apply(_ sessionState: HKWorkoutSessionState) {
        switch sessionState {
        case .running:
            state = .running
        case .paused:
            // §10: a paused session suspends commits. Nothing to suspend yet in
            // M1, but the state has to be visible or M3 inherits a silent bug.
            state = .paused
        case .ended, .stopped:
            state = .idle
        default:
            break
        }
    }
}
