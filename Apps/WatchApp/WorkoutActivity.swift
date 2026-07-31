import Foundation
import HealthKit

/// SPEC.md §11.2's activity list — curated, not the full catalogue.
///
/// `HKWorkoutActivityType` has no public display-name API, so every entry
/// offered here is a hand-written string that has to be maintained and can be
/// subtly wrong. Roughly seventy of those is a lot of surface for a
/// single-user app, and most of it would never be picked. Adding one later is
/// one line.
///
/// **Location is part of the entry, not a second control.** §10 used to pin
/// `locationType = .unknown`, which was free when the workout session existed
/// only to obtain heart rate and background runtime. R-14 made the saved
/// workout a record the owner keeps, and `.unknown` gets a conservative energy
/// estimate for exactly the activities most likely to be used — so the choice
/// is made honestly and made once (D-8).
struct WorkoutActivity: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let activityType: HKWorkoutActivityType
    let locationType: HKWorkoutSessionLocationType

    /// The order they appear in. Running first because it is the likeliest,
    /// `Other` last because it is the fallback.
    static let all: [WorkoutActivity] = [
        .init(id: "running.outdoor", name: "Outdoor Run", activityType: .running, locationType: .outdoor),
        .init(id: "running.indoor", name: "Indoor Run", activityType: .running, locationType: .indoor),
        .init(id: "walking.outdoor", name: "Outdoor Walk", activityType: .walking, locationType: .outdoor),
        .init(id: "walking.indoor", name: "Indoor Walk", activityType: .walking, locationType: .indoor),
        .init(id: "cycling.outdoor", name: "Outdoor Cycle", activityType: .cycling, locationType: .outdoor),
        .init(id: "cycling.indoor", name: "Indoor Cycle", activityType: .cycling, locationType: .indoor),
        .init(id: "hiking", name: "Hiking", activityType: .hiking, locationType: .outdoor),
        .init(id: "rowing.indoor", name: "Indoor Row", activityType: .rowing, locationType: .indoor),
        .init(id: "rowing.outdoor", name: "Outdoor Row", activityType: .rowing, locationType: .outdoor),
        .init(id: "elliptical", name: "Elliptical", activityType: .elliptical, locationType: .indoor),
        .init(id: "stairs", name: "Stair Stepper", activityType: .stairClimbing, locationType: .indoor),
        .init(id: "strength.traditional", name: "Strength Training", activityType: .traditionalStrengthTraining, locationType: .indoor),
        .init(id: "strength.functional", name: "Functional Strength", activityType: .functionalStrengthTraining, locationType: .indoor),
        .init(id: "hiit", name: "HIIT", activityType: .highIntensityIntervalTraining, locationType: .indoor),
        .init(id: "yoga", name: "Yoga", activityType: .yoga, locationType: .indoor),
        // Looks like padding and is not: this is the only sensible label for a
        // Z0 meditation session, which is the zone §6.1 gained specifically.
        .init(id: "mindAndBody", name: "Mind & Body", activityType: .mindAndBody, locationType: .indoor),
        .init(id: "other", name: "Other", activityType: .other, locationType: .unknown),
    ]

    static let fallback = WorkoutActivity.all.last!

    static func named(_ id: String?) -> WorkoutActivity {
        guard let id else { return fallback }
        return all.first { $0.id == id } ?? fallback
    }
}

/// The idle screen's two settings, persisted so they survive a relaunch.
///
/// This is the sliver of R-13's configuration surface pulled forward out of M4.
/// It is here because R-14 made it load-bearing: a year of sessions labelled
/// `Other` is a worse record than the Workout app would have produced, which
/// undercuts the reason for saving them at all. Everything else R-13 wants —
/// the §6.7 constants, `maxHR`, the pool IDs — can wait.
@MainActor
@Observable
final class SessionSettings {
    private enum Key {
        static let activity = "session.activityID"
        static let saveWorkout = "session.saveWorkout"
    }

    private let defaults: UserDefaults

    var activity: WorkoutActivity {
        didSet { defaults.set(activity.id, forKey: Key.activity) }
    }

    /// R-14. Defaults to on: it is the entire mitigation for the
    /// single-workout-session constraint (§15), not a nicety.
    var saveWorkout: Bool {
        didSet { defaults.set(saveWorkout, forKey: Key.saveWorkout) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.activity = WorkoutActivity.named(defaults.string(forKey: Key.activity))
        self.saveWorkout = defaults.object(forKey: Key.saveWorkout) as? Bool ?? true
    }
}
