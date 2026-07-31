import SwiftUI
import HRDJCore
import SpotifyKit

@main
struct BioRhythmWatchApp: App {
    /// One store, shared by the phone link that writes the token and the API
    /// stack that reads it.
    private let store: KeychainTokenStore
    @StateObject private var link: PhoneLink

    /// The owner's maximum, set explicitly — §6.1 is emphatic that this is not
    /// derived from age. At 182 the thresholds are 62 / 109 / 127 / 149 bpm and
    /// the §6.3 hysteresis margin is 4.55 bpm.
    ///
    /// The 62 is the meditation ceiling and is the one threshold that is not a
    /// percentage of `maxHR` — it stays at 62 whatever this value becomes. See
    /// `ZoneBoundaries` for why.
    ///
    /// R-13 wants every §6.7 constant editable without a rebuild. The settings
    /// screen is M4; until then this is the one place it lives, and it is the
    /// value most worth getting right, because every threshold is a percentage
    /// of it.
    private let configuration = ControlConfiguration(maxHR: 182)

    init() {
        let store = KeychainTokenStore()
        self.store = store
        _link = StateObject(wrappedValue: PhoneLink(store: store))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SessionView(link: link, store: store, configuration: configuration)
            }
        }
    }
}
