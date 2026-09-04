# AMLL Player for SwiftUI

AMLL Player is being rebuilt as a native SwiftUI application for iPhone and iPad. Audio remains in Spotify; this application provides Spotify browsing, remote controls, and native synchronized lyrics.

This repository contains the reproducible XcodeGen foundation and the plan 2 Spotify vertical slice: PKCE authorization, Keychain-backed sessions, App Remote/Web API playback synchronization, controls, and Spotify Connect device switching.

Plan 3 now adds Home, Search, Library, and track/album/artist/playlist details, including pagination, refresh, external Spotify links, and context-position playback. See [Plan 3 validation](Docs/Plan3-Validation.md) for the outstanding Xcode/device acceptance checks.

## Requirements

- iOS or iPadOS 18 or later
- Xcode 26 stable
- A Spotify Developer application
- XcodeGen 2.46.0, installed automatically by `Scripts/generate-project.sh`

## Configure Spotify

1. Create an iOS application in the Spotify Developer Dashboard.
2. Set the bundle identifier to `net.stevexmh.amllplayer`.
3. Register `amllplayer://spotify-callback` as the redirect URI.
4. In the app, open Settings → Login → Sign in to Spotify.
5. Enter your Client ID and tap Authorize and sign in. The ID is saved on the device;
   the system browser opens Spotify's PKCE authorization page.

The login page also includes setup instructions and links to the Developer Dashboard.
Changing Client ID disconnects the old session before creating the new connection.
Sessions are scoped to each Client ID. Existing installations may need to sign in once
after upgrading from the earlier, unscoped session store.
For a build-time default, you can still copy `Configuration/Secrets.xcconfig.example`
to the untracked `Configuration/Secrets.xcconfig` and enter a Client ID.

Spotify Development Mode requires each user to be allowlisted. Do not commit the Client ID or any tokens.

## Spotify authorization and playback

- The main connect action prefers the installed Spotify app and falls back to web PKCE.
- Settings and Spotify login are separate navigation pages with standard back navigation.
- The mini player uses native Liquid Glass on iOS 26 and later, with a material fallback
  on older systems and an opaque surface when Reduce Transparency is enabled.
- Settings offers an explicit system-browser PKCE sign-in path, even in an unconfigured build.
- Native clients never collect or embed a Client Secret; secrets belong on a trusted server.
- Sessions are stored in a this-device-only Keychain item and removed on logout.
- App Remote supplies near-real-time state; Web API polling takes over when it is unavailable.
- Play, pause, previous, next, seek, volume, URI playback, device listing, and playback transfer are supported.
- Backgrounding disconnects App Remote and stops polling. Foregrounding refreshes, reconnects, and recalibrates playback.
- Web API playback control and on-demand URI playback require Spotify Premium.

## Generate and open the project

```bash
bash Scripts/generate-project.sh
open AMLLPlayer.xcodeproj
```

The generated Xcode project is intentionally ignored. GitHub Actions regenerates it for every build.

## Repository structure

- `AMLLPlayer/App`: application lifecycle and root state
- `AMLLPlayer/Domain`: platform-independent domain types
- `AMLLPlayer/Infrastructure`: external systems and diagnostics
- `AMLLPlayer/Features`: SwiftUI feature surfaces
- `AMLLPlayer/Rendering`: native lyric renderer boundary
- `AMLLPlayerTests` and `AMLLPlayerUITests`: automated verification

## Xcode 27 artifacts

Every push builds with the dedicated Xcode 27 runner and uploads
AMLLPlayer-Xcode27-unsigned.ipa. This unsigned IPA is intended for later
re-signing and cannot be installed directly on an ordinary iPhone or iPad.

## CI signing secrets

The manual `Signed development IPA` workflow requires:

- `APPLE_DEVELOPMENT_CERTIFICATE_BASE64`
- `APPLE_DEVELOPMENT_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPMENT_TEAM`
- `APPLE_PROVISIONING_PROFILE_BASE64`
- `TEMPORARY_KEYCHAIN_PASSWORD`
- `SPOTIFY_CLIENT_ID`

No signing material is written to the repository or uploaded with build artifacts.

## License

AGPL-3.0; see LICENSE. Spotify SDK and other third-party notices remain governed by their respective licenses.
