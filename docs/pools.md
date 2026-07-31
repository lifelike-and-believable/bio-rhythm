# The pools

Everything the control law does is choose *which pool the next track comes
from*. The pools decide what the music actually is. That makes this the one
part of the system with no code in it and the largest effect on whether it
feels right.

SPEC.md §4.5: Prompted Playlists have no API. They are created by hand in the
Spotify mobile app, and the watch app only ever reads them. Nothing in the
runtime path depends on generating or refreshing one.

---

## Why this matters more than it looks

Two consequences worth having in mind before writing anything.

**The prompts define what the zones mean.** `Z3` is not "tempo music" in the
abstract — it is whatever the Z3 prompt returned from your library. The §6.7
constants get tuned in M2 against real logs, and those logs are only meaningful
relative to the pools that produced them. Rewriting a prompt after tuning
invalidates some of the tuning.

**Overlap is expensive.** §8 keeps a session-wide `playedURIs` set: a track
played from Z2 is ineligible in Z3 for the rest of the session. Tracks that sit
in two pools therefore shrink the effective size of both. Prompts that produce
distinct sets are worth more than prompts that each produce a good set.

---

## Sample prompts

**These are a starting point, not a recommendation.** I do not know your
library, your training, or what you actually want to hear at threshold. Treat
them as something to react to — the useful version is the one you rewrite after
seeing what the first attempt returns.

Prompt in terms of **energy and feel**, not genre. The whole design rests on
energy tiers; a prompt that names a genre gets you a genre, whose energy varies.

### Z0 — Meditation (below 34% maxHR — 62 bpm at maxHR 182)

> Still, spacious, unhurried music for sitting quietly. No percussion driving
> it, no builds, nothing that resolves into a groove. Long and slow is fine.

You reach this sitting still, not moving, so it is the only pool where
"ambient" is the right answer rather than the trap it is in Z1.

**You may not want a fifth playlist for this**, and you do not have to have one.
Pointing Z0 and Z1 at the same playlist ID is a supported configuration (§8):
you get the zone, the indicator, and the telemetry, and the music simply does
not change when you cross 62. Worth starting there and splitting later if the
Z1 prompt turns out to be too energetic for sitting still.

Sizing is also different: you visit this zone for long stretches at a time or
not at all, so 10–15 tracks is enough if you do curate it separately.

### Z1 — Recovery (34–60% maxHR — 62 to 109 bpm at maxHR 182)

> Calm, steady tracks for warming up and cooling down. Low intensity but not
> sleepy — something with a pulse I can walk to. No abrupt drops or big builds.

The default zone — warm-up, cool-down, walking around, and whatever recovery
you do between hard efforts. Most of a non-workout day sits here. The trap is
drifting into ambient: this still has to be listenable while moving, which is
what separates it from Z0.

### Z2 — Aerobic (60–70%)

> Easy, steady groove for a conversational-pace run. Consistent energy the whole
> way through, nothing that spikes or drops out.

This and Z3 are where most of a session lives, so these two want to be the
biggest pools. A likely fallback pool as well (see below).

### Z3 — Tempo (70–82%)

> Driving, propulsive tracks for sustained hard effort. Forward momentum,
> steady intensity, no long quiet intros.

The long-intro exclusion is worth keeping. Commits land in the last twenty
seconds of the previous track (§6.7), so a track that opens with forty seconds
of atmosphere spends the first part of a hard effort feeling like a mistake.

### Z4 — Hard (above 82%)

> Aggressive, high-intensity tracks for maximum effort intervals. Immediate,
> relentless, no slow builds.

Usually the smallest pool and the one visited least, but visited when you have
the least patience for a wrong choice. The one-step limit (§6.5) means you only
arrive here after climbing through Z2 and Z3, so it is genuinely the top end.

---

## Sizing

A 60-minute session at roughly 3.5 minutes per track is about 17 commits, and
Z2/Z3 will take most of them.

Aim for **30+ tracks in Z2 and Z3**, 20+ in Z1 and Z4, and 10+ in Z0 if it has
a playlist of its own. Below that, §8's
exhaustion path starts clearing the played-set mid-session and you hear repeats.
It handles that case correctly; it is just not a nice experience.

---

## The auto-refresh decision

Prompted Playlists can be scheduled to refresh daily or weekly. §4.5 is why the
app fetches pools fresh at every session start and never persists contents:
whatever you choose here, the runtime copes.

It is still a real choice, and it cuts against itself:

| | Refresh on | Refresh off |
|---|---|---|
| Music | Stays fresh, less repetition across weeks | Goes stale; you learn the pools |
| M2 tuning | Each session's logs describe slightly different pools | Logs are comparable across sessions |
| Prompt drift | New misfiles arrive continuously | One round of blocklisting settles it |

**My suggestion: leave refresh off until M2's tuning is done**, then turn it on.
M2 exists to produce comparable traces across several real workouts (§13,
"do not compress M2"), and pools that change underneath you make two sessions
harder to compare. Once §6.7 is settled, drift in pool contents costs much less.

Also unresolved: **V-6** asks whether a refresh changes the playlist *ID* or
only its contents. If IDs rotate, the configured pool IDs have to be re-pointed
every time, and R-13 needs a repair flow. Another reason to leave it off for
now — with refresh off, V-6 cannot bite.

---

## Recording the IDs

For each playlist: share → copy link → take the segment between `/playlist/`
and `?`. Five pools, though two of them may be the same ID.

```
https://open.spotify.com/playlist/<22 characters>?si=…
                                  └──── this ────┘
```

Configuration is M4 (R-13 wants all of this editable without a rebuild). Until
then the five IDs and the fallback pool go wherever M3 first needs them; there
is nothing to fill in yet, which is why this document stops at "write them
down".

**The fallback pool** (§7.3) is played as the context at session start and is
what you hear when a commit is missed. It should be Z2 or Z3 — whichever you
expect to occupy most — so that a miss yields a plausible mid-energy track
rather than something jarring.

---

## If V-1 fails

**V-1** asks whether Prompted Playlists return their contents through
`GET /v1/playlists/{id}/items` at all. It is unanswered, and it gates §8
entirely.

If they do not, the fallback is to duplicate each pool into an ordinary
playlist you own: same pools, same IDs recorded the same way, created by
hand instead. §15 notes this costs nothing in code — pools are ordinary
playlist reads either way — but it does mean re-duplicating whenever you
regenerate, which is a second reason to leave auto-refresh off.

Run `Scripts/capture-fixtures.sh` against one of these playlists to find out.
`docs/SETUP.md` §7 has the procedure and what each outcome means.

---

## Prompt drift

§4.5 expects the occasional misfiled track — something mellow landing in the
hard pool. The mitigation is the blocklist (R-11): long-press the now-playing
track to add its URI, and it never reappears in any pool. That is M4.

Until then, a wrong-energy track is something to note and live with. If one
pool produces them repeatedly, that is evidence about the prompt rather than
about the track — rewrite the prompt rather than blocklisting your way out of
it.
