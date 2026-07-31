// Standard library only. See CLAUDE.md §2.

/// Randomness, injected. SPEC.md §8 wants uniform random selection; a test
/// wants to know which track it will get.
///
/// Deliberately not `RandomNumberGenerator`. The stdlib protocol has to be
/// passed `inout` to a generic parameter, which an existential stored on an
/// actor cannot satisfy without gymnastics. This is three lines and does the
/// one job §8 needs.
public protocol RandomSource: Sendable {
    /// Uniform in `0..<upperBound`. Never called with a bound below 1.
    mutating func next(upperBound: Int) -> Int
}

public struct SystemRandomSource: RandomSource {
    public init() {}
    public mutating func next(upperBound: Int) -> Int {
        Int.random(in: 0..<Swift.max(1, upperBound))
    }
}

/// The result of a selection, with enough context to log it honestly.
///
/// `pool` is the pool the track actually came from, which is not always the one
/// asked for — §8's exhaustion path falls back one zone toward Z2. Logging the
/// requested pool in that case would put a Z4 label on a Z3 track and quietly
/// corrupt the tuning data M2 exists to collect.
public struct PoolSelection: Hashable, Sendable {
    public let track: TrackRef
    public let pool: PoolID
    /// Set when §8's fallback fired. Nil on the ordinary path.
    public let fellBackFrom: PoolID?
    /// Set when the played-set had to be cleared to find a candidate.
    public let clearedPlayedSet: Bool

    public init(
        track: TrackRef,
        pool: PoolID,
        fellBackFrom: PoolID? = nil,
        clearedPlayedSet: Bool = false
    ) {
        self.track = track
        self.pool = pool
        self.fellBackFrom = fellBackFrom
        self.clearedPlayedSet = clearedPlayedSet
    }
}

/// Pool contents and selection. SPEC.md §8.
///
/// An actor because the played-set is session-wide mutable state read from the
/// control loop, and because §7.4 refills pools at session start while the loop
/// may already be running.
///
/// ## What it does not do
///
/// No fetching. `HRDJCore` cannot reach the network (CLAUDE.md #2), so the app
/// layer fetches `/v1/playlists/{id}/items`, applies §8's wire-level filters —
/// `item == nil`, `type != "track"`, `is_local`, `is_playable == false`, all of
/// which are properties of the response rather than of the control law — and
/// hands the survivors here with `load(_:into:)`.
///
/// The blocklist (R-11) is applied here rather than on ingest, because it
/// changes mid-session when the owner long-presses a track and the pools do
/// not get refetched for it.
public actor PoolManager: PoolSelecting {
    private var pools: [PoolID: [TrackRef]] = [:]
    /// Session-wide. §8: a track played from Z2 is ineligible in Z3 for the
    /// rest of the session, so eligibility is keyed by URI and not by pool.
    private var playedURIs: Set<String> = []
    /// Which pool each played URI was actually played *from*.
    ///
    /// Provenance, not membership. Recycling one pool must not free a track
    /// that was played from another, and current pool contents cannot answer
    /// that question: a track present in both Z2 and Z3 looks identical from
    /// either side. Inferring provenance from membership silently punched a
    /// hole in the cross-pool deduplication — a track played from Z2 became
    /// eligible again the moment Z3 was exhausted.
    private var playedByPool: [PoolID: Set<String>] = [:]
    private var blocklist: Set<String>
    private var random: any RandomSource

    public init(
        blocklist: Set<String> = [],
        random: any RandomSource = SystemRandomSource()
    ) {
        self.blocklist = blocklist
        self.random = random
    }

    // MARK: - Contents

    /// Replaces a pool's contents. §4.5: fetched fresh every session and never
    /// persisted, because Prompted Playlists can auto-refresh underneath us.
    public func load(_ tracks: [TrackRef], into pool: PoolID) {
        pools[pool] = tracks
    }

    public func loadedPools() -> Set<PoolID> {
        Set(pools.keys.filter { !(pools[$0]?.isEmpty ?? true) })
    }

    public func count(in pool: PoolID) -> Int {
        pools[pool]?.count ?? 0
    }

    /// R-11. Takes effect immediately and survives the played-set being
    /// cleared, which is the difference between a blocklist and a played-set.
    public func block(_ uri: String) {
        blocklist.insert(uri)
    }

    public func markPlayed(_ uri: String, from pool: PoolID) {
        playedURIs.insert(uri)
        playedByPool[pool, default: []].insert(uri)
    }

    public func playedCount() -> Int { playedURIs.count }

    // MARK: - §8 selection

    public func selectTrack(from pool: PoolID, avoidingArtists: [String]) async throws -> PoolSelection? {
        select(from: pool, avoidingArtists: avoidingArtists)
    }

    /// The same thing without the `async throws` the protocol needs. Selection
    /// touches nothing that can fail or suspend, and tests read better for it.
    public func select(from pool: PoolID, avoidingArtists: [String]) -> PoolSelection? {
        if let track = pick(from: pool, avoidingArtists: avoidingArtists) {
            markPlayed(track.uri, from: pool)
            return PoolSelection(track: track, pool: pool)
        }

        // §8 exhaustion, step one: clear the played entries belonging to *this
        // pool only*. Scoped deliberately — clearing the whole set would make
        // tracks eligible again in pools the owner has not exhausted, and the
        // cross-pool deduplication is the point of a session-wide set.
        let cleared = clearPlayed(for: pool)
        if cleared, let track = pick(from: pool, avoidingArtists: avoidingArtists) {
            markPlayed(track.uri, from: pool)
            return PoolSelection(track: track, pool: pool, clearedPlayedSet: true)
        }

        // §8 exhaustion, step two: fall back one zone toward Z2 and warn. Only
        // one step — a cascade would silently drag a Z4 effort down to Z2 while
        // reporting nothing louder than a warning per hop.
        guard let neighbour = fallbackPool(from: pool) else { return nil }
        _ = clearPlayed(for: neighbour)
        guard let track = pick(from: neighbour, avoidingArtists: avoidingArtists) else {
            return nil
        }
        markPlayed(track.uri, from: neighbour)
        return PoolSelection(track: track, pool: neighbour, fellBackFrom: pool)
    }

    /// Uniform random from the eligible candidates, preferring those that do
    /// not repeat a recent primary artist.
    ///
    /// §8 is careful about the artist rule: "if an alternative exists". It is a
    /// preference, not a filter. Applying it as a filter would turn a pool with
    /// one artist into an exhausted pool, which is a much worse outcome than
    /// hearing them twice.
    private func pick(from pool: PoolID, avoidingArtists: [String]) -> TrackRef? {
        let eligible = (pools[pool] ?? []).filter {
            !playedURIs.contains($0.uri) && !blocklist.contains($0.uri)
        }
        guard !eligible.isEmpty else { return nil }

        let avoided = Set(avoidingArtists)
        let unclustered = eligible.filter { !avoided.contains($0.primaryArtist) }
        let candidates = unclustered.isEmpty ? eligible : unclustered

        return candidates[random.next(upperBound: candidates.count)]
    }

    /// Frees the tracks that were played *from* this pool. Returns whether
    /// anything was actually removed, so a caller cannot mistake "cleared
    /// nothing" for a fresh start.
    ///
    /// Keyed on provenance rather than on current membership. Those differ
    /// exactly when a track sits in two pools, which §8 says to expect — and
    /// in that case membership frees a track the owner has not yet exhausted
    /// the pool of.
    @discardableResult
    private func clearPlayed(for pool: PoolID) -> Bool {
        guard let uris = playedByPool[pool], !uris.isEmpty else { return false }
        playedURIs.subtract(uris)
        playedByPool[pool] = []
        return true
    }

    /// One zone toward Z2, §8's "fall back one zone toward Z2". Z2 itself has
    /// nowhere to fall back to, which is the correct end of the line: it is the
    /// zone the fallback context already plays (§7.3).
    private func fallbackPool(from pool: PoolID) -> PoolID? {
        let here = pool.zone.rawValue
        let target = Zone.z2.rawValue
        guard here != target else { return nil }
        let step = here < target ? 1 : -1
        return Zone(rawValue: here + step)?.poolID
    }
}
