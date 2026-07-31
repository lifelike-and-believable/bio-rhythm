# bio-rhythm

A standalone watchOS app that steers Spotify playback by heart rate, choosing
which track plays next from one of five energy-tiered playlists.

Heart rate is already measured continuously and accurately on the wrist, and it
is a direct proxy for effort. Effort maps onto a small number of music energy
tiers. Closing the loop between the two removes the fiddling with a phone
mid-effort. The system never interrupts a track — it decides what plays *next*,
committing to the choice in the last twenty seconds of the current one.

Single user, sideloaded, not for distribution.

- **[`SPEC.md`](SPEC.md)** — requirements and design. Authoritative.
- **[`CLAUDE.md`](CLAUDE.md)** — working rules for anyone, human or agent, changing this repo.
- **[`docs/SETUP.md`](docs/SETUP.md)** — Spotify registration, local config, onboarding.
- **[`docs/pools.md`](docs/pools.md)** — the playlists: prompts, sizing, and the auto-refresh decision.
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

**M0, written but unverified.** Auth and playback reading exist and are unit
tested; nothing has run on a device yet. `swift test` covers `HRDJCore` and
`SpotifyKit` with no simulator, network, or credentials.

There is no control loop yet. M2 is observe-only on purpose — the constants in
§6.7 get tuned against logs from real workouts before the loop is allowed to
drive anything.
