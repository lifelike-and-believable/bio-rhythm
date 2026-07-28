import Foundation
import Testing
import SpotifyKit

@Suite("PKCE and the authorization request — SPEC.md §9.1, §9.2")
struct AuthorizationTests {
    private let configuration = SpotifyAuthConfiguration(
        clientID: "test-client",
        redirectURI: "biorhythm://callback"
    )

    @Test("Only the four scopes in §9.2 are requested")
    func scopesAreExactlyTheRequiredSet() {
        #expect(SpotifyAuthConfiguration.requiredScopes == [
            "user-read-playback-state",
            "user-modify-playback-state",
            "playlist-read-private",
            "playlist-read-collaborative",
        ])
        // `user-read-email` and `user-read-private` buy nothing now that
        // `email`, `country`, and `product` are gone from the user object.
        #expect(SpotifyAuthConfiguration.requiredScopes.contains("user-read-email") == false)
        #expect(SpotifyAuthConfiguration.requiredScopes.contains("user-read-private") == false)
    }

    @Test("The authorization URL carries the PKCE challenge and no secret")
    func authorizationURL() throws {
        let client = AuthorizationClient(configuration: configuration, transport: FakeTransport())
        let url = try #require(client.authorizationURL(challenge: "test-challenge", state: "state-123"))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        #expect(components.host == "accounts.spotify.com")
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "test-client")
        #expect(query["redirect_uri"] == "biorhythm://callback")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == "test-challenge")
        #expect(query["state"] == "state-123")
        #expect(query["scope"] == SpotifyAuthConfiguration.requiredScopes.joined(separator: " "))
        // §9.1: no client secret on device, ever.
        #expect(query["client_secret"] == nil)
    }

    @Test("Form bodies percent-encode the characters that would corrupt them")
    func formEncoding() {
        let encoded = AuthorizationClient.formURLEncoded([
            "grant_type": "refresh_token",
            "refresh_token": "abc+def/ghi=jkl&mno",
        ])
        // A raw `+` in a form body decodes as a space and a raw `&` splits the
        // field, either of which silently produces a wrong refresh token.
        #expect(encoded.contains("abc%2Bdef%2Fghi%3Djkl%26mno"))
        #expect(encoded == "grant_type=refresh_token&refresh_token=abc%2Bdef%2Fghi%3Djkl%26mno")
    }

    @Test("Unreserved characters are left alone")
    func unreservedCharacters() {
        #expect(AuthorizationClient.percentEncoded("aZ0-._~") == "aZ0-._~")
    }

    @Test("The code exchange sends the verifier and the redirect URI")
    func exchangeSendsVerifier() async throws {
        let transport = FakeTransport()
        let client = AuthorizationClient(configuration: configuration, transport: transport)

        let grant = try await client.exchange(code: "auth-code", verifier: "the-verifier")

        #expect(grant.accessToken == "access-1")
        let request = try #require(await transport.tokenRequests.first)
        let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
        #expect(body.contains("code=auth-code"))
        #expect(body.contains("code_verifier=the-verifier"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("client_id=test-client"))
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test("Verifiers are RFC 7636-legal and not repeated")
    func verifierShape() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        var seen = Set<String>()
        for _ in 0..<50 {
            let verifier = PKCE.generateVerifier()
            #expect((43...128).contains(verifier.count))
            #expect(verifier.allSatisfy { allowed.contains($0) })
            seen.insert(verifier)
        }
        #expect(seen.count == 50)
    }

    #if canImport(CryptoKit)
    @Test("The challenge is a base64url SHA-256 of the verifier")
    func challengeIsDeterministic() {
        // RFC 7636 Appendix B's worked example, which is the only way to check
        // the encoding without trusting the implementation that produced it.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        let pair = PKCE.generate()
        #expect(pair.method == "S256")
        #expect(pair.challenge == PKCE.challenge(for: pair.verifier))
        // base64url: no padding, no `+`, no `/`.
        #expect(pair.challenge.contains("=") == false)
        #expect(pair.challenge.contains("+") == false)
        #expect(pair.challenge.contains("/") == false)
    }
    #endif
}
