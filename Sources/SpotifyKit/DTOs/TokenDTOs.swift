/// Wire types for `POST https://accounts.spotify.com/api/token`. SPEC.md §9.

struct TokenResponseDTO: Decodable, Sendable {
    var accessToken: String
    var tokenType: String?
    var expiresIn: Int?
    /// Spotify may rotate the refresh token on any refresh. §9.1: always
    /// persist it when present.
    var refreshToken: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

struct TokenErrorDTO: Decodable, Sendable {
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }

    /// The grant is dead: clear the Keychain and re-onboard (§9.3).
    var isInvalidGrant: Bool { error == "invalid_grant" }
}
