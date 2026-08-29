# AMLL Player SwiftUI 原生版

AMLL Player 正在重构为仅面向 iPhone 与 iPad 的 SwiftUI 原生应用。音频始终由 Spotify 播放；本应用负责 Spotify 音乐浏览、远程控制与原生同步歌词。

当前仓库已经完成计划 1 的基础骨架：XcodeGen 工程、SwiftUI 应用入口、基础分层、单元/UI 测试、简中/英文资源、脱敏诊断以及 GitHub Actions。

## 本地配置

1. 在 Spotify Developer Dashboard 创建 iOS 应用。
2. Bundle ID 设置为 `net.stevexmh.amllplayer`。
3. 注册回调地址 `amllplayer://spotify-callback`。
4. 将 `Configuration/Secrets.xcconfig.example` 复制为 `Configuration/Secrets.xcconfig`。
5. 在未跟踪的配置文件中填写自己的 Client ID。

Spotify Development Mode 要求把测试用户加入 allowlist。不要提交 Client ID、令牌、证书或描述文件。

## 生成工程

```bash
bash Scripts/generate-project.sh
open AMLLPlayer.xcodeproj
```

生成的 `.xcodeproj` 不进入 Git；本地和 CI 都通过固定版本的 XcodeGen 重建。

## Xcode 27 构建产物

每次推送都会使用专用 Xcode 27 runner，并上传
AMLLPlayer-Xcode27-unsigned.ipa。该文件用于后续重签名，没有 Apple 开发签名时
不能直接安装到普通 iPhone 或 iPad。

## 当前边界

- 最低 iOS/iPadOS 18。
- 不包含 WebView、React、Tauri、Rust 或 JavaScript 插件运行时。
- 不播放本地音频，也不申请后台音频能力。
- Spotify 授权与播放功能将在计划 2 实现。

## 许可证

GPL-3.0。Spotify SDK 等第三方组件遵循各自许可证。
