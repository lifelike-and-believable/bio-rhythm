# CLAUDE.md

## What this project is

A standalone watchOS app that steers Spotify playback by heart rate, choosing which track plays next from one of five energy-tiered playlists. Single user, sideloaded, not for distribution.

**`SPEC.md` in the repo root is authoritative.** Read it before making changes. If a request conflicts with it, say so rather than silently diverging.

## Non-negotiables

1. **Never interrupt a playing track.** The automatic controller must not be able to call pause, skip, previous, or seek. This is enforced by protocol separation (`SPEC.md` §5.3), not by convention. Do not add transport methods to `PlaybackReading` or `PlaybackQueueing`.
2. **`Sources/HRDJCore` imports nothing but the standard library.** No HealthKit, no SwiftUI, no `URLSession`, no `Date()`. Time comes from the injected `Clock`. If control logic cannot be tested with a fake clock and a synthetic HR trace, it is in the wrong module.
3. **The Spotify Web API changed in Nov 2024 and Feb 2026.** Pre-training knowledge is wrong in specific, load-bearing ways. `SPEC.md` §4 is the only endpoint list to work from. Notably: `audio-features`, `audio-analysis`, and `recommendations` are gone; playlist item endpoints are `/items`, not `/tracks`. Do not invent endpoints. If §4 lacks what you need, stop and ask.
4. **Do not tune the constants in §6.7 speculatively.** They are tuned from real session telemetry during milestone M2. Changing them without log evidence is guesswork dressed as improvement. Two entries in that table are exceptions because they are personal choices rather than tuning parameters: `maxHR` and `MEDITATION_CEILING`. Those the owner sets; everything else waits for logs.
5. **Invariants I1–I6 (§7.2) each have a test.** If you change the commit scheduler, the tests come first.

## Build and test

```bash
swift build
swift test                          # HRDJCore + SpotifyKit, no device needed
cd Apps && xcodegen generate        # .xcodeproj is generated, not committed
xcodebuild -scheme WatchApp -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' build
```

First-time setup (Spotify app registration, `Config.local.xcconfig`, onboarding):
`docs/SETUP.md`.

`HRDJCore` tests must pass without a simulator, a network, or credentials. Keep it that way.

## Repo conventions

- Swift 6 strict concurrency. `HRDJCore` types are `Sendable`; the controller is an `actor`.
- No force unwraps outside tests.
- Response fixtures in `Tests/SpotifyKitTests/Fixtures` are **captured from real API calls**, never hand-written. If you need a new one, ask for a capture rather than authoring it.
- Secrets never in the repo. Client ID goes in a gitignored `Config.local.xcconfig`.
- **Accessibility is part of a view's state machine, not a label bolted onto it.** Three rounds of watch UI produced three accessibility defects with one shape: a view whose *visible* state was carefully conditional carried a single fixed VoiceOver string and a single fixed trait set. The zone row announced itself as a button while inert; it offered "double tap to choose a zone with the crown" before any zone existed, and again in Always-On, where raising the wrist wakes the screen before a touch could land. When interactivity is conditional, `accessibilityLabel` and `accessibilityAddTraits` are conditional on **the same thing** — written in the same commit, not the next one. A label naming a gesture the current state cannot accept is worse than no label, because it is confidently wrong.

## Current state

Milestone: **M2's `HRDJCore` half is complete and merged. Nothing has ever run
on a device.**

Everything compiles and the library tests pass — CI builds both SwiftPM targets
and both app targets on every pull request (`.github/workflows/ci.yml`, Xcode
pinned). That is the *only* verification any of this has had.

### Built

- **M0** — auth, token transfer, playback read.
- **M1** — `HRWindow` (§6.2), `ZoneBoundaries` (§6.1), `ControlConfiguration`
  (§6.7), the `HKWorkoutSession` lifecycle, JSONL telemetry.
- **M2, control law** — `ZoneModel` (§6.3–§6.6), `TrackClock` (§7.1),
  `CommitScheduler` (§7.2), `PoolManager` (§8), `Controller` (§7). All five
  test against a fake clock with no simulator, network or credentials.
  Invariants I1–I4 live in `CommitSchedulerTests`, I5 in `ZoneModelTests`, I6
  in `ProtocolSeparationTests`.
- **The §11.2 UI** — two paged screens, the zone row as override indicator,
  focus-gated Crown zone lock, idle screen with the activity picker, R-14 on,
  Always-On variant.

### Not built

- **M2's app-layer wiring.** Pools fetched through `SpotifyKit` into
  `PoolManager`, `Controller.tick()` driven off the workout session,
  `DecisionRecording` pointed at `TelemetryLog`. Until this exists the watch
  runs M1 behaviour: heart rate, zone, now playing, and no decisions.
- **Pool configuration.** Five Prompted Playlists exist, and their IDs have
  nowhere to live until M4 (R-13). This is what blocks the wiring above, and
  why §7.4's `FETCHING_POOLS` progress display was deliberately not faked.
- **R-10 skip detection** (D-7), `PoolManager`'s network side, R-15's session
  summary.

### On-device exit criteria — all open

- **M0** — the watch reads playback state with the phone powered off.
- **M1** — a 30-minute session holds background runtime and logs continuous HR.
- **V-1** — `Scripts/capture-fixtures.sh` against a real Prompted Playlist. The
  last thing that can invalidate the DTOs. The *structural* risk is resolved:
  the pools are editable, so §8's duplication fallback is unlikely to be needed.

**§12 now has eight items, V-1 through V-8, none answered.** V-7 (a workout
starting while this app holds a session) and V-8 (the Always-On redraw budget)
are both testable in the same sitting as M1's exit criterion.

### Amendments and open questions

`docs/verification.md` is the record. Settled: **D-1** (playback protocols live
in `HRDJCore`), **D-5** (three gaps §6 leaves in zone selection), **D-6**
(`SHORT_TRACK_THRESHOLD` contradicts I2; resolved by waking early rather than
committing early), **D-8** (`locationType` set honestly). Open: **D-2** (I6 is
not testable as §5.3 words it), **D-3** (`Clock` shadows `Swift.Clock`), **D-4**
and **D-7**, both of which want M2 logs rather than argument.

SPEC.md has been amended, not merely followed, in several places — §5.2/§5.3,
§6.1 (the meditation zone), §6.6 (the override no longer expires), §10, §11.2
(rewritten). Each is listed in `docs/verification.md` under "Deliberate changes
to SPEC.md". Read that before assuming the spec and the code disagree by
accident.

At `maxHR` 182 the zone thresholds are **62 / 109 / 127 / 149** bpm.
