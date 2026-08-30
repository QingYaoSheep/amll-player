# AMLL Player SwiftUI 原生版

AMLL Player 正在重构为仅面向 iPhone 与 iPad 的 SwiftUI 原生应用。音频始终由 Spotify 播放；本应用负责 Spotify 音乐浏览、远程控制与原生同步歌词。

当前仓库已经完成计划 1 的工程基础和计划 2 的 Spotify 纵向切片：PKCE 授权、Keychain 会话、App Remote/Web API 状态同步、实时进度、播放控制与 Connect 设备切换。

## 本地配置

1. 在 Spotify Developer Dashboard 创建 iOS 应用。
2. Bundle ID 设置为 `net.stevexmh.amllplayer`。
3. 注册回调地址 `amllplayer://spotify-callback`。
4. 将 `Configuration/Secrets.xcconfig.example` 复制为 `Configuration/Secrets.xcconfig`。
5. 在未跟踪的配置文件中填写自己的 Client ID。

Spotify Development Mode 要求把测试用户加入 allowlist。不要提交 Client ID、令牌、证书或描述文件。

## Spotify 授权与播放

- 授权默认优先使用已安装的 Spotify App，未安装时由 SDK 回退到网页 PKCE。
- 会话使用仅限本机的 Keychain 项保存；注销会立即删除。
- Spotify App Remote 可用时订阅近实时状态，连接失败或未安装 Spotify 时自动使用 Web API 轮询。
- 支持播放、暂停、上一首、下一首、seek、音量、播放 URI，以及 Spotify Connect 设备列表和切换。
- 进入后台会断开 App Remote 并停止轮询；回到前台会刷新令牌、重连并重新校准进度。
- Web API 播放控制和点播 URI 需要 Spotify Premium。没有活跃设备时，应用会提示先打开 Spotify 或选择 Connect 设备。

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
- 计划 3 的首页、搜索、音乐库和内容详情尚未实现。

## 许可证

GPL-3.0。Spotify SDK 等第三方组件遵循各自许可证。
