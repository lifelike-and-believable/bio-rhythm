# Synthetic HR traces

Unlike the SpotifyKit fixtures, these are **meant** to be authored — SPEC.md
§14.1 calls for synthetic traces, not recordings. They arrive with the code
they exercise, because a trace is only meaningful next to the zone sequence it
is asserted to produce, and `ZoneModel` does not exist yet (M1/M2).

Each file is a timestamped HR series: `[{"tSeconds": 0.0, "bpm": 62}, …]`.

| File | Shape | Expectation |
|---|---|---|
| `ramp_up.json` | 60 → 175 bpm over 20 min | Monotonic non-decreasing zones, one step at a time |
| `ramp_down.json` | Mirror of the above | Monotonic non-increasing |
| `boundary_oscillation.json` | ±3 bpm around a boundary for 15 min | **Zero zone changes.** The hysteresis test, and the most important one in the suite |
| `spiky.json` | 10 s spikes into Z4 from a Z2 baseline | No zone change — dwell rejects them |
| `dropout.json` | 90 s sensor gap mid-session | Zone held, `hr_sample_gap` logged, commits still attempted |
| `interval.json` | 4 × 4 min intervals | Step limit visibly lags effort; never jumps two zones |

Drive all of them through `FakeClock` and `FakeSpotify`, the latter with
injectable per-call latency and failure modes (timeout, 429 with `Retry-After`,
404, 403, malformed body).
