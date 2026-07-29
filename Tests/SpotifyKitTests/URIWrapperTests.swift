import Testing
import SpotifyKit

@Suite("Spotify URI wrappers")
struct URIWrapperTests {
    @Test("Track URIs preserve the exact Spotify URI")
    func trackURI() {
        let labeled = TrackURI(rawValue: "spotify:track:4iV5W9uYEdYUVa79Axb7Rh")
        let unlabeled = TrackURI("spotify:track:4iV5W9uYEdYUVa79Axb7Rh")

        #expect(labeled.rawValue == "spotify:track:4iV5W9uYEdYUVa79Axb7Rh")
        #expect(unlabeled == labeled)
        #expect(labeled.description == labeled.rawValue)
    }

    @Test("Playlist IDs are converted to playable context URIs")
    func playlistContextURI() {
        let context = ContextURI(playlistID: "37i9dQZF1DXcBWIGoYBM5M")

        #expect(context.rawValue == "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")
        #expect(context.description == context.rawValue)
    }

    @Test("Device IDs preserve the exact Connect identifier")
    func deviceID() {
        let labeled = DeviceID(rawValue: "watch-device-id")
        let unlabeled = DeviceID("watch-device-id")

        #expect(labeled.rawValue == "watch-device-id")
        #expect(unlabeled == labeled)
        #expect(labeled.description == labeled.rawValue)
    }
}
