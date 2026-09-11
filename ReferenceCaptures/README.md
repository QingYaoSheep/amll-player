# Pinned AMLL reference

The complete local AMLL player, including its layout, is now the acceptance baseline. Apple Music screenshots and `manifest.json` are historical records only and no longer block acceptance.

`amll-source-manifest.json` pins core 0.5.2, react-full 0.4.2, extracted source contents, bundled CSS/JavaScript (including inlined SVG/GLSL), wrapper/lockfile hashes and the installed dependency graph. From the Swift repository, using Node 25:

```sh
node Scripts/extract-amll-reference.cjs ../AMLL-OLD --verify
node Scripts/generate-amll-motion-reference.cjs --verify
```

Omit `--verify` only when deliberately regenerating the baseline. Extracted sources live in ignored `.build-tools/amll-reference/`; numeric fixtures are committed under `AMLLPlayerTests/Fixtures/`. The generator executes original functions/methods with minimal style/animation sinks, not JavaScript copies of the Swift formulas.

Copied pnpm junctions still pointing to the former workspace are resolved to the same local store entry, without modifying the legacy tree. The graph pins dependency manifests and resolution; hashing all transitive code assets and an executable full-page browser runner remain work in P5N-00.

Visual acceptance requires identical Apple-resolved fonts, viewport, settings, lyric data, cover, seed and event sequence. One CSS px maps to one point; scale applies only to rasterization. See [implementation ledger](../Docs/Plan5-AMLL-Port.md). No current screenshot or CI result constitutes 1:1 sign-off.
