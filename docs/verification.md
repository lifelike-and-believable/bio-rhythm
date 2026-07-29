# Verification log

Answers to SPEC.md §12. Several of these are undocumented platform behaviour
that may change, so each answer is dated and says how it was obtained.

**Status: all six open.** None of them can be answered without Premium
credentials, a paired watch, and a real Prompted Playlist, so none were
answered while building M0. §12 says to run the checklist before building on
top of the affected areas; the M0 code deliberately stops short of every one of
those areas.

The **V-items** below are platform/API behaviours to verify on real devices and
real Spotify data. The **D-items** later in this file are design questions raised
by implementation; D-1 blocks M2 because the control loop cannot be placed until
the playback protocol ownership is settled.

| ID | Question | Blocks | Status | Date | Answer |
|---|---|---|---|---|---|
| V-1 | Are Prompted Playlist items readable via `GET /v1/playlists/{id}/items`? | §8 entirely | **Open** | — | Run `Scripts/capture-fixtures.sh` against a real Prompted Playlist. A populated `items.items[].item` is a pass. If it fails, pools must be manually duplicated into ordinary playlists. |
| V-2 | Actual dev-mode rate limit headroom | §9.4 tuning | **Open** | — | Drive ~3 req/min for 30 min, watch for 429 and inspect any `Retry-After`. The limiter defaults (60/min, burst 10) are the spec's guess, not a measurement. |
| V-3 | Does starting `HKWorkoutSession` fail while another app holds one? | §10, R-14, product framing | **Open** | — | Start Apple Workout, then attempt to start this app's session. |
| V-4 | Does a queued track reliably play next when the context is a shuffled playlist? | §7.3 | **Open** | — | Enqueue a known URI mid-track, observe the boundary. The entire fallback design rests on queue-over-context precedence. |
| V-5 | Watch network reliability without the phone | R-5, DEGRADED thresholds | **Open** | — | Full session on LTE, and on Wi-Fi only, phone powered off. The M0 exit criterion is a weaker version of this and is worth recording here when it passes. |
| V-6 | Do Prompted Playlist auto-refreshes change IDs or only contents? | §4.5 | **Open** | — | Schedule a daily refresh, compare playlist ID and contents after 48 h. If IDs rotate, R-13 needs a repair flow. |

## What M0 assumed anyway

Two things in the M0 code are written against §4's description rather than
against observed behaviour. Both are isolated so that a wrong guess is a
contained fix:

- **DTO field names** (`Sources/SpotifyKit/DTOs/`) follow the Feb 2026 renames
  described in §4.3 — `/items` not `/tracks`, `items.items[].item` not
  `tracks.tracks[].track`. Nothing has decoded a real response yet.
  `FixtureDecodingTests` reports a known issue per missing fixture rather than
  passing vacuously.
- **Shuffle before play** in `SpotifyPlayerClient.play(context:shuffle:)`.
  Ordering is an assumption; confirm it alongside V-4.

## Open design questions raised while building M0

Recorded here rather than resolved unilaterally, per CLAUDE.md ("if a request
conflicts with SPEC.md, say so rather than silently diverging").

### D-1. Where do the playback protocols live? — blocks M2

SPEC.md §5.2 puts `Protocols.swift` in `SpotifyKit`. CLAUDE.md non-negotiable
#2 says `HRDJCore` imports nothing but the standard library. At M2 the
`Controller` lives in `HRDJCore` and its dependency is
`PlaybackReading & PlaybackQueueing` — which it cannot name without importing
`SpotifyKit`. The two rules collide the moment the controller exists.

M0 follows §5.2 literally, because at M0 only `SpotifyKit` and the app targets
touch the protocols and nothing is foreclosed. Before M2 starts, pick one:

1. **Move the protocols into `HRDJCore`**, and have `SpotifyKit` conform to
   them. Dependency inversion, keeps `HRDJCore` pure, contradicts §5.2's file
   layout only.
2. **Declare narrow equivalents in `HRDJCore`** and adapt in the app layer.
   Preserves both documents exactly, at the cost of a duplicate protocol pair
   and an adapter.
3. **Let `HRDJCore` import `SpotifyKit`.** Cheapest, and gives up
   non-negotiable #2 — note this would also make `SpotifyKit`'s existing
   dependency on `HRDJCore` circular.

Option 1 looks right, but it is the owner's call.

### D-2. Invariant I6 cannot be tested the way §5.3 describes

§5.3: "A unit test asserts the controller's dependency type does not conform to
`PlaybackTransport`." Taken literally that test cannot pass. `SpotifyPlayerClient`
conforms to all three protocols by design (§5.3 says so in the same paragraph),
so the same object is reachable as a transport through a dynamic cast, whatever
static type the controller holds it as.

What R-2 actually rests on is that control logic cannot *name* a transport
method through its declared dependency type — a compile-time property, and a
strong one. `ProtocolSeparationTests.guaranteeIsCompileTimeOnly` pins the
current behaviour and explains this.

If a runtime-checkable version is wanted, the fix is a wrapper type that holds
only the narrow existential and does not itself conform to `PlaybackTransport`.
That is one small struct and it would make I6 assertable as written. Not added
unilaterally, because it introduces a type §5.2 does not mention.

### D-3. `Clock` shadows `Swift.Clock`

§5.2 names the protocol `Clock`. The standard library exports one too, so any
module that imports `HRDJCore` must write `HRDJCore.Clock` or hit an ambiguity
error. It is a papercut, not a problem, and the spec's name was kept. Renaming
to `MonotonicClock` would remove it if the friction proves annoying.
