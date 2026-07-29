import SwiftUI

/// The companion exists for one job: run the OAuth leg that watchOS cannot,
/// and hand the refresh token to the watch (SPEC.md §9.1). Anything that runs
/// during a workout belongs on the watch.
@main
struct BioRhythmCompanionApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            OnboardingView(link: link)
        }
    }
}
