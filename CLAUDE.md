# CLAUDE.md

## What this project is

A standalone watchOS app that steers Spotify playback by heart rate, choosing which track plays next from one of four energy-tiered playlists. Single user, sideloaded, not for distribution.

**`SPEC.md` in the repo root is authoritative.** Read it before making changes. If a request conflicts with it, say so rather than silently diverging.

## Non-negotiables

1. **Never interrupt a playing track.** The automatic controller must not be able to call pause, skip, previous, or seek. This is enforced by protocol separation (`SPEC.md` §5.3), not by convention. Do not add transport methods to `PlaybackReading` or `PlaybackQueueing`.
2. **`Sources/HRDJCore` imports nothing but the standard library.** No HealthKit, no SwiftUI, no `URLSession`, no `Date()`. Time comes from the injected `Clock`. If control logic cannot be tested with a fake clock and a synthetic HR trace, it is in the wrong module.
3. **The Spotify Web API changed in Nov 2024 and Feb 2026.** Pre-training knowledge is wrong in specific, load-bearing ways. `SPEC.md` §4 is the only endpoint list to work from. Notably: `audio-features`, `audio-analysis`, and `recommendations` are gone; playlist item endpoints are `/items`, not `/tracks`. Do not invent endpoints. If §4 lacks what you need, stop and ask.
4. **Do not tune the constants in §6.7 speculatively.** They are tuned from real session telemetry during milestone M2. Changing them without log evidence is guesswork dressed as improvement.
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

## Current state

Milestone: **M0 written, not yet verified.** SwiftPM packages, `SpotifyKit` auth
and player/playlist endpoints, iOS companion PKCE flow, token transfer to the
watch Keychain, and a watch screen showing the current track all exist. None of
it has been compiled or run — it was authored in an environment with no Swift
toolchain and no credentials. Expect to fix build errors on first `swift build`.

M0 is complete when the exit criterion in §13 is met on device: the watch reads
playback state with the phone off (`docs/SETUP.md` step 6).

Verification checklist §12 is unanswered — all six still open. `docs/verification.md`
records that, plus three design questions M0 surfaced; **D-1 (where the playback
protocols live) has to be settled before M2 starts.**

Not started: `HRWindow`, `ZoneModel`, `TrackClock`, `CommitScheduler`,
`PoolManager`, `Controller`, HealthKit, telemetry writing. `Decision` (§11.3)
exists as a type so the log format is fixed before it starts carrying data.
