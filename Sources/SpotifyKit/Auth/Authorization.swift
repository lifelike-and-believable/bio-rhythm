import Foundation

/// Everything the OAuth leg needs. Values come from `Config.local.xcconfig`
/// via the app's Info.plist — never from source. See docs/SETUP.md.
public struct SpotifyAuthConfiguration: Sendable {
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]

    /// SPEC.md §9.2. Do not request scopes beyond these — `user-read-email`
    /// and `user-read-private` are pointless now that `email`, `country`, and
    /// `product` have been removed from the user object.
    public static let requiredScopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "playlist-read-private",
        "playlist-read-collaborative",
    ]

    public init(clientID: String, redirectURI: String, scopes: [String] = SpotifyAuthConfiguration.requiredScopes) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

/// The token pair as it comes back from the accounts service.
public struct TokenGrant: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int
}

/// Talks to `https://accounts.spotify.com`. Separate from `SpotifyAPI`, which
/// talks to `api.spotify.com` and needs a token this type produces.
public struct AuthorizationClient: Sendable {
    public static let authorizeEndpoint = "https://accounts.spotify.com/authorize"
    public static let tokenEndpoint = "https://accounts.spotify.com/api/token"

    private let configuration: SpotifyAuthConfiguration
    private let transport: any HTTPTransport

    public init(configuration: SpotifyAuthConfiguration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// The URL to hand to `ASWebAuthenticationSession` on the iOS companion.
    /// watchOS has no equivalent, which is why onboarding needs the phone (§9.1).
    public func authorizationURL(challenge: String, state: String) -> URL? {
        var components = URLComponents(string: Self.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        return components?.url
    }

    public func exchange(code: String, verifier: String) async throws -> TokenGrant {
        try await postForm([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI,
            "client_id": configuration.clientID,
            "code_verifier": verifier,
        ])
    }

    public func refresh(refreshToken: String) async throws -> TokenGrant {
        try await postForm([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ])
    }

    private func postForm(_ fields: [String: String]) async throws -> TokenGrant {
        let request = HTTPRequest(
            method: "POST",
            url: Self.tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(Self.formURLEncoded(fields).utf8)
        )

        let response = try await transport.send(request)

        guard (200..<300).contains(response.status) else {
            // §9.3: `invalid_grant` means the grant is dead, which is a
            // different situation from a transient failure and needs
            // re-onboarding rather than a retry.
            if let error = try? JSONDecoder().decode(TokenErrorDTO.self, from: response.body),
               error.isInvalidGrant {
                throw SpotifyError.reauthorizationRequired
            }
            if response.status == 429 {
                throw SpotifyError.rateLimited(retryAfter: response.retryAfter)
            }
            throw SpotifyError.server(status: response.status, body: response.bodyText)
        }

        do {
            let dto = try JSONDecoder().decode(TokenResponseDTO.self, from: response.body)
            return TokenGrant(
                accessToken: dto.accessToken,
                refreshToken: dto.refreshToken,
                expiresIn: dto.expiresIn ?? 3600
            )
        } catch {
            throw SpotifyError.decoding("token response: \(error)")
        }
    }

    static func formURLEncoded(_ fields: [String: String]) -> String {
        // Sorted so the body is reproducible, which makes fixtures and logs
        // comparable across runs.
        fields.sorted { $0.key < $1.key }
            .map { "\(percentEncoded($0.key))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
    }

    static func percentEncoded(_ value: String) -> String {
        // RFC 3986 unreserved set. `addingPercentEncoding` with
        // `.urlQueryAllowed` leaves `+` and `&` intact, which corrupts a form
        // body, so the allowed set is spelled out instead.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
