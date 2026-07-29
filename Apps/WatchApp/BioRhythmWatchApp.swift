import SwiftUI
import HRDJCore
import SpotifyKit

@main
struct BioRhythmWatchApp: App {
    /// One store, shared by the phone link that writes the token and the API
    /// stack that reads it.
    private let store: KeychainTokenStore
    @StateObject private var link: PhoneLink

    /// R-13 wants every §6.7 constant editable without a rebuild, and `maxHR`
    /// most of all — §6.1 has the owner set it explicitly rather than deriving
    /// it from age. The settings screen is M4; until then this is the one place
    /// it lives, and it is the single value most worth getting right before a
    /// real session, because every zone threshold is a percentage of it.
    private let configuration = ControlConfiguration(maxHR: 185)

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
