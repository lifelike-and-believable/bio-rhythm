import Foundation
import HealthKit

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

    private static let heartRateType = HKQuantityType(.heartRate)
    private static let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    func requestAuthorization(saveWorkout: Bool) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw SourceError.healthDataUnavailable
        }
        // §10: share HKWorkoutType only when R-14 is enabled. Asking for write
        // access the product does not use is a permission prompt that buys
        // nothing and costs trust.
        let share: Set<HKSampleType> = saveWorkout ? [HKWorkoutType.workoutType()] : []
        let read: Set<HKObjectType> = [Self.heartRateType]

        try await store.requestAuthorization(toShare: share, read: read)
    }

    func start(activityType: HKWorkoutActivityType = .other) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw SourceError.healthDataUnavailable
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        configuration.locationType = .unknown

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
        let code = (error as NSError).code
        // `HKErrorAnotherWorkoutSessionStarted`. Matched by code where possible
        // and by text as a fallback, because the code is the reliable half and
        // the text is the readable one.
        if code == HKError.errorAnotherWorkoutSessionStarted.rawValue
            || description.localizedCaseInsensitiveContains("another workout session") {
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
        guard collectedTypes.contains(Self.heartRateType) else { return }

        // §10: read the most recent quantity from the running statistics and
        // convert to count/min.
        guard let statistics = workoutBuilder.statistics(for: Self.heartRateType),
              let quantity = statistics.mostRecentQuantity()
        else { return }

        let bpm = Int(quantity.doubleValue(for: Self.bpmUnit).rounded())
        let date = statistics.mostRecentQuantityDateInterval()?.end ?? Date()

        Task { @MainActor in
            self.onReading?(Reading(bpm: bpm, date: date))
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
