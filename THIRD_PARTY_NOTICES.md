# Third-party notices

## Apple Music-like Lyrics native rendering port

- Local reference: `AMLL-OLD`, `@applemusic-like-lyrics/core` 0.5.2 and the installed `react-full` package.
- Project: https://github.com/amll-dev/applemusic-like-lyrics
- Core package license: AGPL-3.0-only, as declared by the pinned package.
- Exact package versions, declared licenses and source hashes: `ReferenceCaptures/amll-source-manifest.json`.
- Swift adaptations: `AMLLSourceSpring`, `AMLLSourceTimeline`, `AMLLBalancedLayout`, `AMLLDisplayDocument`, `AMLLFrameEngine`, `AMLLMaskAlpha`, `AMLLWordMask`, `AMLLWordSegmentation`, `AMLLCoreTextLayout`, and the native layer adapter.
- License text preserved from the supplied upstream tree: [GNU AGPL v3](Licenses/AMLL-AGPL-3.0.txt).
- The upstream spring solver includes the source notice `MIT License github.com/pushkine/`.

These are modified native Swift adaptations of the extracted source algorithms.
The upstream source attribution and package licenses remain applicable to those
adaptations. Development reference scripts are not included in the iOS bundle.

## Spotify iOS SDK

- Project: https://github.com/spotify/ios-sdk
- Version: 5.0.1
- Product: `SpotifyiOS`
- Terms: https://developer.spotify.com/terms
- License notices: see the upstream repository and resolved package contents.

Spotify developer tools are governed separately by Spotify's Developer Terms of
Use and are not relicensed under AMLL Player's GPL-3.0 license. The SDK is linked
only for Spotify authentication and App Remote integration. AMLL Player does not
embed Spotify audio or act as a local audio engine.

## Lyricify Lyrics Helper

- Project: https://github.com/WXRIW/Lyricify-Lyrics-Helper
- Reference revision: `f49a46330b16d733a6d6f5894e347f311e1daae4`
- License: Apache License 2.0
- Copyright: 2023 XY Wang, WXRIW
- License text: https://github.com/WXRIW/Lyricify-Lyrics-Helper/blob/f49a46330b16d733a6d6f5894e347f311e1daae4/LICENSE

The native Apple Music, QQ Music, and NetEase lyric transport and format adapters
use the public provider contracts and format descriptions from Lyricify Lyrics
Helper as an interoperability reference. AMLL Player's Swift implementation is
maintained in this repository.
