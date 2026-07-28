import HRDJCore

/// Holds the current access token and refreshes it. SPEC.md §9.3.
///
/// Two requirements shape this type:
///
/// - Refresh happens proactively at `expires_in - 120 s`, not reactively on a
///   401. A 401 in the middle of a commit window costs an attempt.
/// - Refreshes are serialised. Concurrent callers that all find the token
///   stale must produce exactly one network refresh, not one each — the
///   accounts service rotates refresh tokens, and parallel refreshes race to
///   persist different ones.
public actor TokenRefresher {
    public struct AccessToken: Sendable {
        public let value: String
        public let expiresAt: Instant
    }

    private let client: AuthorizationClient
    private let store: any TokenStore
    private let clock: any HRDJCore.Clock
    private let earlyRefresh: Duration

    private var cached: AccessToken?
    private var inFlight: Task<AccessToken, any Error>?

    /// Number of network refreshes performed. Test observability for the
    /// single-flight requirement; also worth logging at session end.
    public private(set) var refreshCount = 0

    public init(
        client: AuthorizationClient,
        store: any TokenStore,
        clock: any HRDJCore.Clock = SystemClock(),
        earlyRefresh: Duration = .seconds(120)
    ) {
        self.client = client
        self.store = store
        self.clock = clock
        self.earlyRefresh = earlyRefresh
    }

    /// A token guaranteed to be valid for at least `earlyRefresh` longer.
    public func accessToken() async throws -> String {
        if let cached, cached.expiresAt - earlyRefresh > clock.now {
            return cached.value
        }
        return try await performRefresh().value
    }

    /// Drops `token` if it is the one currently cached, so the next
    /// `accessToken()` refreshes. Used by the single 401 retry in `SpotifyAPI`.
    public func invalidate(_ token: String) {
        if cached?.value == token {
            cached = nil
        }
    }

    public func forceRefresh() async throws -> String {
        cached = nil
        return try await performRefresh().value
    }

    private func performRefresh() async throws -> AccessToken {
        // A refresh already in flight: join it rather than starting another.
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<AccessToken, any Error> { [client, store, clock] in
            guard let refreshToken = try store.loadRefreshToken() else {
                throw SpotifyError.notAuthenticated
            }
            let grant = try await client.refresh(refreshToken: refreshToken)
            // §9.1: Spotify may rotate the refresh token. Persist it whenever
            // one comes back, or the next session is locked out.
            if let rotated = grant.refreshToken {
                try store.save(refreshToken: rotated)
            }
            return AccessToken(
                value: grant.accessToken,
                expiresAt: clock.now + .seconds(grant.expiresIn)
            )
        }
        inFlight = task
        refreshCount += 1

        do {
            let token = try await task.value
            cached = token
            inFlight = nil
            return token
        } catch {
            inFlight = nil
            cached = nil
            if let spotify = error as? SpotifyError, case .reauthorizationRequired = spotify {
                // §9.3: the grant is dead. Clear it so the UI can route to
                // re-onboarding instead of retrying a token that cannot work.
                try? store.clear()
            }
            throw error
        }
    }
}
