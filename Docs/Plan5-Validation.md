# 计划 5：Apple Music 布局与 AMLL 原生逐字歌词引擎

日期：2026-09-05。接续基线 `ef16a8ba` 及此前中断时保留的原生渲染文件。Apple Music 只作为页面空间布局参考，歌词和背景效果以旧工程锁定的 `@applemusic-like-lyrics/core@0.5.2` 为准。当前记录实现证据与尚未完成的真机签收，不把代码存在等同于 1:1 验收通过。

## 实现范围

路径相对于 `AMLLPlayer/`。

| 编号 | 实现 | 验证入口 |
|---|---|---|
| P5R-00 | `ReferenceCaptures/manifest.json`、`Scripts/verify-layout-references.cjs`：登记两张 iPhone 16 Pro 原图的状态、1206×2622 像素、@3x 和 SHA-256；原图放在 Git 忽略目录 | 本地脚本逐字节校验；精确 iOS build 和 iPad 原图待补 |
| P5R-01 | `Rendering/AMLLMotionModel.swift`、`LyricsTimeline.swift`：AMLL 解析弹簧、按行间隔变化的纵向参数、字级强调、间奏三点及浏览/返回/seek/关闭状态 | `AMLLMotionModelTests`、`LyricsTimelineTests` 中固定数值和中断测试 |
| P5R-02 | `Rendering/LyricTextLayout.swift`、`LyricsRenderView.swift`：TextKit 字形布局、真实词时间遮罩、0.5em 羽化、主/辅助/背景声部比例、近远景模糊、滚动与行缩放 | `LyricTextLayoutTests`、`LyricsRenderViewTests` 与固定时间截图附件 |
| P5R-03 | `Features/Lyrics/AppleMusicLyricsPlayer.swift`、`Rendering/AppleMusicLayoutReference.swift`：显示歌词时的紧凑信息区、隐藏歌词时的大封面控制栈、顶部把手及 iPad 双栏 | `AppleMusicLayoutReferenceTests`、全屏 UI 测试；原图叠片待真机导出 |
| P5R-04 | `Rendering/AMLLMeshBackground.swift/.metal`：移植封面颜色变换、模糊采样、旋转、镜像、抖动和暗角；前景单独合成 | Xcode 26/27 Metal 编译及 60/120Hz 真机性能待验收 |
| P5R-05 | `LyricsRenderConfiguration.swift`、`LyricsAppearanceView.swift`：Apple Music 布局/自定义档位、v2 存储、旧设置备份迁移和 AMLL 默认值恢复 | `LyricsRenderPreferencesTests` |

接线：`RootView` 的迷你播放器打开原生全屏页；`AppModel` 继续提供 Spotify 播放快照与 `PlayerClock`，`LyricsCoordinator` 提供计划 4 的歌词文档和逐曲延迟。搜索/预览/人工锁定沿用原有协调器。没有本地音频或运行旧 JS。

## 时间与交互约定

- 渲染时间 = 单调播放时钟 − 逐曲延迟；正延迟表示歌词晚出现。提前滚动仅选取定位行，既不改变词级填充，也不加入 seek 目标。点击歌词的 Spotify 时间 = 行起点 + 逐曲延迟，并裁切至曲目时长。
- 行使用半开区间 `[start, end)`；重叠声部独立高亮。纯 LRC 保持逐行精度，不制造逐字时间。末词完成后整词填满；向后 seek 重新计算遮罩，不残留已唱进度。
- 手动浏览和 VoiceOver 聚焦暂停跟随；“返回当前歌词”只移动视图。恢复跟随的弹簧同时检查剩余距离与速度，暂停播放也能完整回到目标。
- 下滑关闭仅由顶部 44pt 把手接收，避免与歌词滚动/进度拖动争抢；未达阈值返回。关闭按钮一直可用，隐藏歌词后保留恢复入口。
- 可见行附近才创建图层与位图，布局缓存上限 48，复用池上限 12。整曲行高在文档/排版/视口变化时测量一次，逐帧不重复布局全文。超长文本初次布局与位图峰值仍需实机 profiling。
- 前台且歌词页可见时运行 display link；暂停且跟随已稳定后休眠，离开页/后台/视图拆除后释放。打开纠错/设备页时停止底层渲染。Reduce Motion 关闭词浮动、行缩放和弹簧，并保留真实词高亮。
- 使用 TextKit 完整段落布局与字体回退；按 glyph bidi level 决定词填充方向，保留组合字符/连字。混排、极端长行仍需与旧版固定画面对照。
- 署名只有来源实际提供时显示。Debug 样本是合成文字/封面，无个人歌曲、凭据或第三方网络依赖。

## 验证方式与证据

- 本地：Swift Tree-sitter 语法辅助检查、String Catalog JSON/中英文本键、`git diff --check`；SwiftFormat 只格式化计划 5 新文件。语法辅助工具不替代 Swift 编译器，条件编译节点有已知解析限制。
- CI：沿用 Xcode 26 单元/UI 测试、iPad build/Archive，以及 Xcode 27 SDK build/Archive/未签名 IPA。待本次源码运行完成后填入结果。
- 第一轮源码 `fcf12023` 已通过 [SwiftUI CI #24](https://github.com/QingYaoSheep/amll-player/actions/runs/33966756501)：110 个单元测试、5 个 UI 测试全部零失败，Swift lint、iPad build、Xcode 26 Archive 和 Xcode 27 build/Archive/未签名 IPA/包校验全部通过。该轮测试日志已核实；后续方向/截图导出/VoiceOver 顺序补充使用最终源码单独验证。
- `LyricsRenderViewTests.testFixedTimelineImagesForVisualReview` 将 390×700 的 2.5/6.5/18/26 秒画面作为 `.xcresult` 的永久附件；UI 测试保留横屏全屏截图。它们是可复现的原生基线，尚未与旧版截图逐像素验收。
- CI 另用 `xcresulttool export attachments` 输出 `AMLLPlayer-visual-review` artifact，供 Windows 直接检查 PNG。
- ProMotion 配置参考 [Apple 的刷新率说明](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays)：工程包含 `CADisableMinimumFrameDurationOnPhone`，渲染按屏幕能力请求最高 120Hz。请求帧率不是实测帧率承诺。

## 待真机验收

提交前两路只读复核：Standards 找到并修复 1 项（返回按钮出现导致歌词区尺寸改变、立即取消手动浏览）；Spec 找到并修复 3 项（重叠声部预滚动回跳、署名类型选择/回退缺失、下滑手势取消残留）。限定复核确认四项已修复，无新增确定问题；这不替代以下真机测试。

- [ ] 同一固定曲目/时间/设置，与旧版对照前奏、长音、重叠/对唱/背景声、空格、多语言与超长行。
- [ ] 60Hz 和 ProMotion 设备连续播放 15 分钟：帧率、掉帧、内存、图层数、时钟漂移；记录设备、系统与构建号。
- [ ] iPhone 竖横屏、iPad 双栏与分屏、最大 Dynamic Type、VoiceOver、Reduce Motion/Transparency；所有歌词、信息、退出与恢复入口可达。
- [ ] 真实 Spotify seek、快速换歌、暂停/恢复、前后台、受限设备及失败回滚；正负逐曲延迟叠加提前滚动。
- [ ] 签名 IPA 安装冷启动；偏好重启恢复；无封面及换封面无旧图残留。

动态背景已经按 AMLL 着色流程接入 Metal；Spotify 遥控模式没有音频采样，因此背景音量参数保持零，不伪造 FFT 输入。计划 7 的 HDR 与动态封面仍未执行。
