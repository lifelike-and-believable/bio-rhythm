import Foundation
import HRDJCore
import SpotifyKit

/// Duplicated from `HRDJCoreTests` on purpose. Shipping a fake clock inside the
/// HRDJCore library would put a test double in the production module, and a
/// shared test-support target is more machinery than twenty lines is worth.
final class FakeClock: HRDJCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Instant

    init(start: Instant = .reference) {
        self.current = start
    }

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        current = current + duration
    }
}

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(refreshToken: String? = nil) {
        self.token = refreshToken
    }

    func loadRefreshToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func save(refreshToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        token = refreshToken
        saveCount += 1
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        token = nil
        clearCount += 1
    }
}

/// Scripted HTTP, so nothing in these tests touches a network.
///
/// The response bodies used with it are written inline by the tests. That is
/// *not* a substitute for the captured fixtures CLAUDE.md requires: nothing
/// here asserts the shape of a Spotify player or playlist response. The bodies
/// are either empty, or the RFC 6749 token-endpoint shape, which is a standard
/// rather than something Spotify renamed. Decoding of `/v1/me/player` and
/// `/v1/playlists/{id}/items` is covered by `FixtureDecodingTests` and stays
/// pending until real captures land.
actor FakeTransport: HTTPTransport {
    static let accountsHost = "https://accounts.spotify.com"

    private var script: [HTTPResponse]
    private var tokenScript: [HTTPResponse]
    private var thrownError: (any Error)?
    private(set) var requests: [HTTPRequest] = []
    /// Held closed, every send suspends until `release()`. Used to keep a
    /// refresh in flight while other callers pile up behind it.
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateClosed = false

    /// `script` answers `api.spotify.com`; `tokenScript` answers the accounts
    /// service. Routing by host keeps API scripts from having to interleave the
    /// token refreshes that happen underneath them.
    init(
        script: [HTTPResponse] = [],
        tokenScript: [HTTPResponse] = [HTTPResponse(status: 200, body: Bodies.token(access: "access-1"))],
        throwing error: (any Error)? = nil
    ) {
        self.script = script
        self.tokenScript = tokenScript
        self.thrownError = error
    }

    var apiRequests: [HTTPRequest] {
        requests.filter { !$0.url.hasPrefix(Self.accountsHost) }
    }

    var tokenRequests: [HTTPRequest] {
        requests.filter { $0.url.hasPrefix(Self.accountsHost) }
    }

    func closeGate() {
        gateClosed = true
    }

    func release() {
        gateClosed = false
        let waiters = gateWaiters
        gateWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    var requestCount: Int { requests.count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)

        if gateClosed {
            await withCheckedContinuation { continuation in
                gateWaiters.append(continuation)
            }
        }

        if let thrownError {
            throw thrownError
        }

        if request.url.hasPrefix(Self.accountsHost) {
            return Self.next(from: &tokenScript)
        }
        return Self.next(from: &script)
    }

    /// Pops the next scripted response, holding the last one so a script can
    /// be shorter than the number of calls without falling off the end.
    private static func next(from script: inout [HTTPResponse]) -> HTTPResponse {
        if script.isEmpty {
            return HTTPResponse(status: 204)
        }
        if script.count == 1 {
            return script[0]
        }
        return script.removeFirst()
    }
}

enum Bodies {
    /// RFC 6749 §5.1 token response. Not a Spotify-specific shape.
    static func token(
        access: String,
        expiresIn: Int = 3600,
        refresh: String? = nil
    ) -> Data {
        var fields = ["\"access_token\":\"\(access)\"", "\"token_type\":\"Bearer\"", "\"expires_in\":\(expiresIn)"]
        if let refresh {
            fields.append("\"refresh_token\":\"\(refresh)\"")
        }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    static let invalidGrant = Data(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8)
}

func makeRefresher(
    transport: FakeTransport,
    store: InMemoryTokenStore,
    clock: FakeClock = FakeClock()
) -> TokenRefresher {
    let client = AuthorizationClient(
        configuration: SpotifyAuthConfiguration(
            clientID: "test-client",
            redirectURI: "biorhythm://callback"
        ),
        transport: transport
    )
    return TokenRefresher(client: client, store: store, clock: clock)
}
