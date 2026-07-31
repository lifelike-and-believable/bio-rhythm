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

### Early signal on V-1: the pool IDs look Spotify-owned

**2026-07-31, unconfirmed.** The owner created five Prompted Playlists and the
Z0 one carries an ID beginning `37i9dQZF1`. That prefix is, as far as anyone
outside Spotify can tell, the one Spotify uses for playlists **it** generates
and owns — Discover Weekly, Daily Mix, Release Radar, editorial. User-created
playlists get IDs without it.

That matters because §4.3 says only playlists *owned by the authenticated user*
return an `items` object; everything else returns metadata only. If Prompted
Playlists are saved *into* the user's library but still **owned by Spotify**,
V-1 fails and §8 needs the duplication fallback — the exact outcome V-1 was
written to catch.

Three reasons not to treat this as settled:

- The prefix convention is observed, not documented, and Spotify has never
  promised it means anything.
- Prompted Playlists are a beta feature (§4.5) and may well be a special case.
- Library membership and ownership are different things, and the API may treat
  a saved-into-library playlist as readable regardless.

**2026-07-31, follow-up.** The Spotify app's byline for that playlist reads
*"Prompted by <owner>"*. That is a third byline class, distinct from both
*"By <user>"* (user-created) and *"By Spotify"* (editorial), and it does not
settle the question — it is equally consistent with "Spotify owns this object
and credits your prompt" and with "you own it and Spotify notes how it was
made". Taken together with the `37i9dQZF1` ID, the concern is neither confirmed
nor removed.

The API's `owner` field on `GET /v1/playlists/{id}` is the thing that decides
it, and that is one request away for anyone holding a token.

**2026-07-31, resolved in practice.** The owner can add tracks to the playlist,
reorder and delete its existing tracks, and rename it, all from the Spotify
mobile app. Spotify's own editorial and generated playlists permit none of
those. Whatever the ID namespace suggests, the object behaves as a user-owned
playlist, and §4.3's rule keys on ownership.

So the structural risk is off the table: §8 can be built as specified, and the
duplication fallback in `docs/pools.md` is unlikely to be needed. **V-1 stays
formally open** — it asks whether `/items` actually returns contents, and only
the capture answers that — but what remains is a question about *field names*,
which is a DTO fix, not a redesign. `PoolManager` is safe to write against §8.

Worth recording that the `37i9dQZF1` prefix was the weaker signal and reading
it as decisive would have been wrong. Editability is a direct observation of
the property §4.3 cares about; the prefix was an inference from a convention
Spotify never documented.

**It does not change what to do, only how much it matters.** Run
`Scripts/capture-fixtures.sh` against one of the real pools. A populated
`items.items[].item` settles V-1 in the good direction and this note becomes a
footnote. A 200 with `items` null, or a 404, means the duplication fallback in
`docs/pools.md` is the actual plan, and it is much cheaper to know that before
`PoolManager` is written than after.

Do not put the pool IDs in the repository. They are not secret, but this
repository is public and §7e already redacts them out of the captured fixtures;
committing them to source would undo that for no gain. Configuration is M4.

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
diverge silently. Several times now the right answer was to change the spec.
All are listed here so the amendments are reviewable in one place rather than
only as diffs.

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

- **2026-07-31 — §11.2 rewritten after a UX pass.** Owner's decisions
  throughout. Four parts, of which only the last two actually diverge:
  - **Two horizontally-paged screens, neither scrolling**, replacing "one
    screen". Forced by the Digital Crown: it cannot be both the scroll gesture
    and the zone lock. Freeing it retires the two undiscoverable gestures as a
    side effect, because the controls page gives every action a label. Costs one
    swipe to reach `End workout`, which is the idiom Apple's Workout app already
    uses.
  - **The override indicator is a state of the zone row**, not an element of its
    own — outlined capsule, lock glyph, and the row is the "resume auto" button.
    §6.6 asks for an unambiguous indicator; it does not ask for a dedicated row,
    and on a watch a row meaningful 5 % of the time is expensive.
  - **"Next committed track" merged into a decision line.** As a field of its
    own it was empty for roughly 90 % of every track. Merged with the status
    text it always says something.
  - **The countdown is coarse**, four steps rather than 180. §11.2 asks for a
    countdown two lines above forbidding continuously running animation. This
    reads the intent rather than the letter, and is the clearest divergence of
    the four. It turned out to be Always-On-native as a side effect.

- **2026-07-31 — §6.6's override no longer expires.** Owner's decision. The
  timeout earns its place only on the *inferred* trigger: a detected skip can
  be a false positive, and one that never lapsed would disable auto-control for
  a whole session. On a deliberate lock it does the reverse — 180 s matches no
  real interval, and the music starts moving again at a moment nobody chose.
  Since R-10 does not exist (D-7), every override today is deliberate and the
  timeout was doing no work.

  Two things went with it, and both are the point rather than collateral:
  - **The countdown**, and the five-second ticker that kept it honest. Two of
    the four defects found in the watch UI were in that machinery — a countdown
    that froze whenever heart rate stopped arriving, and a hold that lapsed
    without clearing its own cause or writing `override_cleared`. Removing the
    expiry removed both at the root rather than fixing them.
  - **The pause/resume trigger.** §6.2's stale path already holds the zone when
    a workout pauses, so the override was duplicating two other mechanisms —
    and with no expiry it would have been harmful, since watchOS auto-pauses
    workouts and auto-control would have stopped permanently with no action
    from the owner.

  `OVERRIDE_HOLD` stays in §6.7 marked dormant. The timeout was never wrong in
  general, only wrong for a deliberate lock.

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

### D-6. `SHORT_TRACK_THRESHOLD` read literally contradicts I2 — resolved in `CommitScheduler`

§6.7: "`SHORT_TRACK_THRESHOLD` | 25 s remaining | Commit immediately instead of
scheduling." §7.2 I2: "No `enqueue` before `estimatedEnd - COMMIT_OPEN`", and
`COMMIT_OPEN` is 20 s. For a track first seen with 21–25 s left, those two
sentences ask for opposite things.

**Resolved by waking early rather than committing early.** I2 is kept exactly
as written — the scheduler will not attempt anything above 20 s remaining — and
`SHORT_TRACK_THRESHOLD` instead governs *when the controller next looks*.

That is not a workaround; it is the hazard the constant is actually about.
`HEARTBEAT_POLL` is 30 s, so a track first seen with 23 s left would not be
looked at again until long after its deadline had passed. Waking 3 s later, at
the moment the window opens, fixes that completely. Committing 5 s early fixes
nothing that was broken, and costs an invariant that has a test and that G2
depends on.

`CommitScheduler.nextEvaluation(remaining:at:)` implements it as
`min(timeUntilNextSlot, HEARTBEAT_POLL)`, which subsumes the threshold entirely
— there is no branch on 25 s anywhere in the logic. `startedShort` is recorded
on the scheduler for the §11.3 log only, so M2 traces can still distinguish
these tracks when the constants get tuned.

If the literal reading was intended, the change is one line and I2's test has
to change with it. It should not change quietly.

### D-7. R-10 skip detection has no implementation, and its threshold decides how often the override is wrong

§6.6 lists a detected manual skip as an override trigger, and §11.2 now labels it `Skipped` on screen. Nothing detects one.

`ZoneModel` holds the override, `Controller.registerManualInput` sets it, and
`TrackClock` reports track changes and seeks — but no rule anywhere turns "the
track changed" into "the owner skipped". §6.6's most common trigger is,
at present, unreachable except through a manual zone lock.

The rule is not hard to state: a `.started` observation arriving while
`remaining` was still comfortably positive is a skip. **"Comfortably" is the
whole problem.** Set it too tight and ordinary §7.1 estimate drift near a
boundary reads as a skip, suspending auto-control for three minutes for no
reason the owner can see. Set it too loose and real skips go unnoticed, which
is the failure R-10 exists to prevent.

Deliberately not picked yet. The distribution of `estimatedEndDriftMs` in the
first M2 traces is exactly the evidence needed, and guessing before those exist
is the thing CLAUDE.md non-negotiable #4 is about. Until then the label on the
zone row is the mitigation: an override the owner did not ask for says so, and
the row saying it is the button that clears it.

### On Always-On, and one thing that cannot be fixed

§11.2 now specifies a reduced-luminance variant. Most of it is ordinary — drop
now-playing, promote the zone name over the capsules, return to the glance page
when the wrist drops.

One property is worth stating separately because it will look like a bug:

**Always-On staleness is a rendering property, and §6.2's stale detection
cannot see it.** During Always-On the workout session keeps delivering samples,
so `HRWindow` reports no gap and the stale treatment never fires — but the
pixels on screen may be a minute old. Nothing distinguishes an Always-On
snapshot from a live reading, and no API reports when the system last drew the
app.

There is no fix, only the knowledge. Accepted and recorded because "why did it
say 142 when I was clearly at 170" is exactly the kind of thing that erodes
trust in a system whose entire job is reacting to heart rate — and the answer
is not that the control law was wrong, it is that the display was old. **V-8**
measures the actual refresh budget and decides whether the decision line
belongs in Always-On at all.

### D-8. `locationType` — **settled: set it honestly, including `.outdoor`**

§10 pinned `locationType = .unknown`. That was free when the workout session
existed only to obtain heart rate and background runtime, and stopped being
free once R-14 made the saved workout a record the owner keeps: `.unknown`
gets a conservative energy estimate for exactly the activities most likely to
be used.

What made it non-obvious was battery. §11.2 said "battery matters more than
polish", and declaring `.outdoor` invites the system to use GPS for distance.

**Resolved 2026-07-31 by the owner: the battery bar is parity with other
workout apps, not minimalism.** §11.2 now says so directly. Spending roughly
what Apple's Workout app spends, to produce a workout record about as good as
Apple's Workout app produces, is the trade this project should make — and the
earlier framing would have declined it by default.

**Three tiers, only two of which are in scope.** Worth separating, because "add
GPS" covers wildly different amounts of work:

1. **`locationType` chosen per activity.** One enum on the configuration, no
   new permissions, no new code paths. In §11.2's idle-screen list, combined
   with activity type so it is a single choice rather than two.
2. **Location authorisation, for GPS-derived distance.** Small — a usage string
   and a prompt — but it adds a permission to onboarding, which is a real UX
   cost paid once. In scope under the parity bar.
3. **`HKWorkoutRouteBuilder`, for the route map in Fitness.** **Deferred, not
   rejected.** CoreLocation plumbing, continuous location collection, and a
   route object to manage — and §3 excludes GPS routes as a non-goal. Tier 1
   improves the estimate; only tier 3 draws the map.

**On tier 3, 2026-07-31:** the owner does not want a map *drawn in this app*,
and does want the option kept open for the workout to carry its route into
Fitness. Those are compatible — §3's non-goal is about bio-rhythm not becoming
a training log with its own map UI, not about the saved `HKWorkout` being
poorer than it needs to be, which is the same distinction §10 already draws for
energy data.

So the shape if it is picked up: attach an `HKWorkoutRoute` to the saved
workout under R-14, and render nothing. Fitness draws the map; this app never
does. That keeps every pixel of §11.2 unchanged and stays inside the parity
bar, since route collection is what any outdoor workout app already does.

Not built. Recorded so that picking it up later is an implementation task
rather than a fresh argument about §3.

### Product framing: the single-workout-session constraint is accepted

**2026-07-31, settled by the owner.** §15 lists "cannot coexist with another
workout app" as a known risk resolved as a product decision, and V-3 names
"product framing" among the things it blocks. That half is now answered: the
owner does not track personal records and wants heart rate and ring credit,
both of which R-14 provides.

Two consequences worth carrying forward:

- **R-14 is no longer a P2 nicety.** It is the entire mitigation for a
  structural platform constraint, and the thing that makes bio-rhythm
  acceptable as a replacement for the Workout app rather than an alternative to
  it. Its priority should be reconsidered against that.
- **Activity type moved out of M4** for the same reason (§11.2, idle screen).
  Configuration can wait; a year of sessions labelled `Other` cannot.

V-3 itself stays open — whether `startActivity` actually fails while another
app holds a session is still unmeasured, as is V-7's more dangerous reverse.
