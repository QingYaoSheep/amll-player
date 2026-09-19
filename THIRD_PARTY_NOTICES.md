# Third-party notices

## Remaining visual source references

- Core 0.5.2 `mesh-renderer/cp-presets.ts` and `cp-generate.ts`: all six presets are preserved in `amll-mesh-presets.json`; `AMLLMeshPreset` adapts the control-point generator to Swift. `generate-amll-background-reference.cjs` executes the pinned source only during development to export seeded parity fixtures. The core attribution and AGPL license below apply.
- `react-full` TextMarquee TSX/CSS: adapted by `AMLLMarqueeMotion` and `AMLLMetadataText`; the pinned AMLL package attribution and license below apply. Touch activation is a native addition.
- Local `spotify-multisource-lyrics.js` 0.29.21 declares `@license MIT`. Its `animatedCoverMediaUrl` and `fetchAppleAnimatedArtwork` catalog sequence inform the independent Swift `ArtworkAsset` decoding and `AppleLyricsProvider.animatedArtwork` method. No JavaScript is embedded or executed in the app.
- Exact source hashes for these references: `ReferenceCaptures/remaining-visual-source-hashes.json`.

## Apple Music-like Lyrics native rendering port

- Local reference: `AMLL-OLD`, `@applemusic-like-lyrics/core` 0.5.2 and the installed `react-full` package.
- Project: https://github.com/amll-dev/applemusic-like-lyrics
- Core package license: AGPL-3.0-only, as declared by the pinned package.
- Exact package versions, declared licenses and source hashes: `ReferenceCaptures/amll-source-manifest.json`.
- Swift adaptations: `AMLLSourceSpring`, `AMLLSourceTimeline`, `AMLLBalancedLayout`, `AMLLDisplayDocument`, `AMLLFrameEngine`, `AMLLMaskAlpha`, `AMLLWordMask`, `AMLLWordSegmentation`, `AMLLCoreTextLayout`, `AMLLSourceWordAnimation`, `AMLLWordAnimationClock`, and the native layer adapter.
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

## Pixi native background filters

`AMLLPixiState`, `AMLLPixiBackground` and its Metal shaders adapt the pinned
core 0.5.2 `pixi-renderer.ts` (AGPL attribution above). The blur weights and
pass order, color matrices, and bulge coordinate mapping adapt Pixi 7.4.3
`@pixi/filter-blur`, `@pixi/filter-color-matrix` and `@pixi/filter-bulge-pinch`
5.1.1 under MIT. Copyright 2013–2023 Mathew Groves, Chad Engler;
bulge-pinch notice copyright 2013–2017 Mathew Groves, Chad Engler.
Full notices: `Licenses/Pixi-MIT.txt`, `Licenses/Pixi-Filters-MIT.txt`.
Exact input hashes: `ReferenceCaptures/amll-pixi-inputs.json`.
Development fixture scripts execute upstream JavaScript only outside the app.
