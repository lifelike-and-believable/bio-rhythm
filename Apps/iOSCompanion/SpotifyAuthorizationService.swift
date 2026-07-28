import AuthenticationServices
import Foundation
import UIKit
import SpotifyKit

/// The interactive OAuth leg. SPEC.md §9.1.
///
/// This lives on the phone because `ASWebAuthenticationSession` does not exist
/// on watchOS. It is the only phone dependency in the product and it is
/// onboarding-only — after the refresh token reaches the watch Keychain, the
/// watch refreshes on its own and the phone can stay in a drawer (G3).
@MainActor
final class SpotifyAuthorizationService: NSObject {
    enum AuthorizationError: LocalizedError {
        case malformedAuthorizationURL
        case stateMismatch
        case noCodeInCallback(String)
        case malformedRedirectURI

        var errorDescription: String? {
            switch self {
            case .malformedAuthorizationURL:
                "Could not build the Spotify authorization URL."
            case .stateMismatch:
                "The authorization response did not match the request. Try again."
            case .noCodeInCallback(let description):
                "Spotify did not return an authorization code: \(description)"
            case .malformedRedirectURI:
                "SPOTIFY_REDIRECT_URI has no scheme. See docs/SETUP.md."
            }
        }
    }

    private let configuration: SpotifyAuthConfiguration
    private let client: AuthorizationClient

    init(configuration: SpotifyAuthConfiguration) {
        self.configuration = configuration
        self.client = AuthorizationClient(configuration: configuration)
    }

    func authorize() async throws -> TokenGrant {
        let pair = PKCE.generate()
        let state = PKCE.generateVerifier(byteCount: 16)

        guard let url = client.authorizationURL(challenge: pair.challenge, state: state) else {
            throw AuthorizationError.malformedAuthorizationURL
        }
        guard let scheme = URL(string: configuration.redirectURI)?.scheme else {
            throw AuthorizationError.malformedRedirectURI
        }

        let callback = try await present(url: url, callbackScheme: scheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard value("state") == state else {
            throw AuthorizationError.stateMismatch
        }
        guard let code = value("code") else {
            throw AuthorizationError.noCodeInCallback(value("error") ?? "no error given")
        }

        return try await client.exchange(code: code, verifier: pair.verifier)
    }

    private func present(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthorizationError.noCodeInCallback("empty callback"))
                }
            }
            session.presentationContextProvider = self
            // The owner is already signed into Spotify in Safari; reusing that
            // session is the difference between one tap and retyping a password.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}

extension SpotifyAuthorizationService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
