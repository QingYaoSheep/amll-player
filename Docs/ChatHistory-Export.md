# AMLL Swift 对话记录导出

导出日期：2026-09-05  
项目：AMLL Player SwiftUI 原生重构  
分支：`swiftui-native`

## 导出范围说明

本文档整理当前对话上下文中可以访问的用户需求、决策和交付结果。平台曾对较早消息执行上下文压缩，因此无法恢复所有历史消息的逐字原文；缺失部分只记录已确认的事项，不补写未提供的内容。

此前用户提供的历史导出文件仍位于：`C:\Users\Administrator\Desktop\fullchathistory.txt`。该文件是本次导出的外部历史来源，内容没有被改写或删除。

## 项目迁移与范围决策

### 用户提出

- 将 `https://github.com/amll-dev/amll-player` 克隆到本地当前仓库。
- 阅读历史聊天记录与 `amll_spotify_multisource_lyrics_v0.29.21.js` 插件源码。
- 将插件集成到原生 AMLL 应用。
- 评估将应用重构为 SwiftUI 原生驱动的可行性。
- 删除本地音乐播放功能，仅保留 Spotify 连接。
- 将 SwiftUI 工程拆为七个执行计划。
- Xcode 构建、真机验证、GitHub 上传和 iOS SDK 27 构建均纳入工作流。

### 已确认的产品边界

- 音频始终由 Spotify 播放，不实现本地音频播放。
- 应用使用 SwiftUI、Spotify SDK、Spotify Web API 与原生歌词数据层。
- 不引入 WebView、JavaScriptCore、React、Tauri 或运行时插件执行环境。
- 语言范围以简体中文和英文为核心。

## 计划 1：原生工程与 CI 基础

- 初始化 SwiftUI 原生工程、XcodeGen 配置和测试 target。
- 建立 Xcode 26 构建、iOS Simulator 测试、iPad 构建和 archive 流程。
- 增加专用 Xcode 27 runner，输出未签名 IPA。
- 处理测试宿主、产品名称、Spotify SDK 嵌入和 Debug testability 问题。

## 计划 2：Spotify 授权、播放状态与控制

- 实现 PKCE 授权、Keychain 会话保存、网页授权回调。
- 设置页改为独立导航页面。
- 设置中增加“登录”分组、“登录到 Spotify”子页面和 Client ID 输入。
- 支持 App Remote 与 Web API 状态同步、播放/暂停、上一首/下一首、seek、音量和 Connect 设备切换。
- 增加底部迷你播放器，并使用原生 Liquid Glass/Material 降级。
- 处理退出、后台、前台恢复、回调 URI 和显式向后 seek。

## 计划 3：Spotify 完整音乐浏览

- 增加首页、搜索、音乐库和详情导航。
- 支持歌曲、专辑、艺人、歌单浏览，分页、刷新、短期缓存和取消旧请求。
- 对 Spotify 不向应用开放的内容显示外部打开入口。
- 保留搜索词和列表位置，支持按原始列表位置播放。
- 增加目录解码、限流/配额、401 重试和 UI 测试。

## 计划 4：多源歌词、缓存与人工纠错

- 增加 Apple Music、QQ Music、NetEase 多源歌词 Provider。
- 实现 Apple TTML、LRC、翻译、音译、对唱、背景声部、RTL 和逐词数据解析。
- 增加 SwiftData 原文与规范化缓存、Keychain Apple 凭据和缓存版本迁移。
- 支持候选搜索、预览、应用、人工锁定、恢复自动匹配和逐曲歌词延迟。
- 增加 86 个单元测试和 4 个 UI 测试。
- CI #23 验证通过：Xcode 26 lint、86/86 单元测试、4/4 UI 测试、iPad 构建、archive，以及 Xcode 27 SDK 构建和 IPA 打包。

## 计划 5：原生逐字歌词渲染引擎

### 当前需求

- 使用 SwiftUI 管理页面和状态，使用原生 UIKit/CALayer 与 `CADisplayLink` 绘制逐字歌词。
- 支持逐词渐变填充、当前行高亮、行间滚动、点击歌词 seek、翻译、音译、背景声部、对唱、RTL 和 VoiceOver。
- 支持拖动浏览歌词、暂停自动跟随、返回当前歌词、下滑关闭和 iPhone/iPad 布局。
- 歌词页暂不移植动态背景。
- 使用专辑封面作为静态背景：保持比例、aspect-fill 裁切铺满全屏、添加模糊和暗色遮罩。
- 用户明确删除“GPU 压力下自动降低背景和模糊质量”的计划与实现；模糊值由用户设置保持。

### 当前工作区状态

计划 5 的渲染代码在本次导出时处于工作区改动状态，尚未形成新的提交或 CI 结果。当前提交基线仍为 `40ee8fc6`。

## 当前对话中的导出请求

用户要求将当前聊天记录全部导出为 Markdown，并将项目 changelog 整合导出为 Markdown。对应文件为：

- `Docs/ChatHistory-Export.md`：本文件。
- `Docs/CHANGELOG.md`：按计划、提交和验证结果整理的项目变更记录。

