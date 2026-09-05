# AMLL Player SwiftUI Changelog

本文件整合 SwiftUI 原生重构的 Git 提交、计划文档和验证记录。日期以 Git 提交时间为准；未提交的工作区内容单独标记，不视为已发布功能。

## 2026-09-05 — 计划 4 验证完成

基线提交：`40ee8fc6`  
代码验证提交：`cd3fcb4c`

- 完成 Apple Music、QQ Music、NetEase 多源歌词。
- 增加 TTML/LRC 解析、逐词时间、翻译、音译、背景声部、对唱和 RTL 处理。
- 增加 SwiftData 歌词缓存、Keychain Apple 凭据和解析器版本迁移。
- 增加人工歌词搜索、预览、应用、锁定、恢复自动匹配和逐曲延迟。
- 将歌词纠错入口放入播放器右上角工具栏。
- 修复 UI 测试在 `LazyVStack` 屏外歌词上的断言问题。
- GitHub Actions #23 通过 Swift lint、86 个单元测试、4 个 UI 测试、iPad build、Xcode 26 archive 和 Xcode 27 SDK IPA 构建。

验证文档：[Docs/Plan4-Validation.md](Plan4-Validation.md)

## 2026-09-04 — 计划 3：Spotify 音乐浏览

提交：`462802cc`

- 增加首页、搜索、音乐库和 Spotify 目录详情页面。
- 支持歌曲、专辑、艺人、歌单、分页、刷新、短期缓存和取消旧请求。
- 支持 Spotify Connect 设备和原始列表位置播放。
- 对不可访问的 Spotify 内容提供外部打开提示。
- 增加目录解码、限流、配额熔断、401 单次刷新重试和 UI 测试。

验证文档：[Docs/Plan3-Validation.md](Plan3-Validation.md)

## 2026-09-04 — Spotify 设置与迷你播放器

提交：`49db18e2`、`cb3aeed4`、`af63ac17`

- 设置页改为独立导航页面。
- 增加 Spotify 登录子页面、Client ID 输入和网页 PKCE 授权按钮。
- 修复构建应用中的 Spotify callback URI。
- 使用原生 Liquid Glass/Material 降级实现底部迷你播放器。

## 2026-08-30 — 计划 1 与计划 2 基础能力

主要提交：`0659e9a0`、`4d8a3de3`、`494b1fd1`、`bc0eb028`

- 初始化 SwiftUI 工程、XcodeGen、测试 target 和 GitHub Actions。
- 增加 Xcode 27 SDK 构建与未签名 IPA artifact。
- 接入 Spotify SDK、PKCE 授权、Keychain 会话和 App Remote。
- 增加 Web API 播放状态同步、实时进度、播放控制和 Connect 设备切换。
- 增加网页登录回退、后台停止轮询、前台恢复和播放时钟校准。

## 2026-09-05 — 计划 5 工作区改动（未提交）

本节记录导出时工作区中已有但尚未提交的计划 5 内容，不代表已经通过 CI：

- 原生 `LyricsRenderView`、`CADisplayLink`、可见行复用和 TextKit 文本布局。
- 真实词时间的渐变填充、逐行高亮、背景声部、对唱、RTL、VoiceOver 和点击 seek。
- 手动浏览、自动跟随恢复、下滑关闭、iPhone/iPad 全屏布局。
- 静态专辑封面背景：aspect-fill 铺满、保持比例、模糊和暗色遮罩。
- 排版、翻译/音译、字号、字重、字距、歌词显示、封面布局、元数据显示和 Debug 渲染预览设置。
- 按用户要求移除 GPU 压力自动降低背景/模糊质量的逻辑。

### 中断后的接续实现

- 补齐计划 5 中英文文本、版本化外观设置与旧草稿迁移、已播放/剩余时间切换。
- 修复暂停后跟随恢复、设备权限变化导致滚动复位、词尾填充、混合文字方向、长标题动画重启和页面退出清理。
- 补充时间轴、偏好、TextKit、图层复用、VoiceOver 和生命周期测试，更新全屏歌词纠错 UI 回归并增加旋转/隐藏恢复用例。
- Debug 提供逐字/逐行合成样本与静态合成封面，展示帧率、帧处理时间、内存及行/缓存数量。
- 验证状态与签收边界见 [Plan5-Validation.md](Plan5-Validation.md)。

## 版本与范围说明

- 最低部署目标：iOS/iPadOS 18。
- 音频由 Spotify 播放；项目不提供本地音乐播放。
- 项目不使用 WebView、JavaScriptCore、React、Tauri 或运行时插件执行环境。
- GitHub Actions 生成的 IPA 未签名，需要使用用户自己的 Apple 证书重签名后才能安装。
- 真实 Spotify、Apple Music、QQ Music、NetEase 服务联调和真机验证以各计划验证文档的“待验收”部分为准。

## 文档导出

- [ChatHistory-Export.md](ChatHistory-Export.md) 仅保留本轮当前对话中可访问的原始角色消息，不引入外部历史文件。
