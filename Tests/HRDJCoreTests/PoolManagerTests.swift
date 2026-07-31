import Testing
import HRDJCore

/// SPEC.md §8.
@Suite("Pool manager — SPEC.md §8")
struct PoolManagerTests {
    /// Deterministic: always takes the first candidate, so a test can say which
    /// track it expects. Uniformity is §8's requirement of the *source*, not of
    /// this type's arithmetic.
    struct FirstChoice: RandomSource {
        mutating func next(upperBound: Int) -> Int { 0 }
    }

    /// Walks the candidate list, so successive calls take successive tracks.
    struct RoundRobin: RandomSource {
        var calls = 0
        mutating func next(upperBound: Int) -> Int {
            defer { calls += 1 }
            return calls % Swift.max(1, upperBound)
        }
    }

    private func track(_ id: String, artist: String = "Artist") -> TrackRef {
        TrackRef(
            id: id,
            uri: "spotify:track:\(id)",
            title: id,
            primaryArtist: artist,
            durationMillis: 200_000
        )
    }

    private func manager(random: any RandomSource = FirstChoice()) -> PoolManager {
        PoolManager(random: random)
    }

    // MARK: - Selection

    @Test("Selects from the requested pool")
    func selectsFromPool() async {
        let manager = self.manager()
        await manager.load([track("a"), track("b")], into: .z3)

        let selection = await manager.select(from: .z3, avoidingArtists: [])
        #expect(selection?.track.id == "a")
        #expect(selection?.pool == .z3)
        #expect(selection?.fellBackFrom == nil)
    }

    @Test("An empty pool with nowhere to fall back to returns nothing")
    func emptyPool() async {
        let manager = self.manager()
        let selection = await manager.select(from: .z2, avoidingArtists: [])
        #expect(selection == nil)
    }

    // MARK: - The played set

    @Test("A selected track is not offered again")
    func playedSetExcludes() async {
        let manager = self.manager()
        await manager.load([track("a"), track("b")], into: .z3)

        #expect(await manager.select(from: .z3, avoidingArtists: [])?.track.id == "a")
        #expect(await manager.select(from: .z3, avoidingArtists: [])?.track.id == "b")
    }

    @Test("The played set spans pools, so a Z2 track is ineligible in Z3")
    func playedSetIsSessionWide() async {
        let manager = self.manager()
        let shared = track("shared")
        await manager.load([shared], into: .z2)
        await manager.load([shared, track("z3only")], into: .z3)

        #expect(await manager.select(from: .z2, avoidingArtists: [])?.track.id == "shared")
        // §8: "a track played from Z2 is ineligible in Z3 for the rest of the
        // session". Without this, tracks in two Prompted Playlists get played
        // twice a session and the pools are effectively smaller than they look.
        #expect(await manager.select(from: .z3, avoidingArtists: [])?.track.id == "z3only")
    }

    // MARK: - §8 exhaustion

    @Test("An exhausted pool clears its own played entries and reselects")
    func exhaustionClearsScoped() async {
        let manager = self.manager()
        await manager.load([track("a")], into: .z3)
        await manager.load([track("x")], into: .z2)

        #expect(await manager.select(from: .z3, avoidingArtists: [])?.track.id == "a")
        #expect(await manager.select(from: .z2, avoidingArtists: [])?.track.id == "x")

        let recycled = await manager.select(from: .z3, avoidingArtists: [])
        #expect(recycled?.track.id == "a")
        #expect(recycled?.clearedPlayedSet == true)
        #expect(recycled?.pool == .z3)
    }

    @Test("Clearing is scoped to the exhausted pool, not the whole session")
    func clearingIsScoped() async {
        // Z2 and Z3 share a track. Exhausting Z3 must not make it eligible in
        // Z2 again — the cross-pool deduplication is the point of a
        // session-wide set, and a global clear would undo it.
        let manager = self.manager()
        let shared = track("shared")
        await manager.load([shared], into: .z2)
        await manager.load([track("z3only")], into: .z3)

        #expect(await manager.select(from: .z2, avoidingArtists: [])?.track.id == "shared")
        #expect(await manager.select(from: .z3, avoidingArtists: [])?.track.id == "z3only")

        // Exhaust Z3 and force a clear.
        _ = await manager.select(from: .z3, avoidingArtists: [])
        // `shared` belongs to Z2, so Z3's clear must have left it played.
        let z2 = await manager.select(from: .z2, avoidingArtists: [])
        #expect(z2?.clearedPlayedSet == true)
    }

    @Test("A truly empty pool falls back one zone toward Z2 and says so")
    func fallsBackTowardZ2() async {
        let manager = self.manager()
        await manager.load([track("hard")], into: .z3)
        // Z4 is configured but empty — the Prompted Playlist returned nothing.

        let selection = await manager.select(from: .z4, avoidingArtists: [])
        #expect(selection?.track.id == "hard")
        #expect(selection?.pool == .z3)
        #expect(selection?.fellBackFrom == .z4)
    }

    @Test("The fallback runs upward from below Z2 as well")
    func fallsBackUpwardFromMeditation() async {
        let manager = self.manager()
        await manager.load([track("recovery")], into: .z1)

        let selection = await manager.select(from: .z0, avoidingArtists: [])
        #expect(selection?.pool == .z1)
        #expect(selection?.fellBackFrom == .z0)
    }

    @Test("The fallback is one hop, never a cascade")
    func fallbackIsOneHop() async {
        // Only Z2 has anything. Z4 falls back to Z3, finds it empty, and stops
        // — a cascade would drag a maximum effort down to aerobic while
        // reporting nothing louder than a warning per hop.
        let manager = self.manager()
        await manager.load([track("aerobic")], into: .z2)

        #expect(await manager.select(from: .z4, avoidingArtists: []) == nil)
    }

    @Test("Z2 has nowhere to fall back to")
    func z2IsTheEndOfTheLine() async {
        let manager = self.manager()
        await manager.load([track("x")], into: .z3)
        #expect(await manager.select(from: .z2, avoidingArtists: []) == nil)
    }

    // MARK: - Artist clustering

    @Test("A recent artist is avoided when an alternative exists")
    func avoidsRecentArtist() async {
        let manager = self.manager()
        await manager.load(
            [track("a", artist: "Repeat"), track("b", artist: "Fresh")],
            into: .z3
        )

        let selection = await manager.select(from: .z3, avoidingArtists: ["Repeat"])
        #expect(selection?.track.primaryArtist == "Fresh")
    }

    @Test("A single-artist pool still yields a track rather than starving")
    func artistRuleIsAPreference() async {
        // §8: "if an alternative exists". Applied as a filter, a pool the owner
        // built around one artist would look exhausted. Hearing them twice is
        // a much better outcome than hearing nothing.
        let manager = self.manager()
        await manager.load(
            [track("a", artist: "Only"), track("b", artist: "Only")],
            into: .z3
        )

        let selection = await manager.select(from: .z3, avoidingArtists: ["Only"])
        #expect(selection?.track.primaryArtist == "Only")
    }

    // MARK: - Blocklist

    @Test("A blocked track is never selected, even after a played-set clear")
    func blocklist() async {
        let manager = self.manager()
        await manager.load([track("bad"), track("good")], into: .z3)
        await manager.block("spotify:track:bad")

        #expect(await manager.select(from: .z3, avoidingArtists: [])?.track.id == "good")

        // Exhaustion clears the played set; it must not clear the blocklist.
        // That difference is the whole reason R-11 is not just "mark played".
        let recycled = await manager.select(from: .z3, avoidingArtists: [])
        #expect(recycled?.track.id == "good")
    }

    @Test("Blocking mid-session takes effect without a refetch")
    func blockingMidSession() async {
        let manager = self.manager()
        await manager.load([track("a"), track("b")], into: .z3)
        await manager.block("spotify:track:a")
        #expect(await manager.select(from: .z3, avoidingArtists: [])?.track.id == "b")
    }

    // MARK: - As the controller sees it

    @Test("The protocol conformance returns the track the full API selects")
    func protocolConformance() async throws {
        let manager = self.manager()
        await manager.load([track("a")], into: .z3)
        let selection = try await manager.selectTrack(from: .z3, avoidingArtists: [])
        #expect(selection?.track.id == "a")
    }

    @Test("A whole session drains a pool without repeating a track")
    func noRepeatsWithinAPool() async {
        let manager = self.manager(random: RoundRobin())
        let tracks = (0..<30).map { track("t\($0)", artist: "A\($0 % 7)") }
        await manager.load(tracks, into: .z3)

        var seen: Set<String> = []
        for _ in 0..<30 {
            guard let selection = await manager.select(from: .z3, avoidingArtists: Array(seen.prefix(2))) else {
                Issue.record("pool ran dry before it was drained")
                return
            }
            #expect(seen.contains(selection.track.uri) == false)
            #expect(selection.clearedPlayedSet == false)
            seen.insert(selection.track.uri)
        }
        #expect(seen.count == 30)

        // The 31st has to recycle.
        let extra = await manager.select(from: .z3, avoidingArtists: [])
        #expect(extra?.clearedPlayedSet == true)
    }
}
