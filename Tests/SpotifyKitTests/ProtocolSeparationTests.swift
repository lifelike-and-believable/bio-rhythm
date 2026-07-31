import Testing
import HRDJCore
import SpotifyKit

/// SPEC.md §5.3 / R-2 / invariant I6 — the never-interrupt guarantee.
///
/// The controller does not exist until M2, so these tests cover the mechanism
/// it will depend on rather than the controller itself. When `Controller`
/// lands, the I6 test belongs next to it and should assert the same thing
/// about its actual dependency — and it will be able to, because D-1 is now
/// settled and the protocols live in `HRDJCore` alongside the controller.
@Suite("Protocol separation")
struct ProtocolSeparationTests {
    private func makeClient(_ transport: FakeTransport) -> SpotifyPlayerClient {
        let clock = FakeClock()
        return SpotifyPlayerClient(
            player: PlayerAPI(
                api: SpotifyAPI(
                    transport: transport,
                    refresher: makeRefresher(
                        transport: transport,
                        store: InMemoryTokenStore(refreshToken: "seed"),
                        clock: clock
                    ),
                    limiter: RateLimiter(permitsPerMinute: 60, burst: 10, clock: clock)
                )
            )
        )
    }

    @Test("The narrow dependency exposes reading and queueing, and nothing else")
    func narrowDependencySurface() async throws {
        let transport = FakeTransport(script: [HTTPResponse(status: 204)])
        let dependency: any PlaybackReading & PlaybackQueueing = makeClient(transport)

        _ = try await dependency.playbackState()
        try await dependency.enqueue(TrackURI("spotify:track:x"))

        // Every one of these is a compile error through this type, which is
        // the entire mechanism. Uncomment any of them to see R-2 enforced:
        //
        //   try await dependency.pause()
        //   try await dependency.next()
        //   try await dependency.previous()
        //   try await dependency.seek(toMillis: 0)
        //   try await dependency.play(context: ContextURI("spotify:playlist:x"), shuffle: true)
        //
        // Two requests: the state read and the enqueue. Nothing else can be
        // spelled, so nothing else can be sent.
        #expect(await transport.apiRequests.count == 2)
    }

    @Test("The concrete client still conforms to all three protocols")
    func concreteClientConformsToAll() {
        // Typed as `Any` so the checks are dynamic; testing `is` against the
        // concrete type would just be the compiler agreeing with itself.
        let client: Any = makeClient(FakeTransport())
        #expect(client is any PlaybackReading)
        #expect(client is any PlaybackQueueing)
        // Manual UI view models need the transport surface (§11.2); it is the
        // controller, not the client, that must not see it.
        #expect(client is any PlaybackTransport)
    }

    @Test("The guarantee is static, not dynamic — a runtime cast still succeeds")
    func guaranteeIsCompileTimeOnly() {
        let dependency: any PlaybackReading & PlaybackQueueing = makeClient(FakeTransport())

        // SPEC.md §5.3 asks for "a unit test asserts the controller's
        // dependency type does not conform to PlaybackTransport". Taken
        // literally that test cannot pass and should not: the concrete client
        // conforms to all three by design, so the same object is reachable as
        // a transport through a dynamic cast. What R-2 actually rests on is
        // that control logic cannot *name* a transport method through its
        // declared dependency type.
        //
        // This assertion pins the current, expected state of affairs. If it
        // ever starts failing, someone has introduced a wrapper that closes
        // the dynamic hole too — which is an improvement, and the moment to
        // rewrite this test rather than delete it. See docs/verification.md.
        #expect((dependency as? any PlaybackTransport) != nil)
    }
}
