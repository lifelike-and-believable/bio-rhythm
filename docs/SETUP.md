# Setup

One-time setup for the owner's machine, phone, and watch, then the two checks
that close M0: the §13 exit criterion on device, and the fixture capture that
answers **V-1**.

Everything here is done once. Nothing in it is needed during a workout.

---

## 1. Register the Spotify app

1. Sign in at <https://developer.spotify.com/dashboard> **with the account that
   holds Premium**. As of Feb 2026 a Development Mode app requires the *app
   owner* to hold active Premium, not just the listening user (§4.1). If you
   have more than one account, this must be the Premium one.
2. Create an app. The name and description do not matter.
3. Add redirect URI **`biorhythm://callback`** — exactly that, no trailing
   slash. It has to match `SPOTIFY_REDIRECT_URI` character for character or the
   callback silently never returns.
4. Add a second redirect URI **`http://127.0.0.1:8888/callback`**. The app does
   not use it; it makes getting a token for step 5 much easier.
5. Under the app's user management, add your own Spotify account. Development
   Mode allows 5 users and you need 1.
6. Copy the Client ID.

Do not request Extended Quota Mode. It requires large MAU now and is not a
fallback (§4.1).

## 2. Local configuration

```bash
cp Config.example.xcconfig Config.local.xcconfig
```

Replace `your_client_id_here` with the Client ID. Leave `SPOTIFY_REDIRECT_URI`
alone — the `$(SLASH)` indirection is a workaround for `//` starting a comment
in xcconfig, not a typo.

`Config.local.xcconfig` is gitignored. `git status` should show nothing.

## 3. Build the libraries

```bash
swift build
swift test
```

`HRDJCore` and `SpotifyKit` tests run with no simulator, no network, and no
credentials. Keep it that way — it is the reason the control law is testable at
all. CI runs exactly this on every push.

## 4. Generate the Xcode project

```bash
brew install xcodegen
cd Apps && xcodegen generate
open BioRhythm.xcodeproj
```

The `.xcodeproj`, the generated Info.plists, and the generated entitlements are
all gitignored; `Apps/project.yml` is the source of truth. Building the project
by hand in Xcode works too — `project.yml` then serves as the checklist of what
each target needs.

Set your signing team on both targets. **On a free Apple ID the provisioning
lasts 7 days** and the app stops launching afterwards. That is normal for a
sideloaded build and not a bug in this code. A paid account gives a year.

## 5. Onboarding — the order matters

1. **Install the watch app first.** Run the `WatchApp` scheme to the physical
   watch. This has to happen before step 3: `WatchLink.send` checks
   `isWatchAppInstalled` and refuses with *"Install the bio-rhythm watch app
   from the Watch app first"* otherwise. That message is the code working, not
   failing.
2. Run `iOSCompanion` to the phone.
3. Tap **Connect Spotify**, sign in, approve the four scopes (§9.2).
4. The companion hands the refresh token over with `transferUserInfo`, which the
   system queues and retries. It can take a moment and does not need the watch
   app in the foreground. The phone shows a pending count while it is
   outstanding.
5. Open the watch app. It should leave "Waiting for the phone" and show a track,
   or "Nothing playing" if nothing is.

## 6. The M0 exit criterion

Play something on any device. **Power the phone fully off** — not locked, not
Bluetooth off — and open the watch app. It should still show the track, having
refreshed its own access token against the Spotify accounts service.

That is §13's exit criterion: the phone is needed once, for onboarding, and
never again (G3).

> **Check this first if the test cannot pass.** A GPS-only Apple Watch reaches
> the network over Wi-Fi only. With the phone off it needs a Wi-Fi network it
> already knows. If it cannot get online at all, that is the network, not the
> app.

Record the result in `docs/verification.md` against **V-5**, with the date and
whether it was LTE or Wi-Fi.

---

## 7. Capture API fixtures — and answer V-1

This is the second gating item. **V-1 blocks all of §8**: if Prompted Playlists
do not return an `items` object, pool management has to become manually
duplicated ordinary playlists, and it is much cheaper to know that before
`PoolManager` is written than after.

It doubles as the only check on whether the post-Feb-2026 DTO field names in
`Sources/SpotifyKit/DTOs/` are right. They were written from §4.3's description,
not from an observed response.

### 7a. Get a user token

Easiest: the "Try it" console on the Web API reference pages at
developer.spotify.com. Pick an endpoint such as *Get Playback State* and it
mints a token for your account; select all four scopes from §9.2.

That area of the site has been reorganised more than once, so if the console is
gone, the fallback is a temporary `print` of the access token in
`NowPlayingModel.refresh()`, read from the Xcode console.

Tokens last about an hour. Capture in one sitting.

### 7b. Find a Prompted Playlist ID

In the Spotify mobile app: open the Prompted Playlist → share → copy link. The
ID is the segment after `/playlist/` and before the `?`:

```
https://open.spotify.com/playlist/<22 characters>?si=…
                                  └──── this ────┘
```

The example used to be a real ID here, and it was Spotify's own *Today's Top
Hits*. That is a bad thing to illustrate with, given that V-1 turns entirely on
who **owns** the playlist — see the note under V-1 in
[`docs/verification.md`](verification.md).

Use a real Prompted Playlist, not an ordinary one. Whether *that specific kind*
is readable is the entire question.

If you have not created the pools yet, [`docs/pools.md`](pools.md) covers the
prompts, how big each pool wants to be, and why auto-refresh is worth leaving
off until M2's tuning is finished. There are five now — Z0 was added with the
meditation zone — but Z0 can point at the Z1 playlist, so four is enough to
answer V-1 and to start M3.

Creating the pools is the one setup task that needs the phone rather than the
Mac, so it is worth doing whenever you have the Spotify app open and a moment,
independently of everything above.

### 7c. Run it

```bash
brew install jq                 # the script needs it for redaction
export SPOTIFY_TOKEN='BQ...'
export POOL_PLAYLIST_ID='37i9...'
Scripts/capture-fixtures.sh
```

Start playback somewhere first, or `/me/player` returns 204 and
`player-state.json` captures nothing worth having.

### 7d. Read the result

| What you see on `/playlists/{id}/items` | What it means |
|---|---|
| 200, `items[].item` populated | **V-1 passes.** §8 can be built as specified. |
| 200, but entries carry `track` rather than `item` | The rename did not land the way §4.3 describes. The DTOs are wrong — send the file. |
| 200, but `items` is null | The playlist is not returning contents to this user. §8 needs the duplication fallback. |
| 404 | Playlist not visible to this user, or the path is not `/items`. V-1 fails. |
| 403 | Premium lapsed, a scope is missing, or it is a withdrawn endpoint (§4.4). |

### 7e. Before committing the fixtures

**Read every file in `Tests/SpotifyKitTests/Fixtures/`.** The script strips
images, external URLs, owner blocks, and the playlist ID, but it deliberately
leaves track and artist names — those are the data under test. This repository
is public, so that is a real decision. If you would rather it did not include
your playlist contents, say so and the redaction can be widened.

Then:

```bash
swift test
```

The five `FixtureDecodingTests` should flip from *known issue* to passing. **If
they fail instead, that is the valuable outcome, not a problem** — it means the
field names were wrong and now we know exactly how.

Record the answer in `docs/verification.md` against **V-1**, with the date.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| "SPOTIFY_CLIENT_ID is missing from Info.plist" | `Config.local.xcconfig` not created, or the Xcode project was generated before it existed. Recreate it, then `xcodegen generate` again. |
| Authorization sheet opens and immediately closes | The redirect URI in the dashboard does not match `SPOTIFY_REDIRECT_URI` exactly, including scheme and path. |
| Callback never returns | The URL scheme is not registered on the companion target. Check `CFBundleURLSchemes` in `Apps/project.yml`. |
| "Install the bio-rhythm watch app first" | `transferUserInfo` has nowhere to go. Install the watch app, then retry. |
| Watch still shows "Not connected" after onboarding | The transfer is queued; open the watch app in the foreground. If it persists, check `WCSession` activation errors on the phone. |
| 403 on every request | Premium lapsed, or a scope is missing (§11.4). |
| App stops launching after a week | Free-account provisioning expired. Rebuild from Xcode. |
| "Another app is already recording a workout" | §10's single-session constraint. End the session in the Workout app, Strava, or whatever started it. Not a retry situation. |
| Zone indicator flickers between two zones | Expected in M1. The screen shows the raw §6.1 mapping; hysteresis, dwell, and the step limit arrive with `ZoneModel` in M2. |
