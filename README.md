# AMLL Player for SwiftUI

AMLL Player is being rebuilt as a native SwiftUI application for iPhone and iPad. Audio remains in Spotify; this application provides Spotify browsing, remote controls, and native synchronized lyrics.

This repository currently contains plan 1: the reproducible XcodeGen project, application foundation, tests, localization, diagnostics, and GitHub Actions workflows.

## Requirements

- iOS or iPadOS 18 or later
- Xcode 26 stable
- A Spotify Developer application
- XcodeGen 2.46.0, installed automatically by `Scripts/generate-project.sh`

## Configure Spotify

1. Create an iOS application in the Spotify Developer Dashboard.
2. Set the bundle identifier to `net.stevexmh.amllplayer`.
3. Register `amllplayer://spotify-callback` as the redirect URI.
4. Copy `Configuration/Secrets.xcconfig.example` to `Configuration/Secrets.xcconfig`.
5. Put your own Client ID in the untracked file.

Spotify Development Mode requires each user to be allowlisted. Do not commit the Client ID or any tokens.

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

GPL-3.0. Spotify SDK and other third-party notices remain governed by their respective licenses.
