// Standard library only. See CLAUDE.md §2.

/// Track selection, as much of §8 as the controller needs to name.
///
/// `PoolManager` conforms to this. Declared here rather than there for the same
/// reason the playback protocols are (D-1): the controller has to name its own
/// dependency, and a protocol is the only shape that lets the pool
/// implementation change — or be faked in a test — without the control loop
/// knowing.
public protocol PoolSelecting: Sendable {
    /// A track from `pool` that has not been played this session.
    ///
    /// `avoidingArtists` carries §8's secondary rule: avoid the primary artist
    /// of the two previously played tracks *if an alternative exists*. It is a
    /// preference, not a filter — returning a clustered track beats returning
    /// nothing.
    ///
    /// Nil means the pool is exhausted and could not be replenished, which the
    /// controller logs as `pool_starvation`.
    func selectTrack(from pool: PoolID, avoidingArtists: [String]) async throws -> PoolSelection?
}

/// Where §11.3 records go. The app layer writes JSONL; tests collect in memory.
public protocol DecisionRecording: Sendable {
    func record(_ decision: Decision) async
}

/// The observe-only control loop. SPEC.md §7, wired from §6.
///
/// ## Its dependency cannot express a skip
///
/// `playback` is declared as `PlaybackReading & PlaybackQueueing` and nothing
/// else. `pause`, `next`, `previous` and `seek` are not merely unused here —
/// they are unnameable, because the composition does not carry them. That is
/// invariant I6 and requirement R-2, and it is why the type of this one stored
/// property matters more than any amount of care in the method bodies.
///
/// ## M2 is observe-only, and that is a constructor argument
///
/// With `actuationEnabled` false — the default, and what M2 ships — every
/// decision is computed and logged exactly as it would be, and the `enqueue`
/// is not issued. The log therefore describes the system that M3 will turn on,
/// which is the whole point of §13's "do not compress M2": the §6.7 constants
/// get tuned against these traces before the loop is allowed to drive
/// anything.
///
/// The flag gates one statement. Everything upstream of it — the window, the
/// zone model, the boundary estimate, the commit schedule, the selection —
/// runs identically either way, so the traces are not a simulation of the real
/// thing, they *are* the real thing minus its last step.
public actor Controller {
    private let playback: any PlaybackReading & PlaybackQueueing
    private let pools: any PoolSelecting
    private let sink: any DecisionRecording
    private let clock: any HRDJCore.Clock
    public let configuration: ControlConfiguration
    public let actuationEnabled: Bool

    public private(set) var window: HRWindow
    public private(set) var zoneModel: ZoneModel
    public private(set) var trackClock: TrackClock
    public private(set) var scheduler: CommitScheduler

    /// §7.4: DEGRADED after this many consecutive network failures.
    public private(set) var consecutiveFailures: Int = 0
    public private(set) var isDegraded: Bool = false

    /// Primary artists of the last two committed tracks, newest first (§8).
    private var recentArtists: [String] = []
    /// So `zone_change` is logged on the edge rather than on every tick.
    private var lastLoggedZone: Zone?

    public init(
        playback: any PlaybackReading & PlaybackQueueing,
        pools: any PoolSelecting,
        sink: any DecisionRecording,
        clock: any HRDJCore.Clock,
        configuration: ControlConfiguration,
        actuationEnabled: Bool = false
    ) {
        self.playback = playback
        self.pools = pools
        self.sink = sink
        self.clock = clock
        self.configuration = configuration
        self.actuationEnabled = actuationEnabled
        self.window = HRWindow(configuration: configuration)
        self.zoneModel = ZoneModel(configuration: configuration)
        self.trackClock = TrackClock()
        self.scheduler = CommitScheduler(configuration: configuration)
    }

    // MARK: - Heart rate

    /// Feeds one sample. Called from the HealthKit delegate at roughly 1 Hz,
    /// which is far more often than `tick()` runs — the window is the buffer
    /// between the two rates.
    public func ingest(_ sample: HRSample) {
        window.insert(sample)
    }

    // MARK: - Session lifecycle

    public func start() async {
        await sink.record(Decision(at: clock.now, event: .sessionStart))
    }

    public func stop() async {
        await sink.record(Decision(at: clock.now, event: .sessionEnd))
        trackClock.reset()
        scheduler.reset()
        window.removeAll()
    }

    // MARK: - §6.6 manual input

    /// A manual skip, pause/resume, or zone change was detected. Suspends
    /// auto-control for `OVERRIDE_HOLD`.
    public func registerManualInput(zone: Zone? = nil) async {
        let now = clock.now
        if let zone {
            zoneModel.lockZone(zone, at: now)
        } else {
            zoneModel.beginOverride(at: now)
        }
        var record = Decision(at: now, event: .overrideSet)
        record.currentZone = zoneModel.currentZone
        record.overrideActive = true
        await sink.record(record)
    }

    public func resumeAuto() async {
        zoneModel.resumeAuto()
        var record = Decision(at: clock.now, event: .overrideCleared)
        record.overrideActive = false
        await sink.record(record)
    }

    // MARK: - The loop

    /// One pass. Returns how long to wait before the next one.
    ///
    /// Poll-driven rather than timer-driven: §7.1's schedule is expressed as
    /// "when should I next look", and `CommitScheduler.nextEvaluation` answers
    /// exactly that. The caller sleeps and calls back.
    @discardableResult
    public func tick() async -> Duration {
        let now = clock.now

        let state: PlaybackState
        do {
            state = try await playback.playbackState()
        } catch {
            return await handleFailure(at: now)
        }
        await clearDegradedIfNeeded(at: now)

        let observation = trackClock.observe(state, at: now)
        if case .started(let trackID) = observation.kind {
            scheduler.trackChanged(
                to: trackID,
                remaining: trackClock.remaining(at: now),
                at: now
            )
        }

        await advanceZone(at: now)
        await evaluateCommit(observation: observation, at: now)

        return scheduler.nextEvaluation(remaining: trackClock.remaining(at: now), at: now)
            ?? configuration.heartbeatPoll
    }

    // MARK: - Steps

    private func advanceZone(at now: Instant) async {
        let observed = window.observedHR(at: now)
        let before = zoneModel.currentZone
        zoneModel.observe(hr: observed, at: now)

        guard observed != nil else {
            // §6.2/§11.4: the zone is held, and the gap is worth a line — a
            // trace with no HR and no explanation is unreadable later.
            await sink.record(baseRecord(event: .hrSampleGap, at: now))
            return
        }

        // Logged on the edge, not on every tick. `currentZone` moves only at a
        // commit, so this fires once per actual change.
        let current = zoneModel.currentZone
        guard current != before else { return }
        lastLoggedZone = current
        await sink.record(baseRecord(event: .zoneChange, at: now))
    }

    private func evaluateCommit(observation: TrackClock.Observation, at now: Instant) async {
        let remaining = trackClock.remaining(at: now)
        let decision = scheduler.decision(
            remaining: remaining,
            isPlaying: trackClock.isPlaying,
            at: now
        )

        switch decision {
        case .wait:
            return

        case .abandon:
            scheduler.recordAbandon(at: now)
            var record = baseRecord(event: .commitMiss, at: now)
            record.outcome = .failure
            record.attempt = scheduler.attempts
            await sink.record(record)

        case .attempt(let number):
            await attemptCommit(number: number, observation: observation, at: now)
        }
    }

    private func attemptCommit(
        number: Int,
        observation: TrackClock.Observation,
        at now: Instant
    ) async {
        guard let target = zoneModel.targetZone(at: now) else { return }
        let pool = target.poolID

        let selection: TrackRef?
        do {
            selection = try await pools.selectTrack(from: pool, avoidingArtists: recentArtists)
        } catch {
            scheduler.recordAttempt(at: now)
            scheduler.recordFailure(at: now)
            var record = baseRecord(event: .commit, at: now)
            record.attempt = number
            record.outcome = .failure
            record.targetZone = target
            record.selectedFromPool = pool
            record.estimatedEndDriftMillis = observation.drift.map { Int($0.inSeconds * 1000) }
            await sink.record(record)
            return
        }

        guard let chosen = selection else {
            // Consumes a slot rather than retrying on the spot. An exhausted
            // pool does not refill between two polls a second apart, and
            // `nextEvaluation` would otherwise return .zero forever — a tight
            // loop hammering §8's selection for the rest of the window.
            scheduler.recordAttempt(at: now)
            scheduler.recordFailure(at: now)
            var record = baseRecord(event: .poolStarvation, at: now)
            record.attempt = number
            record.outcome = .failure
            record.targetZone = target
            record.selectedFromPool = pool
            await sink.record(record)
            return
        }

        scheduler.recordAttempt(at: now)

        // §8: a fallback is a successful selection that still deserves a
        // warning. Logged as its own record so the commit line stays a commit
        // line and the starvation is greppable on its own.
        if let starved = chosen.fellBackFrom {
            var warning = baseRecord(event: .poolStarvation, at: now)
            warning.targetZone = target
            warning.selectedFromPool = starved
            await sink.record(warning)
        }

        var record = baseRecord(event: .commit, at: now)
        record.attempt = number
        record.targetZone = target
        // The pool the track actually came from, which is not always the one
        // asked for. Logging the request would put a Z4 label on a Z3 track.
        record.selectedFromPool = chosen.pool
        record.selectedURI = chosen.track.uri
        record.estimatedEndDriftMillis = observation.drift.map { Int($0.inSeconds * 1000) }

        guard actuationEnabled else {
            // M2. The decision is real and logged; only the write is withheld.
            // `skipped` rather than `success` so a trace cannot be mistaken for
            // one where the queue was actually touched.
            record.outcome = .skipped
            scheduler.recordSuccess(at: now)
            zoneModel.recordCommit(at: now)
            noteArtist(chosen.track.primaryArtist)
            await sink.record(record)
            return
        }

        do {
            try await playback.enqueue(TrackURI(chosen.track.uri))
            record.outcome = .success
            scheduler.recordSuccess(at: now)
            zoneModel.recordCommit(at: now)
            noteArtist(chosen.track.primaryArtist)
            consecutiveFailures = 0
        } catch {
            record.outcome = .failure
            scheduler.recordFailure(at: now)
        }
        await sink.record(record)
    }

    // MARK: - §7.4 DEGRADED

    private func handleFailure(at now: Instant) async -> Duration {
        consecutiveFailures += 1
        if !isDegraded, consecutiveFailures >= 3 {
            isDegraded = true
            await sink.record(baseRecord(event: .degradedEnter, at: now))
        }
        // HR sampling and logging continue; only commits are suspended.
        return configuration.heartbeatPoll
    }

    private func clearDegradedIfNeeded(at now: Instant) async {
        consecutiveFailures = 0
        guard isDegraded else { return }
        isDegraded = false
        await sink.record(baseRecord(event: .degradedExit, at: now))
    }

    // MARK: - Record construction

    /// Every record carries the same context block, so a line in the log can be
    /// read without the lines around it. §11.3 tuning depends on that — grep
    /// for `commit_miss` and you want the HR and zone that produced it in the
    /// same object, not three lines earlier.
    private func baseRecord(event: Decision.Event, at now: Instant) -> Decision {
        var record = Decision(at: now, event: event)
        record.hrInstant = window.instantaneousBPM
        record.hrWindowMean = window.observedHR(at: now)
        record.windowSampleCount = window.sampleCount(at: now)
        record.currentZone = zoneModel.currentZone
        record.rawZone = record.hrWindowMean.map { zoneModel.rawZone(for: $0) }
        record.dwellSeconds = zoneModel.dwellElapsed(at: now)?.inSeconds
        record.eligibleZone = zoneModel.candidate
        record.targetZone = zoneModel.targetZone(at: now)
        record.overrideActive = zoneModel.isOverridden(at: now)
        record.trackID = trackClock.trackID
        record.trackRemainingMillis = trackClock.remaining(at: now).map { Int($0.inSeconds * 1000) }
        return record
    }

    private func noteArtist(_ artist: String) {
        recentArtists.insert(artist, at: 0)
        if recentArtists.count > 2 { recentArtists.removeLast() }
    }
}
