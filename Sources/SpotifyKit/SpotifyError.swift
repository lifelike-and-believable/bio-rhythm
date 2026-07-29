/// Errors surfaced by SpotifyKit. The cases map onto the behaviours required
/// by SPEC.md §11.4, so callers can branch on them without parsing strings.
public enum SpotifyError: Error, Sendable {
    /// 401 after a refresh attempt already happened. Not retryable in place.
    case unauthorized
    /// 403. §11.4: log loudly with the body — usually a lapsed Premium
    /// subscription or a missing scope, and the two need different messages.
    case forbidden(body: String)
    /// 404. On a player write this means no active device (§11.4).
    case notFound(body: String)
    /// 429. `retryAfter` comes from the header and is honoured absolutely (§9.4).
    case rateLimited(retryAfter: Duration?)
    case server(status: Int, body: String)
    case decoding(String)
    /// The request never completed: no network, TLS failure, timeout. Carried
    /// as text because `any Error` is not `Sendable` and this enum crosses
    /// isolation boundaries on every call.
    case transport(message: String)
    /// The refresh grant is dead. Clear the Keychain, re-onboard (§9.3).
    case reauthorizationRequired
    /// No refresh token on this device yet — onboarding has not happened.
    case notAuthenticated
    /// Device acquisition found no device matching the selection criteria.
    case noSuitableDevice

    /// Whether this counts toward the three consecutive failures that trigger
    /// DEGRADED (§7.4). Everything network-shaped does; a dead grant does not,
    /// because it needs re-onboarding rather than backoff.
    public var countsTowardDegraded: Bool {
        switch self {
        case .reauthorizationRequired, .notAuthenticated:
            false
        case .unauthorized, .forbidden, .notFound, .rateLimited,
             .server, .decoding, .transport, .noSuitableDevice:
            true
        }
    }
}
