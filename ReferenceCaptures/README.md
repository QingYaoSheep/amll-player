# Pinned AMLL reference

The complete local AMLL player, including its layout, is now the acceptance baseline. Apple Music screenshots and `manifest.json` are historical records only and no longer block acceptance.

`amll-source-manifest.json` pins core 0.5.2, react-full 0.4.2, extracted source contents, bundled CSS/JavaScript (including inlined SVG/GLSL), wrapper/lockfile hashes and the installed dependency graph. From the Swift repository, using Node 25:

```sh
node Scripts/extract-amll-reference.cjs ../AMLL-OLD --verify
node Scripts/generate-amll-motion-reference.cjs --verify
```

Omit `--verify` only when deliberately regenerating the baseline. Extracted sources live in ignored `.build-tools/amll-reference/`; numeric fixtures are committed under `AMLLPlayerTests/Fixtures/`. The generator executes original functions/methods with minimal style/animation sinks, not JavaScript copies of the Swift formulas.

Copied pnpm junctions still pointing to the former workspace are resolved to the same local store entry, without modifying the legacy tree. The graph pins dependency manifests and resolution; hashing all transitive code assets and an executable full-page browser runner remain work in P5N-00.

## Original core browser host (development only)

On the current Windows checkout with Node 25 and the original installed dev dependencies:

```sh
node Scripts/build-amll-browser-reference.cjs
node Scripts/serve-amll-browser-reference.cjs
```

Open `http://127.0.0.1:4178/`. Optional `width`, `height` and `font` query parameters set the content viewport and font size in CSS px. An independent iframe makes CSS `vh`/`vw` and media queries use these dimensions, excluding the adjacent toolbar. The harness bundles the original core, verifies the source baseline first and writes module hashes to ignored `.build-tools/amll-reference/browser/build-manifest.json`. It neither repairs old pnpm junctions nor enters the Swift app bundle. The compiler bootstrap currently targets the installed Windows rolldown binary; an Apple-hosted build remains pending.

Playback, pause, seek and opt-in geometry capture are available. At most 1200 samples are retained; exports include current original WAAPI keyframes. Geometry capture forces browser layout and must not be used as performance evidence. Buttons labeled `Seek + 1/60 s` / `Seek + 1/120 s` perform seeks, not frozen-animation steps: CSS/WAAPI still use browser time. This is a core-only harness, not full react-full page or deterministic visual acceptance.

Visual acceptance requires identical Apple-resolved fonts, viewport, settings, lyric data, cover, seed and event sequence. One CSS px maps to one point; scale applies only to rasterization. See [implementation ledger](../Docs/Plan5-AMLL-Port.md). No current screenshot or CI result constitutes 1:1 sign-off.
