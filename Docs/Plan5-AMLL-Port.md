# Plan 5 — complete native AMLL port

## 2026-09-18 直接 IPA 构建策略

按用户最新要求，CI 取消 iOS 27 设备/模拟器测试及模拟器构建，使用 Xcode 27 / iOS 27 SDK 直接 Release archive、检查应用包并上传未签名 IPA。保留测试源码，未执行的测试不算通过；HDR/视觉签收与性能仍未完成，不作为本次 IPA 构建前置条件。


2026-09-13: timed ruby fragments and fitting word romanization now reach cached native annotation layers. Ambiguous/oversized romanization falls back with trace diagnostics; wrapped ruby and full source visual parity remain open. See the remaining-visual ledger for validation status.

Latest remaining-visual specification and evidence: [Remaining-Visual-Port.md](Remaining-Visual-Port.md). HDR currently has a model only; metadata SDR Plus Lighter is wired but not visually signed off. Historical status below does not supersede that ledger.

Updated 2026-09-12. Specification: the user's approved “计划 5 替换稿：完整原生移植 AMLL 歌词播放器”, refined so the unified AMLL page keeps the previously added Apple Music-derived page geometry while all lyric motion and rendering remain native AMLL. Playback services, lyric providers, manual matching and offsets remain intact.

Status: **in progress; not visually signed off; not the production default**.

## Source → Swift → test ledger

Paths below are relative to the pinned core/react-full `src` directories extracted into `.build-tools/amll-reference`. Swift files are in `AMLLPlayer/Rendering`; source parity tests use `AMLLPlayerTests/Fixtures/amll-motion-reference.json`.

| Source | Native implementation | Evidence / remaining gap |
|---|---|---|
| `utils/spring.ts`, `derivative.ts` | `AMLLSourceSpring` | 360 original frames at 60/120 Hz, dropped frame, delayed target/retarget/parameters; source finite differences and stop rule |
| `utils/lyric-line-break.ts`, `utils/line-balancer.ts` | `AMLLBalancedLayout`, `AMLLCoreTextLayout.staticSegments` | Four original fixed-width break fixtures; static lines now use NLTokenizer word/gap children and the seven responsive AMLL size presets. Browser glyph calibration and exact baseline parity remain pending |
| `lyric-player/base/timeline.ts` | `AMLLSourceTimeline` | Nine original overlap/seek states; explicit seek revision |
| `utils/optimize-lyric.ts` | `AMLLDisplayDocument` | Original vocal/overlap fixture; source word times unchanged |
| `utils/lyric-split-words.ts` | `AMLLWordSegmentation` | Adapter present; exhaustive UTF-16 fixtures, ruby/obscene metadata incomplete |
| base group/layout/scroll; DOM group/CSS | `AMLLFrameEngine` | Independent group Y/slide and line scales, browsing, paused background flow, explicit event seeks, opacity/blur transitions and non-spring fallback; measured height feedback and full source traces remain incomplete |
| DOM `updateMaskAlphaTargets`, `applyAlphaToDom` | `AMLLMaskAlpha` | 540 original samples; intrinsic scale, force update, attack/release and three-decimal DOM output; state owned by engine |
| DOM `generateWebAnimationBasedMaskImage` | `AMLLWordMask` | Original three-word keyframes/gap holds; ruby timing, overlapping/malformed words and all variants pending |
| DOM layout/CSS | `AMLLCoreTextLayout` | Core Text + source break cost, static word segmentation, independent main/ruby/auxiliary rasters, logical timing shared by fragments. Bidi fragments use shaped visual runs with logical mask ordering; timed ruby reserves annotation space and segmented provider words retain their source atom. Exhaustive ligature/RTL cases and exact line heights/browser baseline pending |
| DOM composed layers | `AMLLNativeLyricsView` | Display link, row reuse, disjoint main/ruby/auxiliary layers, cached near/far blur rasters, row opacity/filter transition consumption, per-character emphasis/glow and 44pt/accessibility actions; full accessibility variants and visual sign-off pending |
| DOM float/emphasis methods | `AMLLSourceWordAnimation`, `AMLLWordAnimationClock` | Original 32-frame emphasis descriptors ported with source predicate, delay, ruby anchor count, last-word boost and matrix rounding; per-character shaped layers consume the sampled transform and glow. Full WAAPI timing parity and complex cross-line fixtures remain pending; old `AMLLWordMotion` is not counted |
| react-full PrebuiltLyricPlayer/layouts/Cover/sliders/icons | `Features/Lyrics/AMLLLyricsPlayer.swift` + `Rendering/AppleMusicLayoutReference.swift` | Unified `.amll` page now uses the Apple Music-derived compact metadata, artwork/control stack, handle and iPad columns with a live AppModel adapter; source SVG paths, reflection/mask details and full geometry sign-off remain pending |
| Mesh/Pixi/GLSL/CSS backgrounds | Old path only | Shader bundle pinned; exact pipelines/seeded frame comparison pending |
| player AMLLWrapper TSX/CSS | `AMLLLyricsPlayer` dismissal shell | Enter/exit displacement, radius and cancellation gesture are present; source delay/keyboard parity remains pending |
| config/data/callback atoms | `AMLLPlayerInput`, `AMLLRenderEnvironment`, `AMLLFrameState`, `AMLLInteraction`, `LyricsRenderPreferences` | Unified `.amll` page input carries document/snapshot/offset/seek revision/artwork/configuration; old `appleMusic26` storage maps to `.amll`, frame state includes row/background/control fields, and the responsive baseline is shared by the merged page. Full lossless migration matrix and device sign-off remain pending |
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
- Browser host now isolates the lyric area in an iframe so CSS media queries use the actual reference viewport. At 402×700, browser inspection confirmed 20px mobile padding (the previous container-only host incorrectly used the desktop 1em rule). This correction does not change the original source.

QQ fix validates/removes the zlib envelope before Apple's raw-DEFLATE decoder, verifies Adler-32 and tolerates DES zero padding. Other provider/cache behavior remains outside this rendering rewrite.

- `aa227852`: native glyph/raster follow-up added timed ruby layers, preserved timed whitespace, retained segmented provider-word metadata, consumed cached row blur/opacity transitions and made old `LyricWord`/frame trace payloads decode with missing optional fields. The Xcode 27 job passed; the Xcode 26 job exposed and was followed by fixes for legacy `isObscene` decoding, segmented-word indexing and transition settling.
- `3bd52b94`: static line breaking now follows source word/gap segmentation, AMLL uses its medium responsive baseline independently from the Apple Music compatibility profile, Reduce Transparency disables engine blur, and a regression covers segmented provider words. CI for this follow-up is pending.

## Completion gates

- Same Apple-resolved fonts, viewport (1 CSS px = 1pt), lyrics, settings, cover, seed and event sequence in original browser and native app.
- Discrete group/focus/break results identical; full numerical trajectories at 60/120 Hz, irregular gaps, pause/resume, forward/reverse seek, browsing, track changes and interruptions compared with fixed tolerance.
- Identical breaks/visibility; foreground geometry/baseline ≤1 physical pixel; events ≤1 reference frame; trajectory P95 ≤1pt, opacity error ≤0.02, scale error ≤0.002; seeded backgrounds compared frame by frame and manually overlaid.
- All natively supportable layouts/effects on iPhone 16 Pro and 13-inch iPad Pro, compact/landscape/split view and separate accessibility variants.
- Complex/multivoice/long lyrics for 15 minutes: bounded layout/layer/texture resources, <1% dropped frames in normal thermal conditions, no automatic effect removal.
- Current delivery gate: Xcode 27 Release archive and IPA bundle checks. Device/simulator tests are disabled by user request (2026-09-18); their sources and unresolved results remain recorded. Building an IPA does not imply visual/HDR hardware sign-off or full port completion.

Matching formulas, green CI or one similar screenshot do not complete Plan 5. Historical `Plan5-Validation.md` describes the previous renderer, not acceptance of this replacement.

## 2026-09-19 竖形动态封面接线

- 新增可选沉浸封面布局：按资源类型选择竖形视频，使用原 react-full 的封面中心/范围公式、70% 遮罩边界和 200/30 弹簧。保留 Apple Music 前景构图，属于明确布局差异。
- 读取实际封面槽位置，覆盖手机及 iPad；横屏取消不可见竖形视频请求并恢复静态布局。切换模式/歌曲沿用 revision 校验，旧方形或竖形资源不会串用。
- 旧配置缺少 presentation 时仍为方形；动态封面和蜂窝策略不自动开启。新增旧配置、资源选择、重置及几何回归测试，按直接 IPA 策略未执行 Apple 测试。
- Mesh 提交 04c0941a 的直接 IPA 构建 run 35352753867 成功。此次封面修改仍待新归档；Pixi、反射、完整视觉/HDR/性能签收仍未完成，不标记全部移植完成。

## 2026-09-19 Pixi 独立原生管线

- 新增独立四层封面 Metal 绘制、原版旋转/位移、逐容器淡入淡出、五档及大视口追加模糊、饱和度/亮度/对比度与双 bulge 滤镜。使用实际 .75 渲染比例和 30Hz 背景时钟；歌词时钟独立。
- 背景模式可选 Mesh/Pixi，旧配置仍选 Mesh。使用过的上下文保留，隐藏模式不发起新封面下载；普通暂停保留过渡状态，减少动态效果单独静态化。未呈现旧资源在新资源安装时释放。
- 直接执行固定 Pixi onTick 导出 60/120Hz/不规则轨迹夹具，锁定滤镜与 ticker 源码 SHA-256，补充 MIT 归属。原版 ticker 的 100ms 上限只用于 Pixi 帧入口，不改变歌词时间。
- 本地原参考生成、265 项资源哈希检查和 diff 检查通过。Swift 新测试未执行；GPU 滤镜边缘、色彩、内存与真机视觉仍待对照，不以管线接线宣称 1:1 完成。
- 竖形封面提交 1cd82fe2 的 run 35371698542 已成功 archive/IPA。本次 Pixi 待新构建；反射及综合签收仍未完成。

## 2026-09-19 同源视频倒影与静态背景

- 可选倒影使用同一 AVQueuePlayer 的 AVPlayerItemVideoOutput；直接传给原生图层，不以逐帧 SwiftUI 状态驱动。按原插件截取底部 24%、镜像、9pt 模糊、1.06 饱和度、0.24 透明度及原渐隐节点，保留透明边界和外层裁剪。
- 原版反射槽采用 ceil(封面底边)+49pt、高度 clamp(视口高度*0.3,220,340)；本应用绑定 Apple Music 实际封面槽，属于已保留的构图差异。切换循环 item 重新绑定 output，停用/关闭取消 display link，来源 token 拦截旧帧。
- 新增纯色（原默认 #111111）及原生双色渐变选项。原版 CSS 可输入任意字符串但没有内置渐变预设；本应用仅提供固定自上而下双色渐变的原生编辑，不新增 CSS 执行器。
- d6397734 的直接 IPA 构建 run 35414204666 成功。此前 64efeb3f 因 SDK 异步纹理加载缺少 await 失败，已修复并重检迟到资源。当前倒影/静态背景待新构建。
- Windows 无法执行 Apple 图形测试。逐帧 Core Image 倒影性能、循环取帧及 HDR/辅助文字/完整背景视觉签收仍待验证；全部移植保持未完成。
