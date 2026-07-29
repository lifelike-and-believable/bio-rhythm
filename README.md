# bio-rhythm

A standalone watchOS app that steers Spotify playback by heart rate, choosing
which track plays next from one of four energy-tiered playlists.

Heart rate is already measured continuously and accurately on the wrist, and it
is a direct proxy for effort. Effort maps onto a small number of music energy
tiers. Closing the loop between the two removes the fiddling with a phone
mid-effort. The system never interrupts a track — it decides what plays *next*,
committing to the choice in the last twenty seconds of the current one.

Single user, sideloaded, not for distribution.

- **[`SPEC.md`](SPEC.md)** — requirements and design. Authoritative.
- **[`CLAUDE.md`](CLAUDE.md)** — working rules for anyone, human or agent, changing this repo.
- **[`docs/SETUP.md`](docs/SETUP.md)** — Spotify registration, local config, onboarding.
- **[`docs/verification.md`](docs/verification.md)** — what nobody has checked yet, and open design questions.

## Layout

```
Sources/HRDJCore     Control logic. Standard library only — no Foundation,
                     no HealthKit, no network, no wall clock.
Sources/SpotifyKit   Web API client, PKCE auth, rate limiting.
Apps/WatchApp        The watch app. Everything that runs during a workout.
Apps/iOSCompanion    Onboarding only: the OAuth leg watchOS cannot perform.
```

## Status

**M1 written; M0 and M1 both unverified on device.** Auth, token transfer,
playback reading, workout-session lifecycle, HR observation, raw zone display,
and JSONL telemetry exist and are unit tested where possible. Nothing has run on
a watch yet.

`swift test` covers `HRDJCore` and `SpotifyKit` with no simulator, network, or
credentials. M0 exits when the watch reads playback state with the phone off.
M1 exits after a 30-minute on-wrist session holds background runtime and logs
continuous HR.

There is no control loop yet. M2 is observe-only on purpose — the constants in
§6.7 get tuned against logs from real workouts before the loop is allowed to
drive anything.
