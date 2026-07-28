# Captured response fixtures

**Every file in this directory is captured from a real API call. Never write one by hand.**
(CLAUDE.md, "Repo conventions".)

The DTOs in `Sources/SpotifyKit/DTOs/` were written from SPEC.md §4.3's
description of the February 2026 renames, not from an observed response. Nobody
has seen the real shapes yet. A hand-written fixture would encode the same
guess twice and the tests would agree with themselves.

`FixtureDecodingTests` reports a known issue for each fixture that is missing,
so an empty directory shows up as pending rather than as a pass.

## Capturing

```bash
export SPOTIFY_TOKEN='BQ...'          # a user token with the §9.2 scopes
export POOL_PLAYLIST_ID='37i9...'     # a Prompted Playlist you own
Scripts/capture-fixtures.sh
```

Start music playing on some device first, or `player-state.json` captures a 204
and proves nothing.

## Expected files

| File | Endpoint | Notes |
|---|---|---|
| `player-state.json` | `GET /v1/me/player` | Capture mid-track, while playing |
| `playlist-items.json` | `GET /v1/playlists/{id}/items` | **This is the V-1 evidence.** Against a real Prompted Playlist |
| `playlist.json` | `GET /v1/playlists/{id}` | Confirms the nested `items` object |
| `devices.json` | `GET /v1/me/player/devices` | With the watch awake and visible |
| `queue.json` | `GET /v1/me/player/queue` | After an `enqueue`, for V-4 |

## Redaction

The capture script strips `images`, `external_urls`, and the `owner` block, and
rewrites the playlist ID it was given. It does not attempt to remove track or
artist names — those are the data under test. Read a capture before committing
it and confirm you are content for it to be in the repo.
