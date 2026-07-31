# Verification log

Answers to SPEC.md §12. Several of these are undocumented platform behaviour
that may change, so each answer is dated and says how it was obtained.

**Status: all six open.** None of them can be answered without Premium
credentials, a paired watch, and a real Prompted Playlist, so none were
answered while building M0. §12 says to run the checklist before building on
top of the affected areas; the M0 code deliberately stops short of every one of
those areas.

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

## Deliberate changes to SPEC.md

CLAUDE.md makes SPEC.md authoritative and says to flag conflicts rather than
diverge silently. Twice now the right answer was to change the spec. Both are
listed here so the amendments are reviewable in one place rather than only as
diffs.

- **2026-07-31 — playback protocols moved from `SpotifyKit` to `HRDJCore`**
  (§5.2, §5.3). D-1 below has the reasoning. Owner's decision.
- **2026-07-31 — meditation zone added** (§6.1, and consequentially §6.3, §6.5,
  §6.7, §7.4, §8, §11.2, R-13). Owner's request. Two things about it are worth
  knowing before reading the code:
  - **Its boundary is 34 % of `maxHR`** — 62 bpm at the owner's 182 — so §6.1's
    "every zone is a percentage of `maxHR`" still holds without exception. It
    was first written as an absolute 62 bpm on the reasoning that a meditative
    HR is set by the resting floor rather than the maximum; the owner chose the
    percentage instead. That reasoning is still true and is recorded in §6.1 as
    the accepted trade-off, but uniformity bought more than it cost: an
    absolute 62 crosses the Z2 threshold below `maxHR` 104, so it needed its
    own validation and a fallback for the misordered case, and all of that
    disappeared with the change.
  - **Zone indices shifted.** Z0 sits at index 0 and Z1–Z4 moved up by one, so
    §6.3's boundary indexing and §6.5's step arithmetic are unchanged. This was
    free only because no §11.3 telemetry has been recorded yet. Once M2 starts
    producing traces, renumbering makes sessions incomparable and a future zone
    would have to be appended instead.

## Open design questions

Recorded here rather than resolved unilaterally, per CLAUDE.md ("if a request
conflicts with SPEC.md, say so rather than silently diverging").

### D-1. Where do the playback protocols live? — **settled, option 1**

SPEC.md §5.2 put `Protocols.swift` in `SpotifyKit`. CLAUDE.md non-negotiable
#2 says `HRDJCore` imports nothing but the standard library. At M2 the
`Controller` lives in `HRDJCore` and its dependency is
`PlaybackReading & PlaybackQueueing` — which it cannot name without importing
`SpotifyKit`. The two rules collide the moment the controller exists.

Three options were on the table: move the protocols into `HRDJCore`; declare
narrow equivalents there and adapt in the app layer; or let `HRDJCore` import
`SpotifyKit` (which would also have made the existing dependency circular).

**Resolved 2026-07-31 by the owner: option 1.** The protocols and their value
types now live in `Sources/HRDJCore/Playback.swift`; `SpotifyKit` conforms to
them rather than declaring them. §5.2 and §5.3 were amended to match — this is
the one place the spec was changed rather than followed, and it was changed
deliberately. `SpotifyPlayerClient` still conforms to all three, and the
narrow-composition injection in `SpotifyStack` is unchanged, so R-2 and the
§5.3 mechanism are untouched.

M2 is no longer blocked on this.

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

### D-4. Does one hysteresis margin suit both ends of the range? — M2 tuning

The meditation zone (§6.1) put a threshold at 34 % of `maxHR` — 62 bpm at 182,
far below the others. `MARGIN` is 2.5 % of `maxHR` and therefore a fixed bpm
figure — 4.55 at maxHR 182 — so it is proportionally much wider at the Z0/Z1
boundary than at Z3/Z4. In practice you leave meditation at ≥ 66.6 bpm and
re-enter below 57.5.

That is defensible and probably right: sitting still, a two-beat wobble should
not change what is playing, and the pool either side is very different. But it
is a guess, and it is the sort of guess §6.7 says to settle with logs rather
than argument. Left at one margin for now. Look at the `zone_change` records
around 62 bpm in the first M2 traces before deciding whether a per-boundary
margin is worth the extra constant.

Not blocking: `ZoneModel` does not exist yet, so nothing has been built on the
answer.

### D-5. Three things §6 does not decide about zone selection — settled in code

`ZoneModel` (§6.3–§6.6) needed answers §6 does not give. Each is recorded here
because each is visible in the M2 logs and each is cheap to reverse once those
logs exist.

**Where a session starts.** §6 never says. The first observation seeds
`currentZone` from the raw §6.1 mapping, with no hysteresis and no dwell.
The alternative — start everyone at Z1 — would make a session that begins at
tempo effort walk up over three tracks before the music caught up, which is
the failure the step limit is supposed to prevent, not cause.

**A gap in the samples breaks dwell.** §6.4 requires the proposal to differ
from the current zone *continuously* for 20 s. A stale window is not evidence
of continuity, so a nil observation resets the timer rather than letting it
accrue through the gap. Conservative in the safe direction: it can only delay a
zone change, never cause one. Worth checking against `dropout.json` traces —
if real sensor gaps are frequent enough that zone changes get starved, the
answer is a grace period, not accrual.

**The override resets dwell.** §6.6 says the target zone is pinned during the
hold; it does not say whether evidence accumulates underneath. It does not
here, so when the hold lifts the model needs 20 s of fresh confirmation.
Otherwise a change confirmed during the hold fires the instant the hold ends,
which is most of the way to not having had a hold.

**One more, not a decision so much as an observation.** §6.5's step limit is
redundant as written: §6.3's `rawZone` already returns at most one step from
the current zone, so with `MAX_STEP = 1` the clamp can never fire. It is
implemented anyway as the enforcement point for I5 (§7.2), which is a
guarantee the product rests on and should not depend on a property of a
different function that a later edit might quietly remove.
