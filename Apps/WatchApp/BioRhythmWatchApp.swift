import SwiftUI
import SpotifyKit

@main
struct BioRhythmWatchApp: App {
    /// One store, shared by the phone link that writes the token and the API
    /// stack that reads it.
    private let store: KeychainTokenStore
    @StateObject private var link: PhoneLink

    init() {
        let store = KeychainTokenStore()
        self.store = store
        _link = StateObject(wrappedValue: PhoneLink(store: store))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                NowPlayingView(link: link, store: store)
            }
        }
    }
}
