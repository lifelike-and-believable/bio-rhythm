# Field test checklist

Manual checks for SPEC.md §14.4. Record dated results in
`docs/verification.md` when they answer one of the V-items; otherwise keep notes
with the session telemetry export.

## Before each field test

- Confirm the watch app is freshly installed and provisioned.
- Confirm Spotify Premium is active on the app-owner account.
- Confirm the watch has a known network path without the phone.
- Start playback before beginning the session, unless the scenario says
  otherwise.
- Preserve the JSONL telemetry file after the run.

## M0 / M1 checks

- [ ] Phone powered fully off; watch still reads playback state.
- [ ] 30-minute on-wrist session keeps the workout session alive.
- [ ] HR samples continue to arrive during the session.
- [ ] JSONL telemetry contains `session_start`, HR observations, and
      `session_end`.
- [ ] Raw zone display follows HR and may flicker at thresholds, as expected
      before M2 hysteresis.

## M2 observe-only checks

- [ ] Airplane mode mid-session; HR sampling and telemetry continue.
- [ ] Spotify app force-quit on the playback device; observe and log degraded
      state without actuation.
- [ ] Manual skip; observe whether it is detected and logged.
- [ ] Pause and resume; observe whether commits would be suspended while paused.
- [ ] Another workout app already recording; app surfaces the single-session
      conflict clearly.
- [ ] Watch battery under 10%; session behaviour and telemetry are recorded.
- [ ] Cold-hands / poor-contact session; sensor dropout is logged and zone is
      held.

## M3 actuation checks

- [ ] Queued track reliably plays next when the context is a shuffled playlist.
- [ ] Forced commit failure falls back to the configured context without a gap.
- [ ] Ten consecutive sessions complete with zero system-caused mid-track
      interruptions.
- [ ] Commit miss rate stays under the M3 exit threshold.
