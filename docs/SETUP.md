# Setup

One-time setup for the owner's machine, phone, and watch. Everything here is
M0 (SPEC.md §13): packages, auth, and the watch reading playback state on its
own.

## 1. Spotify app registration

1. Sign in at <https://developer.spotify.com/dashboard> with the account that
   holds **Premium**. As of Feb 2026 a Development Mode app requires the *app
   owner* to hold active Premium, not just the listening user (§4.1). If the
   subscription lapses the app stops working and resumes on resubscribe.
2. Create an app. Development Mode allows one client ID per developer and five
   users per app — adequate here, and nothing in the design assumes more.
3. Add a redirect URI. `biorhythm://callback` matches the committed example.
4. Add your own Spotify account under the app's users.

Do not request Extended Quota Mode. It now requires large MAU and is not a
fallback (§4.1).

## 2. Local configuration

```bash
cp Config.example.xcconfig Config.local.xcconfig
```

Fill in `SPOTIFY_CLIENT_ID`. `Config.local.xcconfig` is gitignored and must
stay that way.

## 3. Build the libraries

```bash
swift build
swift test
```

`HRDJCore` and `SpotifyKit` tests run with no simulator, no network, and no
credentials. Keep it that way — it is the reason the control law is testable at
all.

## 4. Generate the Xcode project

```bash
brew install xcodegen
cd Apps && xcodegen generate
open BioRhythm.xcodeproj
```

The `.xcodeproj` is generated and gitignored; `Apps/project.yml` is the source
of truth. Building the project by hand in Xcode instead is fine — `project.yml`
then serves as the checklist of what each target needs.

## 5. Run onboarding

1. Build and run **iOSCompanion** on the phone. Tap *Connect Spotify*, sign in,
   approve the four scopes (§9.2).
2. The companion sends the refresh token to the watch with
   `transferUserInfo`, which is queued and retried by the system. The watch app
   must be installed first, or the transfer is refused with a message saying so.
3. Build and run **WatchApp**. It should pick up the token and show the
   currently playing track.

## 6. Confirm the M0 exit criterion

Play something on any device, then **power the phone off** and open the watch
app. It should still show the track, refreshing its own access token against
the Spotify accounts service over Wi-Fi or LTE.

That is M0 complete: the phone is needed once, for onboarding, and never again
(G3).

## 7. Capture API fixtures

```bash
export SPOTIFY_TOKEN='BQ...'
export POOL_PLAYLIST_ID='37i9...'
Scripts/capture-fixtures.sh
```

This populates `Tests/SpotifyKitTests/Fixtures` and answers **V-1**, which
blocks all of §8. Record the answer in `docs/verification.md`.

The easiest way to get `SPOTIFY_TOKEN` is to add a temporary print of the
access token in the watch app, or to run the authorization flow by hand from
the developer dashboard's console.

## Troubleshooting

| Symptom | Cause |
|---|---|
| "SPOTIFY_CLIENT_ID is missing from Info.plist" | `Config.local.xcconfig` not created, or Xcode project generated before it existed. Regenerate. |
| Authorization sheet opens and immediately closes | Redirect URI in the dashboard does not match `SPOTIFY_REDIRECT_URI` exactly, including scheme and trailing path. |
| Callback never returns | The URL scheme is not registered on the companion target. Check `CFBundleURLSchemes` in `project.yml`. |
| "Install the bio-rhythm watch app first" | `transferUserInfo` has nowhere to go. Install the watch app, then retry. |
| Watch shows "Not connected" after onboarding | The transfer is queued and can take a moment; open the watch app in the foreground. If it persists, check `WCSession` activation errors on the phone. |
| 403 on every request | Premium lapsed, or a scope is missing (§11.4). |
