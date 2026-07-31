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

Milestone: **M1 written; M0 and M1 both unverified on device.**

Everything compiles and the library tests pass — CI builds both SwiftPM targets
and both app targets on every PR (`.github/workflows/ci.yml`, Xcode pinned).
Nothing has run on a watch.

- **M0** (auth, token transfer, playback read) is complete when §13's exit
  criterion is met on device: the watch reads playback state with the phone off
  (`docs/SETUP.md`).
- **M1** adds `HRWindow` (§6.2), `ZoneBoundaries` (§6.1), `ControlConfiguration`
  (§6.7), the `HKWorkoutSession` lifecycle, and JSONL telemetry writing. The
  `HRDJCore` half is tested against a fake clock; the HealthKit half can only be
  proven on a wrist. Exit: a 30-minute session holds background runtime and logs
  continuous HR.

Verification checklist §12 is unanswered — all six still open. `docs/verification.md`
records that, the design questions, and the two places SPEC.md has been amended
rather than followed. **D-1 is settled: the playback protocols live in
`Sources/HRDJCore/Playback.swift` and `SpotifyKit` conforms to them.** §5.2/§5.3
were amended to match. D-2, D-3 and D-4 are open; none blocks M2.

The **meditation zone** (Z0, below 34 % of `maxHR` — 62 bpm at 182) is the
second amendment. Adding it shifted every zone index up by one; every threshold
is still a percentage of `maxHR`, with no exceptions. See §6.1 and
`ZoneBoundaries`. Z0 has a `PoolID` but no playlist yet; `docs/pools.md` covers
both curating one and pointing Z0 at the Z1 playlist instead. Nothing consumes
pools until M3.

Not started: `ZoneModel` hysteresis/dwell/step-limit, `TrackClock`,
`CommitScheduler`, `PoolManager`, `Controller`. The zone shown on screen in M1
is the raw §6.1 mapping and will flicker on a threshold — that is what §6.3
exists to fix, in M2.
