import Foundation
import Testing
import HRDJCore
import SpotifyKit

@Suite("Request machinery and status mapping — SPEC.md §11.4")
struct SpotifyAPITests {
    private func makeAPI(
        transport: FakeTransport,
        clock: FakeClock = FakeClock()
    ) -> (SpotifyAPI, RateLimiter) {
        let limiter = RateLimiter(permitsPerMinute: 60, burst: 10, clock: clock)
        let api = SpotifyAPI(
            transport: transport,
            refresher: makeRefresher(
                transport: transport,
                store: InMemoryTokenStore(refreshToken: "seed"),
                clock: clock
            ),
            limiter: limiter
        )
        return (api, limiter)
    }

    @Test("Requests carry a bearer token")
    func sendsBearerToken() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 204)])
        let (api, _) = makeAPI(transport: transport)

        _ = try await api.send(method: "GET", path: "/v1/me/player")

        let request = try #require(await transport.apiRequests.first)
        #expect(request.headers["Authorization"] == "Bearer access-1")
        #expect(request.url == "https://api.spotify.com/v1/me/player")
    }

    @Test("Query parameters are appended")
    func buildsQuery() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 204)])
        let (api, _) = makeAPI(transport: transport)

        _ = try await api.send(
            method: "POST",
            path: "/v1/me/player/queue",
            query: ["uri": "spotify:track:4iV5W9uYEdYUVa79Axb7Rh"]
        )

        let request = try #require(await transport.apiRequests.first)
        #expect(request.url.hasPrefix("https://api.spotify.com/v1/me/player/queue?uri="))
        #expect(request.url.contains("4iV5W9uYEdYUVa79Axb7Rh"))
    }

    @Test("A 401 forces one refresh and one retry")
    func retriesOnceAfter401() async throws {
        let transport = FakeTransport(script: [
            HTTPResponse(status: 401),
            HTTPResponse(status: 204),
        ])
        let (api, _) = makeAPI(transport: transport)

        let response = try await api.send(method: "GET", path: "/v1/me/player")

        #expect(response.status == 204)
        #expect(await transport.apiRequests.count == 2)
        // One token call to get started, one forced refresh after the 401.
        #expect(await transport.tokenRequests.count == 2)
    }

    @Test("A second 401 is a real authorization failure, not a stale token")
    func doesNotRetryTwice() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 401)])
        let (api, _) = makeAPI(transport: transport)

        await #expect(throws: SpotifyError.self) {
            _ = try await api.send(method: "GET", path: "/v1/me/player")
        }
        #expect(await transport.apiRequests.count == 2)
    }

    @Test("403 carries the body, because Premium lapse and scope errors read differently")
    func forbiddenKeepsBody() async throws {
        let transport = FakeTransport(script: [
            HTTPResponse(status: 403, body: Data("Player command failed: Premium required".utf8)),
        ])
        let (api, _) = makeAPI(transport: transport)

        let error = await #expect(throws: SpotifyError.self) {
            _ = try await api.send(method: "GET", path: "/v1/me/player")
        }
        guard case .forbidden(let body) = try #require(error as? SpotifyError) else {
            Issue.record("expected .forbidden, got \(String(describing: error))")
            return
        }
        #expect(body.contains("Premium required"))
    }

    @Test("404 maps to notFound — on a player write this means no active device")
    func notFound() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 404)])
        let (api, _) = makeAPI(transport: transport)

        let error = await #expect(throws: SpotifyError.self) {
            _ = try await api.send(method: "POST", path: "/v1/me/player/queue")
        }
        guard case .notFound = try #require(error as? SpotifyError) else {
            Issue.record("expected .notFound, got \(String(describing: error))")
            return
        }
    }

    @Test("429 surfaces Retry-After and pauses every later caller")
    func rateLimited() async throws {
        let transport = FakeTransport(script: [
            HTTPResponse(status: 429, headers: ["Retry-After": "12"]),
        ])
        let (api, limiter) = makeAPI(transport: transport)

        let error = await #expect(throws: SpotifyError.self) {
            _ = try await api.send(method: "GET", path: "/v1/me/player")
        }
        guard case .rateLimited(let retryAfter) = try #require(error as? SpotifyError) else {
            Issue.record("expected .rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retryAfter == .seconds(12))

        // §9.4: the pause applies to the whole client, not just the caller
        // that happened to receive the 429.
        #expect(await limiter.reserve() == .seconds(12))
    }

    @Test("Retry-After is matched case-insensitively")
    func retryAfterHeaderCasing() {
        let response = HTTPResponse(status: 429, headers: ["retry-after": "7"])
        #expect(response.retryAfter == .seconds(7))
        #expect(response.header("Retry-After") == "7")
    }

    @Test("5xx keeps the status for the log")
    func serverError() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 502, body: Data("bad gateway".utf8))])
        let (api, _) = makeAPI(transport: transport)

        let error = await #expect(throws: SpotifyError.self) {
            _ = try await api.send(method: "GET", path: "/v1/me/player")
        }
        guard case .server(let status, _) = try #require(error as? SpotifyError) else {
            Issue.record("expected .server, got \(String(describing: error))")
            return
        }
        #expect(status == 502)
    }

    @Test("Only network-shaped failures count toward DEGRADED")
    func degradedClassification() {
        // §7.4 enters DEGRADED after three consecutive failures and backs off.
        // A dead grant needs re-onboarding instead, and backing off would just
        // hide it.
        #expect(SpotifyError.server(status: 500, body: "").countsTowardDegraded)
        #expect(SpotifyError.rateLimited(retryAfter: nil).countsTowardDegraded)
        #expect(SpotifyError.notFound(body: "").countsTowardDegraded)
        #expect(SpotifyError.forbidden(body: "").countsTowardDegraded)
        #expect(SpotifyError.reauthorizationRequired.countsTowardDegraded == false)
        #expect(SpotifyError.notAuthenticated.countsTowardDegraded == false)
    }
}
