import Foundation
import HealthKit

/// The HealthKit types this file needs, outside any actor.
///
/// Computed rather than stored, and in their own namespace rather than as
/// statics on `HealthKitSource`. The class is `@MainActor`, which its static
/// members inherit — and the sample callback is `nonisolated`, because that is
/// where HealthKit delivers. A stored static would be unreachable from exactly
/// the place it is needed. Constructing them per call is cheap.
private enum HealthKitTypes {
    static var heartRate: HKQuantityType { HKQuantityType(.heartRate) }
    static var bpm: HKUnit { HKUnit.count().unitDivided(by: .minute()) }
}

/// Live heart rate from an `HKWorkoutSession`. SPEC.md §10.
///
/// The workout session exists to obtain live HR **and** extended background
/// runtime — that is why §10 forbids also requesting a
/// `WKExtendedRuntimeSession`. The workout session is the sanctioned mechanism
/// and asking for both is how you get neither.
@MainActor
final class HealthKitSource: NSObject {
    enum SourceError: LocalizedError {
        case healthDataUnavailable
        case authorizationDenied
        /// §10: only one workout session may be active device-wide.
        case sessionHeldByAnotherApp(underlying: String)
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable:
                "Health data is not available on this device."
            case .authorizationDenied:
                "bio-rhythm needs permission to read heart rate. Grant it in the Watch app under Privacy."
            case .sessionHeldByAnotherApp:
                // Named specifically, per §10 and §11.4: this is not a retry
                // situation and a generic failure message sends the owner
                // looking in the wrong place.
                "Another app is already recording a workout. End it — the Workout app, Strava, or whatever started it — and try again."
            case .sessionFailed(let detail):
                "Could not start the workout session: \(detail)"
            }
        }
    }

    /// A heart rate reading, with the wall-clock time HealthKit gave it.
    struct Reading: Sendable {
        let bpm: Int
        let date: Date
    }

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// Called on the main actor for each new reading.
    var onReading: (@MainActor (Reading) -> Void)?
    /// Called when the session state changes, including auto-pause. A paused
    /// session suspends commits (§10).
    var onStateChange: (@MainActor (HKWorkoutSessionState) -> Void)?


    func requestAuthorization(saveWorkout: Bool) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw SourceError.healthDataUnavailable
        }
        // §10: share HKWorkoutType only when R-14 is enabled. Asking for write
        // access the product does not use is a permission prompt that buys
        // nothing and costs trust.
        let share: Set<HKSampleType> = saveWorkout ? [HKWorkoutType.workoutType()] : []
        let read: Set<HKObjectType> = [HealthKitTypes.heartRate]

        try await store.requestAuthorization(toShare: share, read: read)
    }

    func start(
        activityType: HKWorkoutActivityType = .other,
        locationType: HKWorkoutSessionLocationType = .unknown
    ) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw SourceError.healthDataUnavailable
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        // §10/D-8: set honestly rather than pinned to `.unknown`. It
        // materially improves the system's energy estimate for running,
        // cycling and walking, which is the ring credit R-14 exists to provide.
        configuration.locationType = locationType

        let session: HKWorkoutSession
        do {
            session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        } catch {
            throw Self.classify(error)
        }

        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder

        let start = Date()
        session.startActivity(with: start)
        do {
            try await builder.beginCollection(at: start)
        } catch {
            self.session = nil
            self.builder = nil
            throw Self.classify(error)
        }
    }

    func stop(saveWorkout: Bool) async {
        guard let session, let builder else { return }

        let end = Date()
        session.end()
        try? await builder.endCollection(at: end)
        if saveWorkout {
            _ = try? await builder.finishWorkout()
        }

        self.session = nil
        self.builder = nil
    }

    /// HealthKit reports the single-session conflict as a plain error. Pull it
    /// apart here so the UI can say something actionable rather than echoing a
    /// framework string.
    private static func classify(_ error: any Error) -> SourceError {
        let description = error.localizedDescription

        // Cast to HKError rather than comparing a bare NSError code: the code
        // alone says nothing about which domain it came from, so an unrelated
        // error that happens to share the number would be reported to the owner
        // as a workout conflict and send them looking for an app that is not
        // running.
        if let healthKitError = error as? HKError,
           healthKitError.code == .errorAnotherWorkoutSessionStarted {
            return .sessionHeldByAnotherApp(underlying: description)
        }
        return .sessionFailed(description)
    }
}

extension HealthKitSource: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.onStateChange?(toState)
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            self.onStateChange?(.stopped)
        }
    }
}

extension HealthKitSource: HKLiveWorkoutBuilderDelegate {
    // `didCollectDataOf`, not `didCollectDataFor`. Easy to get backwards and
    // the compiler is the only thing that will tell you.
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let heartRateType = HealthKitTypes.heartRate
        guard collectedTypes.contains(heartRateType) else { return }

        // §10: read the most recent quantity from the running statistics and
        // convert to count/min.
        guard let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity()
        else { return }

        let bpm = Int(quantity.doubleValue(for: HealthKitTypes.bpm).rounded())
        let date = statistics.mostRecentQuantityDateInterval()?.end ?? Date()

        Task { @MainActor in
            self.onReading?(Reading(bpm: bpm, date: date))
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
