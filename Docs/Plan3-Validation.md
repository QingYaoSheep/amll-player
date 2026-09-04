# 计划 3：实现与验收记录

日期：2026-09-04。代码已实现，尚未通过 Xcode 编译、XCTest 或真机验收；不要把下方测试清单理解为已执行成功。

## 实现范围

| 项目 | 实现位置 | 状态 |
|---|---|---|
| 首页个人资料与六个独立区块、查看全部 | `Features/Catalog/SpotifyBrowserView.swift` | 已实现，待设备验证 |
| 四类搜索、350ms 防抖、取消旧请求、分页 | 同上、`SpotifyCatalogStore.swift` | 已实现，待 XCTest/UI 测试 |
| 只读音乐库、歌曲/专辑/艺人/歌单详情 | `CatalogDetailView.swift`、`Domain/SpotifyCatalog.swift` | 已实现，待服务联调 |
| 返回保留搜索/滚动位置、短期缓存、退出失效 | `SpotifyCatalogStore.swift`、`AppModel.swift` | 已实现，待测试 |
| 按 Spotify Connect 设备和原始列表位置播放 | `SpotifyWebAPIClient.swift`、`SpotifyPlaybackCoordinator.swift` | 已实现，待真机 |
| 部分失败、空状态、重试、外部 Spotify 打开 | `CatalogComponents.swift` | 已实现，待 UI 验证 |
| 401 单次刷新重试、429 等待、配额熔断 | `SpotifyCatalogClient.swift` | 已实现，附 mock HTTP 测试 |

以上 `Features/` 等路径相对于 `AMLLPlayer/`。保留原来的登录设置导航和 Liquid Glass 迷你播放器，底栏封面/文字可打开正在播放页。未引入本地播放、歌词渲染、收藏写入或运行时插件。

## API 契约核对

- 搜索以 10 条分页；歌单使用 `/playlists/{id}/items`，解码兼容 `items/tracks`、`item/track` 两套字段。[Spotify 迁移说明](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)、[歌单条目](https://developer.spotify.com/documentation/web-api/reference/get-playlists-items)。
- 账户优先使用不可变 `account_id`；缺失时仅为本次会话兼容旧 `id`，不持久化个人目录数据。[个人资料](https://developer.spotify.com/documentation/web-api/reference/get-current-users-profile)。
- 普通 429 尊重秒数或 HTTP 日期格式的 `Retry-After`；`QUOTA_EXCEEDED` 停止后续目录请求，不自动循环重试。退出/重新连接重建请求层。[2026 年 7 月变更](https://developer.spotify.com/documentation/web-api/references/changes/july-2026)。
- 专辑/歌单曲目使用 `context_uri + offset.position`，保留 null/不可用曲目留下的位置，重复曲目不去重。[播放控制](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback)。
- 所有目录请求只使用 GET；分页只接受 `https://api.spotify.com/v1/`，禁止带 bearer 的重定向。个人目录网络请求采用 ephemeral session；图片使用独立的有界缓存。
- 收藏/近期列表去重保留首次出现；歌单/专辑维持原始顺序。元数据可读取但条目不可访问时显示外部打开，不伪造曲目。

## 自动测试（已编写，待 Xcode 执行）

- `SpotifyCatalogDecoderTests`：新旧字段、空/缺失条目、重复歌单曲目位置、近期去重、cursor、已保存专辑、地区/本地/非音乐内容、元数据降级、ISRC/艺人/专辑、账户字段、搜索编码、分页域名、错误分类、Retry-After、播放请求字段。
- `SpotifyCatalogStoreTests`：缓存命中/强制刷新、追加分页和重复 cursor、局部失败、取消后的迟到响应、退出与账户切换。
- `SpotifyCatalogHTTPTests`：真正通过 URLSession/URLProtocol mock 验证配额/限流阻止后续 HTTP、401 刷新后最多重试一次及 GET 方法。
- `AMLLPlayerUITests`：保留登录配置回归，新增已登录导航、元数据歌单提示和搜索进入详情再返回。
- Debug 启动参数 `--catalog-ui-testing` 仅注入内存 fixture，不访问真实账号、Keychain 或网络；Release 不编译该入口。

在 Mac/Xcode 执行：

```bash
bash Scripts/generate-project.sh
xcrun swift-format lint --recursive AMLLPlayer AMLLPlayerTests AMLLPlayerUITests
xcodebuild test -project AMLLPlayer.xcodeproj -scheme AMLLPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  -resultBundlePath build/Plan3-tests.xcresult CODE_SIGNING_ALLOWED=NO
```

执行前选择当前 Mac 上真实可用的模拟器名称；SDK 27 设备 Archive 沿用现有 CI 任务。新增 Swift 文件由 XcodeGen 目录发现，无需手工维护 `.xcodeproj`。

## 本次实际检查

- Windows 本地 `git diff --check`、String Catalog JSON/键覆盖、Swift Tree-sitter 语法解析。
- 没有本地 `swift`/`xcodebuild`；现有 WSL 发行版启动失败。未向 GitHub 推送或触发 CI。
- Tree-sitter 不检查 Swift 类型、SDK API 可用性、并发隔离或 SwiftUI 实际布局；XCTest/UI 测试仍是验收必需项。

## 真机签收清单

- [ ] Xcode 26 测试、iPad 构建、SDK 27 Archive 通过，签名 IPA 安装冷启动正常。
- [ ] 真实登录后六区块独立加载；某区块 403/断网不影响其余页面。
- [ ] 四类搜索快速输入/切换类型无旧结果覆盖，分页无重复，返回保留搜索和列表位置。
- [ ] 音乐库四类入口和四类详情的分页/刷新/空状态正确；非本人或不可访问歌单有外部入口。
- [ ] iPhone/iPad/分屏与大字号下内容、设置、底栏和键盘不相互遮挡；VoiceOver 能区分详情与播放按钮。
- [ ] 从专辑/歌单第二页播放选中项，重复歌曲仍从正确位置开始；播放目标为选择的设备。
- [ ] 无设备/受限设备/非 Premium 等失败有明确提示与 Spotify 外部打开，音频仍由 Spotify 播放。
- [ ] 退出、换 Client ID、换账号和刷新令牌期间，没有旧个人目录或迟到响应重新出现。

未通过上述签收前，`Plan.md` 的 P3-01 至 P3-04 不勾选为“已验收”。
