# Apple Music layout references

Apple Music screenshots are used only to measure the native player's spatial layout. AMLL source code and the locked `@applemusic-like-lyrics/core@0.5.2` package remain the authority for lyric typography, highlighting, springs, scrolling, voices, translations, romanization, and interlude motion.

Copy original, uncropped files into `ReferenceCaptures/raw/`. That directory is ignored by Git. `manifest.json` records the immutable filename, dimensions, scale, state, and SHA-256 digest; run:

```sh
node Scripts/verify-layout-references.cjs
```

The two current captures establish the 402×874pt iPhone 16 Pro portrait layout. The exact iOS 26 build and iPad reference captures are still required before pixel-level layout sign-off.
