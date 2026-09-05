# 计划 5：原生逐字歌词渲染引擎

日期：2026-09-05。接续基线 `ef16a8ba` 及此前中断时保留的未提交渲染文件。当前为实现与验证记录，CI 结果将在执行后补充；不把代码存在等同于真机验收通过。

## 实现范围

路径相对于 `AMLLPlayer/`。

| 编号 | 实现 | 验证入口 |
|---|---|---|
| P5-01 | `Features/Lyrics/FullscreenLyricsPlayer.swift`：封面 aspect-fill、裁切、安全区覆盖、固定模糊、暗色遮罩；缺封面或 Reduce Transparency 使用纯色 | 全屏页及 Debug 合成封面预览；iPhone/iPad 真机画面对照待验收 |
| P5-02 | `Rendering/LyricsTimeline.swift`、`LyricTextLayout.swift`、`LyricsRenderView.swift`：独立行/词时间、多声部重叠、前奏/间奏指示、渐变填充、词级上浮、行缩放/模糊、弹簧跟随、对唱/RTL | `LyricsTimelineTests`、`LyricsRenderViewTests`；固定时间截图附件 |
| P5-03 | `LyricsRenderView.swift`：手动/VoiceOver 浏览暂停跟随，独立返回当前行，点击受设备权限限制的 seek；旋转/换歌复位，退出与后台停 display link | 暂停恢复、权限变化保留浏览、生命周期单元测试；全屏浏览/隐藏恢复/旋转 UI 测试 |
| P5-04 | `LyricsRenderConfiguration.swift`、`Features/Lyrics/LyricsAppearanceView.swift`：翻译/音译开关及顺序、字号预设、字重、字距、布局/信息显隐、署名模式、版本化本地偏好与旧草稿迁移 | `LyricsRenderPreferencesTests`；TextKit 组合字符/长词换行/字体放大测试 |
| P5-05 | `Features/Lyrics/MarqueeText.swift`、`Rendering/LyricsRenderPreview.swift`：可停止长标题、真实署名、逐字/逐行合成样本、时间/字号/模糊控制、FPS/帧处理时间/内存/行数/缓存数 | 设置 → Debug 歌词渲染预览；300 主行+背景声部的有界缓存测试 |

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

动态背景与 GPU 压力自动降低背景/模糊质量不在本次实现中。计划 7 的高级视觉尚未执行。
