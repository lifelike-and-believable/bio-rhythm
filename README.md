# bio-rhythm

A standalone watchOS app that steers Spotify playback by heart rate, choosing
which track plays next from one of five energy-tiered playlists.

Heart rate is already measured continuously and accurately on the wrist, and it
is a direct proxy for effort. Effort maps onto a small number of music energy
tiers. Closing the loop between the two removes the fiddling with a phone
mid-effort. The system never interrupts a track — it decides what plays *next*,
committing to the choice in the last twenty seconds of the current one.

Current scope: single user, sideloaded, not for distribution. `SPEC.md`
records a later commercial/App Store phase, but only behind the M2/M3
verification gates that keep the controller safe.

- **[The site](https://lifelike-and-believable.github.io/bio-rhythm/)** — what it is for, and how far along it is.
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

**Built, and never run.** The control law, the Spotify client and the whole
watch interface exist and are internally consistent. Every line of it has been
verified by CI and by nothing else — no session has taken place on a wrist.

Built: M0 (auth, token transfer, playback read), M1 (heart-rate window, zones,
workout session, telemetry), M2's control law (`ZoneModel`, `TrackClock`,
`CommitScheduler`, `PoolManager`, `Controller`), and the §11.2 watch UI.

Not built: M2's app-layer wiring — pools fetched into `PoolManager`, the
controller driven off the workout session. It is blocked on pool configuration,
which is M4.

`swift test` covers `HRDJCore` and `SpotifyKit` with no simulator, network or
credentials, and that constraint is worth keeping.

**M2 is observe-only on purpose.** `Controller.actuationEnabled` defaults to
false and gates exactly one statement — the `enqueue`. Everything upstream runs
identically either way, so the traces are the real thing minus its last step.
The §6.7 constants get tuned against those traces before the loop is allowed to
drive anything (§13: *do not compress M2*).

Ten things are unverified: §12's **V-1 through V-8**, and the on-device exit
criteria for **M0** and **M1**. All ten are listed in
[`docs/verification.md`](docs/verification.md).
