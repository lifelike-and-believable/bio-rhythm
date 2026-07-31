# HR-Steered Spotify Zone Player — Requirements & Design Spec

**Status:** Draft v1 · **Target platform:** watchOS (standalone) + minimal iOS companion
**Primary reader:** an implementing coding agent. Secondary reader: the project owner.

---

## 0. Notes for the implementing agent

Read this section before writing any code.

1. **The Spotify Web API changed substantially in Nov 2024 and Feb 2026.** Model knowledge from before that is actively wrong. Do not reach for `GET /v1/audio-features`, `GET /v1/audio-analysis`, `GET /v1/recommendations`, `GET /v1/artists/{id}/related-artists`, or featured-playlist endpoints. They return 403 for any app created after 2024-11-27. Do not reach for `POST /v1/playlists/{id}/tracks` or `GET /v1/playlists/{id}/tracks`; those were renamed to `/items` in Feb 2026. Section 4 is the authoritative endpoint list for this project. If you believe you need an endpoint not in Section 4, stop and ask.
2. **`HRDJCore` must not import HealthKit, SwiftUI, WatchKit, or perform I/O.** All control logic lives there behind protocols with injected clock and injected transport. This is the difference between a tunable system and an untestable one. Every number in Section 6 must be reachable by a unit test driving a synthetic HR trace against a fake clock.
3. **"Never interrupt a song" is enforced structurally, not by discipline.** See Section 5.3. The automatic controller must not be able to *express* a skip/pause/seek call. If you find yourself adding a transport method to a protocol the controller sees, you have misread the spec.
4. **Milestone M2 is observe-only on purpose.** Do not skip ahead to actuation. The owner needs real logged HR traces from real workouts to tune Section 6 constants before the loop is allowed to drive playback.
5. **Section 12 is a list of things nobody has verified yet.** Several design choices depend on the answers. Run that checklist before building on top of the affected areas, and record the results in the repo.
6. Prefer boring, explicit code. This is a personal-scale app with one user; there is no scale problem to solve. The hard parts are timing, hysteresis, and failure handling.

---

## 1. Problem statement

Workout music selection is manual and badly timed. The listener adjusts the music to match their effort, which means fiddling with a phone or watch mid-effort, or accepting a playlist whose energy has no relationship to what the body is actually doing. Existing "BPM matching" apps solve a different and largely irrelevant problem (cadence sync), and most of them broke when Spotify withdrew tempo data from the Web API.

The opportunity: heart rate is already measured continuously and accurately on the wrist. It is a direct proxy for effort. Effort maps cleanly onto a small number of music energy tiers. A closed loop between the two removes the manual work entirely.

## 2. Goals

- **G1.** Music energy tracks the listener's effort automatically, with no interaction during a workout.
- **G2.** The listener never experiences a song being cut off. Zero mid-track interruptions caused by the system, under all conditions including network failure.
- **G3.** The system runs on the watch alone, with no phone present, for the duration of a workout.
- **G4.** Zone thresholds, timings, and pool contents are tunable by the owner without a code change.
- **G5.** Every automatic decision is logged in enough detail to reconstruct and second-guess it afterwards.

## 3. Non-goals

| Non-goal | Rationale |
|---|---|
| Tempo / BPM matching | Explicitly rejected in favour of energy zones. Spotify no longer exposes tempo, and cadence sync is a different product. |
| Deriving energy from audio analysis | Prompted Playlists supply the energy grouping. No MIR pipeline, no per-track tagging, no third-party audio API. |
| Programmatic playlist generation | No API exists for Prompted Playlists, and `/recommendations` is withdrawn. Pool creation is a manual, occasional, in-app task. |
| Crossfade, beat-matching, gapless, any DSP | The system chooses *what plays next*. It does not touch audio. |
| Multi-user, accounts, sharing, App Store distribution | Out of scope for M0–M4. The current product is a single-user personal build, sideloaded via Xcode. A later commercial phase is specified separately in §16 and must not weaken the invariants below. |
| Apple Music, local library, or any non-Spotify source | One backend. Revisit only if Spotify access degrades further. |
| Recording rich workout metrics (pace, GPS, calories) | The workout session exists to obtain live HR and background runtime. It is not a training log. See R-14 for the one exception. |
| Reacting to HRV, cadence, power, or elevation | HR only. Additional signals are a later question. |

## 4. External dependencies and authoritative API surface

### 4.1 Accounts and app registration

- Spotify **Premium** is required. Playback control has always required it, and as of Feb 2026 a Development Mode app additionally requires the *app owner* to hold active Premium. If the subscription lapses the app stops working and resumes on resubscribe.
- Development Mode limits for newly created apps: **1 client ID per developer, 5 users per app.** Adequate here. Do not design anything that assumes more.
- Extended Quota Mode is unavailable in practice for the current personal build (it requires large MAU) and is not a fallback for M0–M4. A future commercial phase may pursue it only as a business/quota gate (§16), not as an authentication architecture change.

### 4.2 Player endpoints (all confirmed available, Feb 2026 changelog)

| Method | Path | Use in this project |
|---|---|---|
| `GET` | `/v1/me/player` | Primary state read: `is_playing`, `progress_ms`, `item.id`, `item.duration_ms`, `item.uri`, `device`, `shuffle_state` |
| `POST` | `/v1/me/player/queue` | **The only actuator used by the automatic controller.** Body: `uri` query param |
| `GET` | `/v1/me/player/queue` | Diagnostic / commit verification |
| `GET` | `/v1/me/player/devices` | Device selection at session start |
| `PUT` | `/v1/me/player` | Transfer playback to the watch device at session start |
| `PUT` | `/v1/me/player/play` | Session start only, with `context_uri` = fallback pool. **Not reachable from the controller.** |
| `PUT` | `/v1/me/player/shuffle` | Session start only |
| `PUT` | `/v1/me/player/pause`, `POST .../next`, `POST .../previous`, `PUT .../seek`, `PUT .../volume` | Manual UI only. **Never reachable from the controller.** |

### 4.3 Playlist endpoints

| Method | Path | Notes |
|---|---|---|
| `GET` | `/v1/me/playlists` | Pool discovery during setup |
| `GET` | `/v1/playlists/{id}` | Metadata |
| `GET` | `/v1/playlists/{id}/items` | **Renamed from `/tracks` in Feb 2026.** Response fields renamed: `tracks` → `items`, `tracks.tracks` → `items.items`, `tracks.tracks.track` → `items.items.item`. Paginate via `limit`/`offset`. |

Only playlists **owned by the authenticated user** return an `items` object; other playlists return metadata only. Prompted Playlists are saved into the user's own library and are expected to qualify, but this is **unverified** — see V-1.

### 4.4 Withdrawn — do not call

`/v1/audio-features`, `/v1/audio-analysis`, `/v1/recommendations`, `/v1/artists/{id}/related-artists`, `/v1/browse/featured-playlists`, `/v1/tracks` (batch), `/v1/artists/{id}/top-tracks`, `/v1/markets`, `/v1/users/{id}/playlists`, `/v1/me/tracks` (PUT/DELETE — use `/v1/me/library`). Track `popularity` and `available_markets` fields are also gone.

### 4.5 Prompted Playlists (upstream constraint, not an integration)

Prompted Playlists are an in-app Premium **beta** feature with usage limits that Spotify says may change. There is no API. Consequences the design must absorb:

- Pool creation and editing happen by hand in the Spotify mobile app. The watch app only *reads* pools.
- Pools may be scheduled to auto-refresh daily or weekly. **Pool contents are therefore not stable across sessions.** Fetch fresh at every session start; never persist pool contents as ground truth.
- Prompt drift will occasionally misfile a track (a mellow track landing in the hard pool). The blocklist (R-11) is the mitigation.
- Nothing in the runtime path may depend on generating or refreshing a Prompted Playlist.

### 4.6 Platform

- watchOS: HealthKit (`HKWorkoutSession`, `HKLiveWorkoutBuilder`), Keychain, `URLSession`, SwiftUI, `WKExtendedRuntimeSession` not required if the workout session is active.
- iOS companion: `ASWebAuthenticationSession`, `WatchConnectivity`.
- **Only one `HKWorkoutSession` may be active on the device at a time.** This app must own it, which means it cannot run alongside the Workout app or Strava recording a session. See V-3 and R-14.

---

## 5. Architecture

### 5.1 Component overview

```
┌─────────────────────── WatchApp (watchOS target) ──────────────────────┐
│                                                                        │
│  HealthKitSource ──HRSample──┐                                         │
│   (HKLiveWorkoutBuilder)     │                                         │
│                              ▼                                         │
│  WorkoutCoordinator ──▶ ┌──────────── HRDJCore (pure) ───────────┐     │
│   (session lifecycle)   │                                        │     │
│                         │  HRWindow ──▶ ZoneModel ──▶ Controller │     │
│                         │       TrackClock ──▶ CommitScheduler   │     │
│                         │                PoolManager             │     │
│                         └──────┬──────────────────┬──────────────┘     │
│                                │ reads            │ enqueue(uri)       │
│  TelemetryLog ◀── decisions ───┘                  │                    │
│                                                   ▼                    │
│                        SpotifyKit: PlaybackReading, PlaybackQueueing    │
│                                        │                               │
│  Manual UI ──▶ PlaybackTransport ──────┤ (separate protocol)           │
│                                        ▼                               │
│                              TokenStore (Keychain) ──▶ Spotify Web API │
└────────────────────────────────────────────────────────────────────────┘

┌──────── iOSCompanion ────────┐
│ PKCE OAuth (ASWebAuth)       │
│ → refresh token              │
│ → WatchConnectivity transfer │──▶ watch Keychain
│ Pool picker (choose 4 IDs)   │
└──────────────────────────────┘
```

### 5.2 Package layout

```
/
├── CLAUDE.md
├── SPEC.md
├── Package.swift                     # SwiftPM for the two library targets
├── Sources/
│   ├── HRDJCore/                     # NO HealthKit, NO SwiftUI, NO URLSession
│   │   ├── Clock.swift               # protocol Clock { var now: Instant }
│   │   ├── Models.swift              # Zone, HRSample, TrackRef, PoolID, Decision
│   │   ├── Playback.swift            # PlaybackReading / PlaybackQueueing / PlaybackTransport
│   │   ├── HRWindow.swift            # ring buffer + trailing statistics
│   │   ├── ZoneModel.swift           # boundaries, hysteresis, dwell, step limit
│   │   ├── TrackClock.swift          # boundary estimation from progress/duration
│   │   ├── CommitScheduler.swift     # late-commit window state machine
│   │   ├── PoolManager.swift         # pools, played-set, selection
│   │   └── Controller.swift          # orchestrates the above; the system under test
│   └── SpotifyKit/
│       ├── Auth/                     # PKCE, refresh, TokenStore protocol
│       ├── Endpoints/                # PlayerAPI, PlaylistAPI
│       ├── DTOs/                     # Codable, matching post-Feb-2026 field names
│       └── RateLimiter.swift         # (conforms to the protocols declared in HRDJCore)
├── Tests/
│   ├── HRDJCoreTests/
│   │   └── Fixtures/                 # synthetic HR traces as JSON
│   └── SpotifyKitTests/
└── Apps/
    ├── WatchApp/
    └── iOSCompanion/
```

### 5.3 Structural enforcement of the never-interrupt guarantee (R-2)

Three protocols, deliberately separated:

```swift
public protocol PlaybackReading {
    func playbackState() async throws -> PlaybackState
}

public protocol PlaybackQueueing {
    func enqueue(_ uri: TrackURI) async throws
}

// NOT visible to Controller. Injected only into manual UI view models.
public protocol PlaybackTransport {
    func play(context: ContextURI, shuffle: Bool) async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func seek(toMillis: Int) async throws
    func setVolume(percent: Int) async throws
    func transfer(toDevice: DeviceID) async throws
}
```

`Controller.init` accepts `PlaybackReading & PlaybackQueueing` and nothing else. The concrete `SpotifyPlayerClient` conforms to all three, but the controller's dependency is declared as the narrow composition, so a skip call from control logic is a compile error rather than a bug. A unit test asserts the controller's dependency type does not conform to `PlaybackTransport`.

The three protocols are **declared in `HRDJCore`** and conformed to in `SpotifyKit`, which is the reverse of what an earlier draft of §5.2 showed. `Controller` lives in `HRDJCore` and has to name its own dependency type; `HRDJCore` may not import `SpotifyKit`. Dependency inversion is the only arrangement that satisfies both. Nothing about the separation above changes — only which module declares it. See `docs/verification.md` D-1.

---

## 6. Control law

All constants below are **tunable defaults** and must be surfaced in configuration (R-13), not hardcoded at call sites.

### 6.1 Zone definition

Zones are derived from `maxHR`, which the owner sets explicitly (do not compute from age).

| Zone | Index | Label | Lower bound (% maxHR) | At maxHR 182 |
|---|---|---|---|---|
| Z0 | 0 | Meditation | 0 | — |
| Z1 | 1 | Recovery | 34 | 62 bpm |
| Z2 | 2 | Aerobic | 60 | 109 bpm |
| Z3 | 3 | Tempo | 70 | 127 bpm |
| Z4 | 4 | Hard | 82 | 149 bpm |

`boundaries = [0.34, 0.60, 0.70, 0.82] × maxHR`, rounded to whole bpm. Default activity — the zone you are in walking around, warming up, or doing anything at all — is Z1, the 62-to-109 band at maxHR 182.

**Every threshold is a fraction of `maxHR`, including the meditation ceiling.** `MEDITATION_CEILING = 34 %` was chosen to put the Z0/Z1 boundary at 62 bpm for the owner's 182. The uniformity earns its keep: `boundaries[i]` is the lower bound of zone `i + 1` with no offset and no special case, so ordering the fraction list is enough to order the thresholds. A single absolute bpm mixed in among percentages could cross the Z2 threshold at a low `maxHR` and would need its own validation and fallback path; as a fraction it cannot.

**The fraction list must be ascending, and is sorted on construction rather than trusted.** §6.3 walks the threshold list and stops at the first bound the heart rate does not clear, so a misordered list does not fail — it silently reports the wrong zone. Sort rather than reject: R-13 puts these behind a settings screen in M4, and a hard precondition there is a watch app that dies mid-workout over a typo.

The trade-off is real and worth stating: a meditative heart rate is arguably set by the resting floor rather than the maximum, so tying it to `maxHR` means it moves when `maxHR` is re-measured. Accepted in exchange for the uniformity. If it lands somewhere unhelpful after a re-measurement, change the fraction — that is what R-13 is for.

The zone index is load-bearing: §6.3 indexes `boundaries` by it and §6.5 clamps on it. Z0 sits at index 0 with Z1–Z4 shifted up, rather than being bolted on below zero, so both rules are unchanged by its addition.

### 6.2 Observation

- `HRWindow` is a ring buffer of `(timestamp, bpm)`.
- Samples older than `WINDOW = 45 s` are evicted.
- A sample is **stale** if older than `STALE_SAMPLE = 10 s`. If the newest sample is stale, the window reports `nil`.
- `observedHR = arithmetic mean of the window`. Reject physiologically impossible samples outside `[30, 240]` bpm before insertion.
- If `observedHR == nil` at decision time, **hold the current zone**. Never move a zone on missing data.

### 6.3 Zone selection with hysteresis

Given `currentZone = n` and `observedHR = h`:

```
rawZone(h, n):
    if n < topZone and h > boundaries[n]   + MARGIN  →  n + 1
    if n > 0       and h < boundaries[n-1] - MARGIN  →  n - 1
    otherwise                                        →  n
```

`topZone` is the number of thresholds — `4` for §6.1's defaults. Write it against the boundary count rather than as a literal, so a change to the zone count does not need this rule rewritten.

`MARGIN = 0.025 × maxHR` (≈ 4–5 bpm for most values). Asymmetric thresholds are the point: entering a zone requires more than leaving it, which prevents flapping when HR sits on a boundary.

The margin is one fixed bpm figure for the whole range, so at the Z0/Z1 boundary it is proportionally much wider than at Z3/Z4: at maxHR 182 you leave meditation at ≥ 66.6 bpm and re-enter below 57.5. That asymmetry is wanted here — drifting in and out of a meditation pool because of a two-beat wobble is exactly the flapping §6.3 exists to prevent — but it is worth checking against real traces in M2 before assuming one margin suits both ends of the range.

### 6.4 Dwell requirement

`rawZone` must differ from `currentZone` **continuously for `DWELL = 20 s`** before it becomes eligible. Implementation: a `dwellTimer` that resets to zero whenever `rawZone == currentZone`, and accumulates otherwise. If `rawZone` changes direction mid-dwell, reset.

### 6.5 Step limit

`targetZone = clamp(eligibleZone, currentZone - 1, currentZone + 1)`. At most one zone step per commit, regardless of how large the HR excursion was. A sprint from Z1 to Z4 walks up over three tracks; from Z0, four.

### 6.6 Override

While `overrideUntil > now`, `targetZone = currentZone` unconditionally. `OVERRIDE_HOLD = 180 s`, set by:
- a detected manual skip (R-10),
- a manual zone change in the UI,
- a manual pause/resume cycle.

The watch UI must show an unambiguous override indicator with remaining time, and offer a "resume auto" action that clears it immediately.

### 6.7 Constant summary

| Constant | Default | Notes |
|---|---|---|
| `WINDOW` | 45 s | Trailing mean window |
| `STALE_SAMPLE` | 10 s | Freshness bound |
| `MEDITATION_CEILING` | 34 % maxHR | Z0/Z1 boundary; 62 bpm at maxHR 182. A personal choice like `maxHR` rather than a tuning constant — set it from observation, above where you actually settle, and do not wait on M2 logs to do so |
| `MARGIN` | 2.5 % maxHR | Hysteresis half-width |
| `DWELL` | 20 s | Continuous confirmation before a zone change is eligible |
| `MAX_STEP` | 1 | Zones per commit |
| `OVERRIDE_HOLD` | 180 s | Auto-control suspension after manual input |
| `COMMIT_OPEN` | T−20 s | First commit attempt |
| `COMMIT_RETRY_1` | T−14 s | |
| `COMMIT_RETRY_2` | T−9 s | |
| `COMMIT_DEADLINE` | T−6 s | After this, abandon and log a miss |
| `SHORT_TRACK_THRESHOLD` | 25 s remaining | Commit immediately instead of scheduling |
| `HEARTBEAT_POLL` | 30 s | Baseline state poll |
| `BOUNDARY_CONFIRM` | T+2 s, T+6 s | Post-boundary confirmation attempts |

---

## 7. Timing and state machines

### 7.1 TrackClock — boundary estimation

Polling at 1 Hz is unacceptable for battery and rate limit. Instead maintain a local estimate corrected by sparse polls.

On any `PlaybackState` observation containing a track:
```
observedAt      = clock.now                    // monotonic
remainingAtObs  = duration_ms - progress_ms
estimatedEnd    = observedAt + remainingAtObs
```
`estimatedEnd` is recomputed on every poll, so drift is bounded by the poll interval. Treat any single-poll correction larger than 3 s as evidence of a seek, and re-derive rather than smoothing.

Poll schedule per track: on track-change detection, then every `HEARTBEAT_POLL`, then at `COMMIT_OPEN` (needed anyway), then `BOUNDARY_CONFIRM` attempts. Roughly 8 requests per 3-minute track, about 2.7/min. Well inside any plausible rate limit.

### 7.2 Per-track commit state machine

```
                  ┌──────────┐
   track change   │ OBSERVING│  HR accumulating; no network writes
   detected  ────▶│          │
                  └────┬─────┘
                       │ clock.now >= estimatedEnd - COMMIT_OPEN
                       ▼
                  ┌──────────┐   enqueue(uri) succeeds
                  │COMMITTING│───────────────────┐
                  └────┬─────┘                   ▼
                       │ failure           ┌───────────┐
                       │ (retry at         │ COMMITTED │ no further writes this track
                       │  RETRY_1/2)       └───────────┘
                       ▼
                  ┌──────────┐
                  │  MISSED  │  past COMMIT_DEADLINE; log; fallback context plays
                  └──────────┘
```

Invariants, each with a corresponding unit test:

- **I1.** At most one successful `enqueue` per track ID. `committedForTrackID` guards re-entry.
- **I2.** No `enqueue` before `estimatedEnd - COMMIT_OPEN`.
- **I3.** No `enqueue` after `estimatedEnd - COMMIT_DEADLINE`.
- **I4.** No `enqueue` while `is_playing == false`.
- **I5.** Zone delta between consecutive commits is in `{-1, 0, +1}`.
- **I6.** The controller never calls a `PlaybackTransport` method (enforced by type; asserted by test).

### 7.3 Fallback context

`enqueue` only ever *appends*; queued items cannot be removed or reordered through the API. That makes a missed commit unrecoverable within the current track, so the fallback must be deliberately chosen rather than incidental.

At session start, `PlaybackTransport.play(context:)` is called once with the **fallback pool**, configurable and defaulting to Z2 or Z3 (whichever the owner expects to occupy most). Shuffle is enabled for the context. Queued tracks take precedence over context, so the context surfaces only in the `MISSED` case, where it yields a plausible mid-energy track rather than something jarring.

### 7.4 Session lifecycle

```
IDLE ──start──▶ AUTHORIZING ──▶ FETCHING_POOLS ──▶ ACQUIRING_DEVICE
                                                          │
                                                          ▼
                                          RUNNING ◀──▶ DEGRADED
                                             │
                                          ──end──▶ TEARDOWN ──▶ IDLE
```

- `FETCHING_POOLS`: fetch every configured pool (§4.3), fresh, every session. Fail fast with a clear message if a pool is empty or unreadable. Two pools may be configured with the same playlist ID — Z0 and Z1 is the expected case (§8) — and it should be fetched once, not twice.
- `ACQUIRING_DEVICE`: `GET /me/player/devices`, select the watch, `PUT /me/player` to transfer, `PUT /me/player/shuffle`, `PUT /me/player/play` with fallback context.
- `DEGRADED`: entered after `3` consecutive network failures. HR sampling and logging continue; commits are suspended; the UI shows it. Exponential backoff retry (2, 4, 8, 16, 30 s, capped) probing `GET /me/player`. Return to `RUNNING` on success.
- `TEARDOWN`: end the workout session, flush telemetry, optionally save the workout (R-14). Do **not** pause playback on teardown unless the owner asks.

---

## 8. Pool management

- **PoolID** ∈ {Z0, Z1, Z2, Z3, Z4}, one per zone, each mapped to one Spotify playlist ID in configuration. The mapping need not be injective: pointing Z0 and Z1 at the same playlist is a supported configuration and the way to have the meditation zone without curating a separate pool for it. `docs/pools.md` covers the trade-off.
- Fetch with `GET /v1/playlists/{id}/items`, paginated. Post-Feb-2026 field names apply (`items.items[].item`).
- **Filter on ingest:** drop entries where `item == nil`, `item.type != "track"`, `is_local == true`, or `item.is_playable == false`. Drop anything on the blocklist.
- **Deduplicate across pools.** A track may legitimately appear in two Prompted Playlists. Keep a session-wide `playedURIs` set; a track played from Z2 is ineligible in Z3 for the rest of the session.
- **Selection:** uniform random from eligible candidates in the target pool. Secondary rule: avoid selecting the same primary artist as either of the two previously played tracks, if an alternative exists. Prevents accidental artist clustering that reads as a bug.
- **Exhaustion:** if a pool has no eligible candidates, clear `playedURIs` entries belonging to that pool only, log it, and reselect. If it is still empty, fall back one zone toward Z2 and log a pool-starvation warning.

---

## 9. Authentication

### 9.1 Flow

Authorization Code with **PKCE**. No client secret on device.

`ASWebAuthenticationSession` is not available on watchOS, so the interactive leg runs on the iOS companion:

1. iOS companion performs PKCE authorization, receives `access_token` + `refresh_token`.
2. Companion sends the refresh token to the watch via `WCSession.transferUserInfo`. Do not use `updateApplicationContext` (it is lossy and last-write-wins).
3. Watch stores the refresh token in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
4. **Thereafter the watch refreshes independently.** No phone required at runtime. This is the only phone dependency and it is onboarding-only, consistent with G3.

Handle refresh-token rotation: Spotify may return a new `refresh_token` on refresh. Always persist it if present.

### 9.2 Scopes

```
user-read-playback-state
user-modify-playback-state
playlist-read-private
playlist-read-collaborative
```

Do not request scopes beyond these. `user-read-email` and `user-read-private` are pointless now that `email`, `country`, and `product` were removed from the user object.

### 9.3 Token handling

- Refresh proactively at `expires_in - 120 s`, not reactively on 401.
- Serialize refreshes behind a single actor. Concurrent 401s must not trigger parallel refreshes.
- On refresh failure with `invalid_grant`, the grant is dead: clear Keychain, enter a re-onboarding state, surface it clearly on the watch.

### 9.4 Rate limiting

Spotify does not publish exact limits. Implement a conservative token-bucket in `SpotifyKit` (suggest 60 requests/minute, burst 10) and honour `Retry-After` on 429 absolutely. A 429 during a commit window counts as a commit failure and follows the retry schedule in §6.7.

---

## 10. HealthKit integration

- `HKWorkoutConfiguration`: `activityType` configurable, default `.other`; `locationType = .unknown`.
- Authorization: read `HKQuantityType(.heartRate)`; share `HKWorkoutType` only if R-14 is enabled.
- Use `HKLiveWorkoutBuilder` with `HKLiveWorkoutDataSource`. Read HR from `workoutBuilder(_:didCollectDataFor:)` via `statistics(for:)?.mostRecentQuantity()`, converted to `count/min`.
- Expect roughly 1 Hz during activity, degrading with poor contact. The design already tolerates gaps (§6.2).
- The active workout session is what grants extended background runtime. Do **not** additionally request `WKExtendedRuntimeSession`.
- Handle `HKWorkoutSessionState` transitions including `.paused` (auto-pause) and interruption. A paused session suspends commits.
- **Single-session constraint:** only one workout session may be active device-wide. If `startActivity` fails because another app holds one, surface a specific, actionable error naming the conflict. Do not retry silently.

---

## 11. Cross-cutting requirements

### 11.1 Functional requirements

| ID | Priority | Requirement | Acceptance criteria |
|---|---|---|---|
| R-1 | P0 | Automatic zone selection from live HR | Given a synthetic ramp trace, the logged zone sequence matches the expected sequence within one decision point |
| R-2 | P0 | Never interrupt a track | Controller type does not conform to `PlaybackTransport`; no transport call appears in any session log; verified across 10 real sessions |
| R-3 | P0 | Late-commit scheduling | Invariants I1–I4 hold under fake-clock tests including failure injection |
| R-4 | P0 | Hysteresis, dwell, and one-step limiting | Boundary-oscillation trace produces zero zone changes; invariant I5 holds |
| R-5 | P0 | Standalone watch operation | A full session completes with the paired phone powered off |
| R-6 | P0 | Pool fetch at session start | Four non-empty pools loaded before `RUNNING`; stale cache never used |
| R-7 | P0 | Fallback context configured at session start | A forced commit failure results in playback continuing from the fallback pool with no gap |
| R-8 | P0 | Degraded mode on repeated network failure | After 3 induced failures, commits stop, UI indicates it, recovery is automatic |
| R-9 | P0 | Structured decision telemetry | §11.3 fields present for every decision; exportable |
| R-10 | P1 | Manual skip detection → override | Track changes more than 5 s before `estimatedEnd` sets `overrideUntil` |
| R-11 | P1 | Blocklist | Long-press on now-playing adds the URI; blocked tracks never reappear in any pool |
| R-12 | P1 | Manual zone lock | Owner can pin a zone; pin implies override until cleared |
| R-13 | P1 | Configuration surface | Every §6.7 constant, `maxHR`, `MEDITATION_CEILING`, all five pool IDs, and fallback pool editable without rebuild |
| R-14 | P2 | Optionally save the workout to HealthKit | Toggle; when on, the session appears in Health with HR data |
| R-15 | P2 | Session summary screen | Time in each zone, commit count, miss count, override count |

### 11.2 Watch UI

Minimum viable, glanceable, one screen:

- Current HR, large.
- Current zone, with every zone shown as a discrete indicator (not a continuous gauge — the system is discrete and the UI should not imply otherwise). Five steps as of §6.1's meditation zone.
- Now playing: title and artist, truncated.
- Next committed track, or "deciding" during `OBSERVING`, or a warning glyph in `MISSED` / `DEGRADED`.
- Override indicator with countdown when active, plus "resume auto".
- Long-press: blocklist current track. Digital Crown: manual zone lock.

No animations that run continuously. Battery matters more than polish here.

### 11.3 Telemetry

Append-only JSONL in the app container, one file per session, rotated and capped (suggest 5 MB / 10 sessions). Exportable to the phone on request.

Per decision record:
```json
{
  "t": "2026-07-28T14:03:11.482Z",
  "event": "commit",
  "hrInstant": 148,
  "hrWindowMean": 143.2,
  "windowSampleCount": 42,
  "currentZone": 2,
  "rawZone": 3,
  "dwellSeconds": 24.0,
  "eligibleZone": 3,
  "targetZone": 3,
  "overrideActive": false,
  "trackId": "…",
  "trackRemainingMs": 19400,
  "estimatedEndDriftMs": 340,
  "selectedUri": "spotify:track:…",
  "selectedFromPool": "Z3",
  "attempt": 1,
  "outcome": "success",
  "httpStatus": 204
}
```
Also log: `hr_sample_gap`, `zone_change`, `commit_miss`, `override_set`, `override_cleared`, `degraded_enter`, `degraded_exit`, `pool_starvation`, `manual_skip`, `session_start`, `session_end`.

This file is the tuning instrument for §6.7. Treat it as a first-class deliverable, not debug output.

### 11.4 Error handling summary

| Condition | Behaviour |
|---|---|
| No fresh HR sample | Hold zone. Log `hr_sample_gap`. Do not skip the commit. |
| `is_playing == false` | Suspend commit scheduling. Resume on next playing observation. |
| Commit returns 404 (no active device) | Attempt one device re-acquisition, then `DEGRADED` |
| Commit returns 403 | Log loudly with body; likely Premium lapse or scope problem. Enter `DEGRADED`, surface a distinct message. |
| Commit returns 429 | Honour `Retry-After`; counts as a failed attempt |
| 3 consecutive failures of any kind | `DEGRADED` |
| Pool fetch fails at session start | Refuse to start `RUNNING` with a specific error. Do not start without a usable pool for every zone (§8 — Z0 and Z1 may share one playlist). |
| `invalid_grant` on refresh | Clear tokens, re-onboarding state |
| Workout session start fails | Named error identifying the single-session conflict |

---

## 12. Verification checklist (do this before building dependent code)

| ID | Question | How | Blocks |
|---|---|---|---|
| V-1 | Are Prompted Playlist items readable via `GET /v1/playlists/{id}/items`? | `curl` with a user token against a real Prompted Playlist ID. Confirm an `items` object with populated `item` entries. | §8 entirely. If it fails, pools must be manually duplicated into ordinary playlists. |
| V-2 | Actual dev-mode rate limit headroom | Drive ~3 req/min for 30 min, watch for 429 and inspect any `Retry-After` | §9.4 tuning |
| V-3 | Does starting `HKWorkoutSession` fail while another app holds one? | Start Apple Workout, then attempt to start this app's session | §10, R-14, product framing |
| V-4 | Does a queued track reliably play next when the context is a shuffled playlist? | Enqueue a known URI mid-track, observe boundary | §7.3 — the fallback design depends on queue-over-context precedence |
| V-5 | Watch network reliability without the phone | Full session on LTE, and on Wi-Fi only, phone powered off | R-5, `DEGRADED` thresholds |
| V-6 | Do Prompted Playlist auto-refreshes change IDs or only contents? | Schedule a daily refresh, compare playlist ID and contents after 48 h | §4.5. If IDs rotate, configuration must be re-pointed each time and R-13 needs a repair flow. |

Record answers in `/docs/verification.md` with dates. Several are behaviour that is undocumented and may change.

---

## 13. Milestones

**M0 — Skeleton and auth.** SwiftPM packages, iOS companion PKCE flow, refresh token transferred to watch Keychain, watch performs an independent refresh and displays the currently playing track. Exit: watch reads playback state with the phone off.

**M1 — Workout session and HR.** `HKWorkoutSession` lifecycle, `HRWindow`, live HR and computed zone on screen. No actuation, no network writes. Exit: a 30-minute session holds background runtime and logs continuous HR.

**M2 — Observe-only control loop.** Full `ZoneModel`, `TrackClock`, `CommitScheduler`, and `PoolManager` wired up, computing and logging every decision it *would* have made, with `enqueue` stubbed out. **Ship this and run it for several real workouts.** Tune §6.7 against the resulting logs. Exit: owner is satisfied that the logged zone sequence matches perceived effort.

**M3 — Actuation.** Enable `enqueue`. Fallback context, `MISSED` handling, `DEGRADED` mode, device acquisition. Exit: 10 consecutive sessions with zero mid-track interruptions and a commit miss rate under 5%.

**M4 — Ergonomics.** Override, manual zone lock, blocklist, session summary, configuration UI, optional workout saving.

**M5 — Commercial readiness, if the product direction changes.** App Store/TestFlight hardening, user-facing setup and repair flows, privacy disclosures, Spotify policy review, and Extended Quota Mode submission materials. M5 begins only after M3's exit bar is met and M4's configuration surface exists; it does not replace any control-law verification.

Do not compress M2. It is the only milestone that produces the data needed to make the rest correct.

---

## 14. Test plan

### 14.1 HRDJCore — deterministic, no I/O

Fixtures in `Tests/HRDJCoreTests/Fixtures/*.json`, each a timestamped HR series:

- `ramp_up.json` — 55 → 175 bpm over 20 min. Expect monotonic non-decreasing zones, one step at a time. Starts below `MEDITATION_CEILING`, so it exercises the Z0 → Z4 climb end to end.
- `ramp_down.json` — mirror. Expect monotonic non-increasing.
- `boundary_oscillation.json` — HR hovering ±3 bpm around a zone boundary for 15 min. **Expect zero zone changes.** This is the hysteresis test and the most important one in the suite.
- `spiky.json` — 10-second spikes into Z4 from a Z2 baseline. Expect no zone change (dwell rejects them).
- `dropout.json` — 90-second sensor gap mid-session. Expect zone held, `hr_sample_gap` logged, commits still attempted.
- `interval.json` — 4×4 minute intervals. Expect the step limit to visibly lag the effort; assert it never jumps two zones.

Drive all of these through `FakeClock` and `FakeSpotify`, the latter with injectable per-call latency and failure modes (timeout, 429 with `Retry-After`, 404, 403, malformed body).

### 14.2 Property tests

For randomized HR traces and randomized failure injection, assert invariants I1–I6 always hold. These are the guarantees the product rests on and they should be checked adversarially rather than by example.

### 14.3 SpotifyKit

- DTO decoding against **captured real response fixtures**, post-Feb-2026 shapes. Do not hand-write expected JSON from memory; capture it with `curl` and commit it.
- Token refresh: concurrent 401s trigger exactly one refresh.
- Rate limiter honours `Retry-After`.
- Playlist validation covers metadata and `/v1/playlists/{id}/items`, including empty, unreadable, private, non-owned, 401, 403, and 429 responses. Do not add `/tracks`.

### 14.4 Configuration, storage, and onboarding

- Configuration encoding/decoding/defaults/migration, with an explicit schema version.
- `maxHR` validation and derived boundary assertions, including the Z0/Z1 `MEDITATION_CEILING` fraction.
- Five pool IDs plus fallback pool, with Z0 and Z1 allowed to share the same playlist ID.
- Local storage failure/recovery. The refresh token stays in Keychain; user configuration lives in the app container (`UserDefaults` or plist); playlist contents are never persisted as ground truth.
- iOS companion transfer of onboarding payloads, watch persistence across restart, re-onboarding replacement of stale credentials, and reset flows for configuration and Spotify account.
- A dependency guard that `HRDJCore` imports only the standard library.

### 14.5 Manual / on-device

A checklist in `/docs/field-test.md` covering: phone off, airplane mode mid-session, Spotify app force-quit mid-session, manual skip, pause and resume, another workout app started mid-session, watch battery under 10%, and a full session in the shower-cold-hands sensor-dropout case.

For a commercial phase, extend the checklist with LTE-only and Wi-Fi-only sessions, app restart after onboarding, unreadable or empty configured playlists, re-authorization after `invalid_grant`, HealthKit permission denial, App Store privacy strings, and reset-account/reset-configuration flows.

### 14.6 Commercial beta metrics

If M5 is pursued, TestFlight/beta validation must track onboarding completion, playlist validation failure rate, session completion rate, commit miss rate, battery impact, and the R-2 bar: zero automatic mid-track interruptions.

---

## 15. Risks and trade-offs

| Risk | Impact | Mitigation |
|---|---|---|
| Prompted Playlists is a beta with usage limits and could change or be withdrawn | Pools disappear | Nothing in runtime depends on generation; pools are ordinary playlist reads. Worst case, pools become hand-curated playlists with no other code change. |
| Spotify further restricts the Web API | Project dead | No mitigation. Accept the platform risk; keep `SpotifyKit` isolated so a different backend is a contained rewrite. |
| Queue is append-only, so late commit is a one-shot decision | Occasional off-zone track | Deliberate fallback context (§7.3); miss rate is a tracked metric |
| Single workout session per device | Cannot coexist with another workout app | R-14 lets this app record the workout instead. Product decision, not a bug. |
| Prompt drift misfiles tracks into wrong pools | Occasional wrong-energy track | Blocklist (R-11) plus fresh fetch each session |
| One-step-per-track limit lags sharp interval work | Music trails effort during intervals | Accepted. Sharper response reintroduces thrash. Revisit only with logged evidence from M2. |
| watchOS background runtime ends unexpectedly | Loop dies mid-session | Workout session is the sanctioned mechanism; detect and log; UI shows loss of control |

### Deliberate trade-offs, recorded

- **Discrete zones over continuous energy mapping.** A handful of buckets is all the resolution the actuator supports, given one decision per three minutes. A continuous model would be false precision. The count is a product decision rather than a structural one — going from four to five cost one enum case and one threshold.
- **Trailing mean over instantaneous HR.** Adds ~20 s of lag, removes essentially all noise sensitivity. The actuation rate is already low enough that the lag is free.
- **Late commit over playlist-tail rewriting.** Rewriting a scratch playlist's tail would make decisions revocable, but relies on undocumented client behaviour around mid-playback playlist edits. Late commit uses only documented semantics. Revisit as a v2 if the miss rate proves annoying.
- **Watch-only runtime, phone-only onboarding.** `ASWebAuthenticationSession` does not exist on watchOS. A one-time phone step is a smaller cost than any on-watch code-entry scheme.

---

## 16. Future commercial / App Store phase

This section is a scope amendment, not permission to skip M0–M4. The repository still targets a single-user sideloaded build until M3 has proven actuation and M4 has supplied the configuration UI.

### 16.1 Product boundary

- No app-level account system unless Spotify approval or App Store review makes one unavoidable.
- No backend server for ordinary operation. The watch uses Spotify OAuth/PKCE, local Keychain tokens, local configuration, and direct Spotify Web API calls.
- One Spotify Premium account per watch. The product should explain this clearly rather than hide it behind an account abstraction.
- Preserve the hard invariants: standalone watch runtime, local-only user configuration, no automatic pause/skip/seek/previous, no HealthKit/network/UI dependencies in `HRDJCore`, and no speculative tuning of §6.7 constants.

### 16.2 User configuration surface

Onboarding must become more than Spotify authorization:

1. Spotify connection status and re-authorization entry point.
2. Explicit `maxHR` entry; never derive it from age.
3. Five playlist IDs, one for each of Z0–Z4. Z0 and Z1 may point at the same ID.
4. Fallback pool choice, defaulting to Z2 or Z3.

The refresh token remains Keychain-only. User configuration is stored locally in the app container (`UserDefaults` or plist) with a schema version and migration tests. Playlist contents are fetched fresh at session start and are never treated as persisted ground truth.

Validate playlist IDs with the endpoints in §4.3: metadata plus `/v1/playlists/{id}/items`. Empty, unreadable, private, or non-owned playlists must produce clear repair instructions before a workout starts.

### 16.3 Repair and settings flows

- `invalid_grant` clears tokens and enters a re-onboarding state.
- Settings can edit `maxHR`, all pool IDs, fallback pool, and later the R-13 tuning surface once logs justify exposing it.
- Reset configuration and reset Spotify account are distinct actions.
- If V-6 shows Prompted Playlist IDs rotate on refresh, settings needs a repair flow that detects and re-points stale pool IDs.

### 16.4 Commercial hardening

- Prepare App Store privacy disclosures for HealthKit access, Spotify account access, local telemetry, and the absence of backend collection.
- Keep HealthKit purpose strings aligned with actual behaviour, especially optional workout saving (R-14).
- Review Spotify Developer Policy compliance: scopes, playback control, branding, quota, and user consent.
- Prepare Extended Quota Mode materials only after there is evidence to submit: demo video, screenshots, scope justification, privacy posture, and TestFlight or pilot usage data.

### 16.5 Release gate

Do not submit a commercial build until all of the following are true:

- V-1 through V-6 are recorded in `docs/verification.md`.
- M2 telemetry has been collected and §6.7 has either been tuned from logs or explicitly left unchanged with evidence.
- M3 has met its exit criterion: 10 consecutive sessions with zero mid-track interruptions and commit miss rate under 5%.
- M4 configuration and repair flows exist.
- App Store privacy requirements and Spotify quota/policy requirements are satisfied.
