import Foundation
import SpotifyKit

/// Reads the client ID and redirect URI that `Config.local.xcconfig` injects
/// into Info.plist. CLAUDE.md: secrets never in the repo.
///
/// The client ID is not strictly a secret — PKCE exists precisely so that a
/// public client can live without one — but it identifies the owner's single
/// Development Mode app (§4.1: one client ID per developer), and there is no
/// reason to publish it.
enum AppConfiguration {
    enum ConfigurationError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let key):
                "\(key) is missing from Info.plist. Copy Config.example.xcconfig to Config.local.xcconfig and fill it in — see docs/SETUP.md."
            }
        }
    }

    static func string(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")  // an unsubstituted build setting
        else {
            throw ConfigurationError.missing(key)
        }
        return value
    }

    static func spotifyAuth() throws -> SpotifyAuthConfiguration {
        SpotifyAuthConfiguration(
            clientID: try string("SPOTIFY_CLIENT_ID"),
            redirectURI: try string("SPOTIFY_REDIRECT_URI")
        )
    }
}
