#!/usr/bin/env bash
#
# Capture real Spotify responses into Tests/SpotifyKitTests/Fixtures.
#
# CLAUDE.md forbids hand-written fixtures, so this is the only sanctioned way
# to add one. It also answers V-1: whether a Prompted Playlist returns an
# `items` object at all.
#
#   export SPOTIFY_TOKEN='BQ...'        # user token with the §9.2 scopes
#   export POOL_PLAYLIST_ID='37i9...'   # a Prompted Playlist you own
#   Scripts/capture-fixtures.sh
#
# Start playback somewhere first, or /me/player returns 204 and the capture is
# worthless.

set -euo pipefail

: "${SPOTIFY_TOKEN:?set SPOTIFY_TOKEN to a user access token}"
: "${POOL_PLAYLIST_ID:?set POOL_PLAYLIST_ID to a playlist you own}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Tests/SpotifyKitTests/Fixtures"
RAW="$ROOT/Scripts/.captures"
API="https://api.spotify.com/v1"

mkdir -p "$OUT" "$RAW"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for redaction. brew install jq" >&2
  exit 1
fi

# Strip the fields that are bulky or identifying and that no DTO reads. Track
# and artist names are left alone — they are the data under test.
redact() {
  jq 'walk(
        if type == "object"
        then del(.images, .external_urls, .owner, .followers, .href, .snapshot_id)
        else .
        end
      )'
}

fetch() {
  local name="$1" path="$2"
  local status
  echo "→ $path"
  status=$(curl -sS -w '%{http_code}' -o "$RAW/$name.json" \
    -H "Authorization: Bearer $SPOTIFY_TOKEN" \
    "$API$path")

  case "$status" in
    200)
      redact < "$RAW/$name.json" > "$OUT/$name.json"
      echo "  captured $OUT/$name.json"
      ;;
    204)
      echo "  204 No Content — nothing is playing. Start a track and retry." >&2
      ;;
    403)
      echo "  403 — withdrawn endpoint, missing scope, or lapsed Premium (SPEC.md §4.4, §11.4)." >&2
      cat "$RAW/$name.json" >&2 || true
      echo >&2
      ;;
    404)
      echo "  404 — no active device, or the playlist is not visible to this user." >&2
      ;;
    *)
      echo "  HTTP $status" >&2
      cat "$RAW/$name.json" >&2 || true
      echo >&2
      ;;
  esac
}

fetch player-state  "/me/player"
fetch devices       "/me/player/devices"
fetch queue         "/me/player/queue"
fetch playlist      "/playlists/$POOL_PLAYLIST_ID"

# The rename is the thing being verified: /items, not /tracks (SPEC.md §4.3).
fetch playlist-items "/playlists/$POOL_PLAYLIST_ID/items?limit=20"

# The playlist ID is not a secret, but there is no reason to publish it either.
if [ -f "$OUT/playlist.json" ] || [ -f "$OUT/playlist-items.json" ]; then
  for file in "$OUT/playlist.json" "$OUT/playlist-items.json"; do
    [ -f "$file" ] || continue
    sed -i.bak "s/$POOL_PLAYLIST_ID/REDACTED_PLAYLIST_ID/g" "$file"
    rm -f "$file.bak"
  done
fi

echo
echo "Raw captures kept in $RAW (gitignored). Read each file in $OUT before committing."
echo "Then record the V-1 answer in docs/verification.md."
