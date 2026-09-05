# AMLL Player SwiftUI 原生版

AMLL Player 正在重构为仅面向 iPhone 与 iPad 的 SwiftUI 原生应用。音频始终由 Spotify 播放；本应用负责 Spotify 音乐浏览、远程控制与原生同步歌词。

当前仓库已经完成计划 1 的工程基础和计划 2 的 Spotify 纵向切片：PKCE 授权、Keychain 会话、App Remote/Web API 状态同步、实时进度、播放控制与 Connect 设备切换。

计划 3 的音乐浏览代码已加入：登录后显示首页、搜索、音乐库，支持歌曲/专辑/艺人/歌单详情、分页、刷新、外部打开以及按列表位置播放。Xcode 与真机验收状态见 [计划 3 验证记录](Docs/Plan3-Validation.md)。

## 本地配置

计划 4 已接入 Apple/QQ/网易多源歌词、缓存与人工纠错。计划 5 仅用用户提供的 Apple Music 原图确定全屏页面构图，逐字动效、TextKit/CALayer 歌词绘制和 Metal 专辑背景直接移植 AMLL。实现、CI 结果与待真机验收项目分别见 [计划 4 验证记录](Docs/Plan4-Validation.md) 和 [计划 5 验证记录](Docs/Plan5-Validation.md)。Debug 构建可在设置中打开离线歌词渲染预览。

1. 在 Spotify Developer Dashboard 创建 iOS 应用。
2. Bundle ID 设置为 `net.stevexmh.amllplayer`。
3. 注册回调地址 `amllplayer://spotify-callback`。
4. 在应用右上角打开设置 → 登录 → 登录到 Spotify。
5. 输入自己的 Client ID 并点击授权登录，完成系统网页 PKCE 授权。无需 Client Secret；构建配置仍可提供可选默认值。

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
- 音乐库保持只读，不增加收藏、关注或歌单写权限；不可访问的内容提供 Spotify 外部入口。
- 搜索每页 10 条；近期播放去重，歌单保留重复曲目和原始播放位置。返回详情前的列表位置和搜索词保留。
- 目录缓存仅在内存中保留，60 秒内复用，强制刷新可更新；退出、换 Client ID 或检测到账户变化会失效。

## 许可证

AGPL-3.0，详见仓库 LICENSE。Spotify SDK 等第三方组件遵循各自许可证。
