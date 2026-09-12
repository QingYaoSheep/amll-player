# Plan 5 — complete native AMLL port

Updated 2026-09-12. Specification: the user's approved “计划 5 替换稿：完整原生移植 AMLL 歌词播放器”, reflected in workspace `../Plan.md`. All Apple Music layout requirements are superseded. Scope is the complete player and all natively supportable layouts, backgrounds, effects, controls and transitions. Playback services, lyric providers, manual matching and offsets remain intact.

Status: **in progress; not visually signed off; not the production default**.

## Source → Swift → test ledger

Paths below are relative to the pinned core/react-full `src` directories extracted into `.build-tools/amll-reference`. Swift files are in `AMLLPlayer/Rendering`; source parity tests use `AMLLPlayerTests/Fixtures/amll-motion-reference.json`.

| Source | Native implementation | Evidence / remaining gap |
|---|---|---|
| `utils/spring.ts`, `derivative.ts` | `AMLLSourceSpring` | 360 original frames at 60/120 Hz, dropped frame, delayed target/retarget/parameters; source finite differences and stop rule |
| `utils/lyric-line-break.ts` | `AMLLBalancedLayout` | Four original fixed-width break fixtures; browser glyph measurements and segmentation parity pending |
| `lyric-player/base/timeline.ts` | `AMLLSourceTimeline` | Nine original overlap/seek states; explicit seek revision |
| `utils/optimize-lyric.ts` | `AMLLDisplayDocument` | Original vocal/overlap fixture; source word times unchanged |
| `utils/lyric-split-words.ts` | `AMLLWordSegmentation` | Adapter present; exhaustive UTF-16 fixtures, ruby/obscene metadata incomplete |
| base group/layout/scroll; DOM group/CSS | `AMLLFrameEngine` | Independent group Y/slide and line scales, browsing, paused background flow test; CSS transitions, measured height feedback, non-spring fallback and full source traces incomplete |
| DOM `updateMaskAlphaTargets`, `applyAlphaToDom` | `AMLLMaskAlpha` | 540 original samples; intrinsic scale, force update, attack/release and three-decimal DOM output; state owned by engine |
| DOM `generateWebAnimationBasedMaskImage` | `AMLLWordMask` | Original three-word keyframes/gap holds; ruby timing, overlapping/malformed words and all variants pending |
| DOM layout/CSS | `AMLLCoreTextLayout` | Core Text + source break cost, independent auxiliary raster, logical timing shared by fragments; bidi runs, ruby, word romanization, ligatures, exact line heights/browser baseline pending |
| DOM composed layers | `AMLLNativeLyricsView` | Display link, row reuse, single mask composition, unclamped feather slope; group blur, opacity/filter transitions, exact emphasis/glow, full accessibility variants pending |
| DOM float/emphasis methods | `AMLLSourceWordAnimation`, `AMLLWordAnimationClock` | Original 32-frame emphasis descriptors ported with delay, ruby anchor count, last-word boost and matrix rounding; source fixture covers eight characters. Normal word float wired with independent pause/enable/reverse clocks. Per-character shaped layers, glow composition and full WAAPI timing parity still pending; old `AMLLWordMotion` is not counted |
| react-full PrebuiltLyricPlayer/layouts/Cover/sliders/icons | Not yet wired in new player | Entire page, responsive font presets, source SVGs, aspect-ratio rules, gestures and live AppModel adapter pending |
| Mesh/Pixi/GLSL/CSS backgrounds | Old path only | Shader bundle pinned; exact pipelines/seeded frame comparison pending |
| player AMLLWrapper TSX/CSS | Not yet ported | Enter/exit displacement, radius, delays, cancellation/keyboard rules pending |
| config/data/callback atoms | Minimal frame/input types | Full contracts and lossless profile migration pending; AMLL defaults must not be labeled appleMusic26 |
| Debug/reference workflow | `LyricsRenderPreview`, native trace export, `Scripts/reference-browser` | A/B switch, native timing/cache counters, rate selection, return-current, five-second real transform export; original core browser host with geometry/WAAPI export and bounded opt-in trace. Full-page host, animation freeze/history stepping and side-by-side/overlay pending |

## Validation record

- `3f2f8260`: [CI 34600005658](https://github.com/QingYaoSheep/amll-player/actions/runs/34600005658) passed Xcode 26 unit/UI, iPad build/archive and Xcode 27 build/archive/IPA, including prior QQ encrypted-QRC/provider regressions and initial source fixtures.
- `1c81db13` / `be39c973`: native view access/isolation and optional CGFloat compile failures were fixed in `be39c973` / `5189d11c`.
- `5189d11c`: Xcode 27 passed; Xcode 26 was superseded, not counted as a full pass.
- `9b361ad9`: Xcode 27 passed; Xcode 26 superseded, not counted as a full pass.
- `e4c5724d`: Xcode 27 build/archive/IPA and all 5 UI tests passed. Of 152 unit tests, the display-optimization source comparison reported three assertions in one test; all other tests passed, including mask/alpha traces and the native canvas attachment/export test. Root cause: second-based arithmetic changed the exact 100 ms overlap threshold. The adapter now retains original millisecond units for optimization and timeline decisions; rerun required.
- Independent standards/spec review agents were attempted but both returned usage-limit errors without reviewing. No independent-review pass is claimed.
- `9a0f1b37`: [CI 34669487513](https://github.com/QingYaoSheep/amll-player/actions/runs/34669487513) fully passed Xcode 26 unit/UI, iPad build/archive and Xcode 27 build/archive/IPA. Native attachment was inspected; transparent PNG previews discard alpha, so subsequent test captures explicitly composite onto black and attach the view to a window for correct display scale.
- Windows has no Swift/Xcode. Local checks verify source hashes/fixtures and formatting/diffs; Swift execution evidence comes from CI.

- `c89c20b2`: [CI 34669889393](https://github.com/QingYaoSheep/amll-player/actions/runs/34669889393) fully passed Xcode 26/27, including original emphasis keyframes and native word-clock tests.
- Original core browser host was built from the pinned bundle with 265 module hashes. Local browser verification confirmed visible lead/background/duet/translation text, seek by 1/60 s, playback, pause and a 1200-sample bound, with no console errors. This Windows font capture is development evidence only. CSS/WAAPI remain on browser wall time; the seek buttons are explicitly not deterministic animation stepping.
- Native masks now sample the engine-owned word clock rather than playback snapshots. A regression covers snapshot corrections, pause, explicit seek and 120 Hz resume. CI for this follow-up remains pending.

QQ fix validates/removes the zlib envelope before Apple's raw-DEFLATE decoder, verifies Adler-32 and tolerates DES zero padding. Other provider/cache behavior remains outside this rendering rewrite.

## Completion gates

- Same Apple-resolved fonts, viewport (1 CSS px = 1pt), lyrics, settings, cover, seed and event sequence in original browser and native app.
- Discrete group/focus/break results identical; full numerical trajectories at 60/120 Hz, irregular gaps, pause/resume, forward/reverse seek, browsing, track changes and interruptions compared with fixed tolerance.
- Identical breaks/visibility; foreground geometry/baseline ≤1 physical pixel; events ≤1 reference frame; trajectory P95 ≤1pt, opacity error ≤0.02, scale error ≤0.002; seeded backgrounds compared frame by frame and manually overlaid.
- All natively supportable layouts/effects on iPhone 16 Pro and 13-inch iPad Pro, compact/landscape/split view and separate accessibility variants.
- Complex/multivoice/long lyrics for 15 minutes: bounded layout/layer/texture resources, <1% dropped frames in normal thermal conditions, no automatic effect removal.
- All provider regressions, Xcode 26 unit/UI and Xcode 27 archive/IPA pass. Hardware sign-off precedes production-default migration.

Matching formulas, green CI or one similar screenshot do not complete Plan 5. Historical `Plan5-Validation.md` describes the previous renderer, not acceptance of this replacement.
