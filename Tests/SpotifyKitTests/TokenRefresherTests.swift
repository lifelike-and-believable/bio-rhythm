import Foundation
import Testing
import HRDJCore
import SpotifyKit

@Suite("Token refresh — SPEC.md §9.3")
struct TokenRefresherTests {
    @Test("A cached token is reused rather than refetched")
    func cachesUntilNearExpiry() async throws {
        let transport = FakeTransport()
        let refresher = makeRefresher(transport: transport, store: InMemoryTokenStore(refreshToken: "seed"))

        #expect(try await refresher.accessToken() == "access-1")
        #expect(try await refresher.accessToken() == "access-1")
        #expect(await transport.tokenRequests.count == 1)
    }

    @Test("Refresh happens 120 s early, not on expiry")
    func refreshesProactively() async throws {
        let clock = FakeClock()
        let transport = FakeTransport(tokenScript: [
            HTTPResponse(status: 200, body: Bodies.token(access: "access-1", expiresIn: 3600)),
            HTTPResponse(status: 200, body: Bodies.token(access: "access-2", expiresIn: 3600)),
        ])
        let refresher = makeRefresher(
            transport: transport,
            store: InMemoryTokenStore(refreshToken: "seed"),
            clock: clock
        )

        #expect(try await refresher.accessToken() == "access-1")

        // 3479 s in: 121 s of validity left, still inside the safe window.
        clock.advance(by: .seconds(3479))
        #expect(try await refresher.accessToken() == "access-1")

        // One more second and the remaining validity is under the 120 s floor.
        clock.advance(by: .seconds(1))
        #expect(try await refresher.accessToken() == "access-2")
        #expect(await transport.tokenRequests.count == 2)
    }

    @Test("Concurrent callers produce exactly one network refresh")
    func concurrentCallersShareOneRefresh() async throws {
        let transport = FakeTransport()
        let refresher = makeRefresher(transport: transport, store: InMemoryTokenStore(refreshToken: "seed"))

        // §9.3: concurrent 401s must not trigger parallel refreshes. Parallel
        // refreshes race to persist rotated tokens and the loser's token is
        // dead on the next session.
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await refresher.accessToken()
                }
            }
            for await token in group {
                #expect(token == "access-1")
            }
        }

        #expect(await transport.tokenRequests.count == 1)
        #expect(await refresher.refreshCount == 1)
    }

    @Test("Callers pile up behind an in-flight refresh instead of starting their own")
    func joinsInFlightRefresh() async throws {
        let transport = FakeTransport()
        let refresher = makeRefresher(transport: transport, store: InMemoryTokenStore(refreshToken: "seed"))

        // Hold the first refresh open so the others cannot be served from the
        // cache — without the gate this would pass even if `inFlight` were
        // removed, because whoever finished first would populate the cache.
        await transport.closeGate()
        async let first = refresher.accessToken()

        // Let the first caller reach the transport and block there.
        while await transport.tokenRequests.isEmpty {
            await Task.yield()
        }

        async let second = refresher.accessToken()
        async let third = refresher.accessToken()

        await transport.release()
        let tokens = try await [first, second, third]

        #expect(tokens == ["access-1", "access-1", "access-1"])
        #expect(await transport.tokenRequests.count == 1)
    }

    @Test("A rotated refresh token is persisted")
    func persistsRotatedToken() async throws {
        let store = InMemoryTokenStore(refreshToken: "seed")
        let transport = FakeTransport(tokenScript: [
            HTTPResponse(status: 200, body: Bodies.token(access: "access-1", refresh: "rotated")),
        ])
        let refresher = makeRefresher(transport: transport, store: store)

        _ = try await refresher.accessToken()

        // §9.1: Spotify may return a new refresh token on any refresh. Dropping
        // it locks the watch out at the next session start.
        #expect(try store.loadRefreshToken() == "rotated")
        #expect(store.saveCount == 1)
    }

    @Test("A response with no rotated token leaves the stored one alone")
    func keepsTokenWhenNotRotated() async throws {
        let store = InMemoryTokenStore(refreshToken: "seed")
        let refresher = makeRefresher(transport: FakeTransport(), store: store)

        _ = try await refresher.accessToken()

        #expect(try store.loadRefreshToken() == "seed")
        #expect(store.saveCount == 0)
    }

    @Test("invalid_grant clears the Keychain and asks for re-onboarding")
    func invalidGrantIsTerminal() async throws {
        let store = InMemoryTokenStore(refreshToken: "seed")
        let transport = FakeTransport(tokenScript: [
            HTTPResponse(status: 400, body: Bodies.invalidGrant),
        ])
        let refresher = makeRefresher(transport: transport, store: store)

        await #expect(throws: SpotifyError.self) {
            _ = try await refresher.accessToken()
        }

        #expect(try store.loadRefreshToken() == nil)
        #expect(store.clearCount == 1)
    }

    @Test("A device with no refresh token reports that it is not onboarded")
    func missingTokenIsNotAuthenticated() async throws {
        let refresher = makeRefresher(transport: FakeTransport(), store: InMemoryTokenStore())

        await #expect(throws: SpotifyError.self) {
            _ = try await refresher.accessToken()
        }
    }

    @Test("A failed refresh does not wedge the refresher")
    func recoversAfterFailure() async throws {
        let transport = FakeTransport(tokenScript: [
            HTTPResponse(status: 500, body: Data("upstream boom".utf8)),
            HTTPResponse(status: 200, body: Bodies.token(access: "access-2")),
        ])
        let refresher = makeRefresher(transport: transport, store: InMemoryTokenStore(refreshToken: "seed"))

        await #expect(throws: SpotifyError.self) {
            _ = try await refresher.accessToken()
        }
        // The in-flight task must have been cleared, or every later call would
        // await a task that already failed.
        #expect(try await refresher.accessToken() == "access-2")
    }
}
