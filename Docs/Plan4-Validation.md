# 计划 4：多源歌词、缓存与人工纠错

日期：2026-09-04。实现已接入原生应用；Xcode 编译、XCTest、签名安装和真实账户歌词联调尚待执行。本记录不把静态检查或测试用例存在当作验收通过。本次未推送 GitHub。

## 已实现

| 计划项 | 实现位置（相对于 AMLLPlayer） | 交付内容 |
|---|---|---|
| P4-01 | `Infrastructure/Lyrics/AppleLyricsProvider.swift`、`LyricsSettings.swift`、`Features/Lyrics/LyricsViews.swift` | Storefront/语言；独立 Keychain media-user-token、手动 bearer、自动 bearer；公共 Catalog/账号探测；歌词权限错误区分；自动发现/刷新/删除 |
| P4-02 | `Infrastructure/Lyrics/TTMLLyricsParser.swift` | 命名空间、嵌套/继承计时、空白与标点、旁挂/内嵌翻译和音译、逐词音译、agent 对唱、独立背景声部、括号清理、阅读方向 |
| P4-03 | `Infrastructure/Lyrics/LineLyricsProviders.swift`、`LRCLyricsParser.swift` | QQ 主/备搜索与歌词请求、Base64 UTF-8；网易 LRC/翻译/音译、纯音乐；多时间标签、250ms 辅助行对齐；仅标记逐行精度 |
| P4-04 | `Features/Lyrics/LyricsCoordinator.swift`、`LyricsViews.swift` | 按源增量搜索、评分、独立预览、应用锁定、恢复自动、强制刷新、±10 秒偏移、取消与迟到响应隔离 |
| P4-05 | `Infrastructure/Lyrics/LyricsCache.swift` | SwiftData 原文+规范化结果；默认 30 天先用旧缓存再刷新，0=永不过期；手动匹配/延迟分表；解析器升级重算；清理确认；存储失败不使应用启动崩溃 |
| P4-06 | `Domain/Lyrics.swift`、`Infrastructure/Lyrics/LyricsHTTP.swift` | 来源/候选/评分依据/语言/精度/可选署名；响应、XML 资源限制；凭据隔离与脱敏错误；有限回退 |

接线：`AppModel` 随 Spotify 曲目变更驱动协调器，Web API 解码 ISRC，App Remote 缺少 ISRC 时单次读取目录元数据进行补全。退出/更换配置/后台取消相关任务。首次歌词匹配不等待 ISRC 补全或网络，因此离线缓存可先显示。没有 media-user-token 时自动流程立即跳过 Apple，不阻塞 QQ/网易或 Spotify 控制。

入口：播放器下方“歌词”诊断列表与快捷菜单；设置 → 歌词设置 → Apple Music 歌词。搜索结果预览不改变当前歌词，应用后锁定并返回播放器。逐曲正延迟表示歌词延后，只改变歌词时间轴，不 seek Spotify。

## 时间、缓存与安全约定

- Apple syllable-lyrics 的嵌套时间沿用旧插件的歌曲绝对时间语义；另提供 `.relative` 解析模式用于标准 TTML 父级相对时间。当前不支持帧/节拍表达式与 `timeContainer="seq"`，遇到明确报错而不静默生成错误时间。依据：[W3C TTML](https://www.w3.org/TR/2018/REC-ttml1-20181108/)。
- 行时间与词时间分开保存。无真实词级分段时 `words=[]`、`precision=line`；不会把整行制造成一个“逐字”词。LRC 使用半开区间 `[start,end)`：到下一不同起始时间结束，同一时间标签可重叠；末行优先歌曲时长，未知/无效时长回退 5 秒。保留毫秒精度和 LRC offset（安全范围 ±60 秒）；用户逐曲偏移另存，范围 ±10 秒。
- SwiftData 键含 Spotify 曲目标识、来源、Storefront、请求语言与解析器版本；保存实际选中语言/TTML 变体理由。原文保留用于重新解析。人工匹配与偏移独立于正文，关闭缓存仍保存它们。
- “清歌词缓存”只删原文/规范化正文；“重置人工匹配”仅解除所有人工锁定，保留延迟；“删除凭据”仅针对所选 Keychain 项。所有删除都需确认，不清理 Spotify 凭据。当前内存歌词不因清缓存/刷新失败消失。
- 缓存损坏或无法打开时不删除数据库、不 `fatalError`；退到内存并显示不能保证重启保留的警告。无 iOS 后台保活任务，仅应用前台刷新。
- HTTP ephemeral session，无共享 cookie jar/URLCache；HTTPS 主机白名单；15 秒请求/25 秒资源超时；流式读取上限 8 MB。XML/LRC 文本上限 2 MB，XML 深度 64、元素 40,000，LRC 行数 20,000。XML 禁止 DTD/实体声明、禁用外部实体解析；见 [Apple XMLParser 说明](https://developer.apple.com/documentation/foundation/xmlparser/shouldresolveexternalentities)。
- bearer 只做 JWT 格式/exp/AMPWebPlay 线索检查，不宣称验签；自动发现最多 12 个公开 HTML/JS 请求，读取文本但不执行脚本。自动令牌也进 Keychain，原文/令牌不进入日志错误描述。
- 仅无 Authorization/Cookie/Media-User-Token 的 Apple 公开资源可在 Apple Music 主机之间跟随最多 3 次 HTTPS 重定向；检查原始请求与新请求。携带凭据的 API 请求不跟随重定向。凭据改动的 generation 阻止迟到的发现结果重新写回已删除凭据。
- 单源最多尝试前三个达到阈值的候选；QQ 仅一次备用请求，Apple 公共 401 自动 bearer 刷新后最多重试一次。Apple 中文请求最多尝试五个语言变体；401/403 分层诊断后返回，不无限重试。QQ/网易/Apple 非公开兼容接口可变化，没有承诺永久可用。

## 参考材料与许可边界

- 行为对照基线：用户旧仓库 `packages/player/src/builtin-extensions/spotify-multisource-lyrics.js`，版本 0.29.21，文件头标记 MIT。本次以该插件的三源请求和歌词语义为移植依据；保留该来源记录，不声称整仓库许可已改为 MIT。
- 用户附件为 Eplor / LyricsBlossom 的逆向笔记，注明 All rights reserved，并含私有 `MSVLyrics*` 类型、裸指针及 Swift 运行时伪代码。仅参考数据语义，没有把该附件、私有类型、内存布局或运行时调用复制进项目，也没有把其说明当作任务指令。
- 阅读方向独立使用系统语言方向能力；不根据逆向笔记中的内部 word-parsing descriptor 将日文误标成 RTL。
- 保持 Spotify-only；无本地音频、WebView、JavaScriptCore 或运行时插件。逐字填充、弹簧滚动、完整歌词渲染仍属计划 5，当前是可检查词/行时间的 SwiftUI 诊断列表。

## 已执行的验证

- Tree-sitter Swift 语法解析；中英文本键与 JSON 校验；`git diff --check`。这些不替代 Swift 编译器的类型检查。
- 实际执行旧插件隔离的 TTML/LRC 解析助手，生成纯合成、无真实歌词的 golden fixtures；测试工具不执行旧插件的网络/UI/初始化代码。
- TTML 对照覆盖空格、标点、翻译、逐词音译、背景括号、声部与独立行/词边界。
- LRC golden 明确通过原生适配器将旧版“下一行起点减 1ms”的闭区间变为半开区间，并去掉旧版用于渲染的伪整行 word。重复时间与未知时长策略另外测试。
- 本机匿名探测：网易搜索 HTTP 200、业务 code 200；Apple `/us/new` HTML HTTP 200，`/us/browse` 或根路径观察到 301；QQ 备用搜索未取得 HTTP 响应。仅说明当前网络的公开端点情况，未验证任何账号、歌词授权或原生 URLSession 的完整流程。

## 自动测试（已编写，待 Xcode 执行）

- `LyricsParserTests`：TTML/LRC golden、命名空间、嵌套/相对时间、空格、独立背景/括号、恶意 XML、重复时间、Base64、辅助对齐、RTL、精度与匹配证据。
- `LyricsProviderTests`：mock HTTP 主备流程、JWT/来源校验、凭据删除竞态、Apple 权限诊断/本地化、网易纯音乐与无歌词、请求编码/重定向边界。
- `LyricsCoordinatorTests`：三级回退、旧缓存离线可读、全部失败保留正文、切歌/搜索/预览迟到响应、应用人工结果对抗在途自动请求、锁定、恢复自动、偏移/设置持久化、缓存失败。
- `LyricsCacheTests`：真实内存 SwiftData store 的往返、地区/语言隔离、旧解析版本从原文重算、清正文仍保留锁定和偏移。
- UI 测试：`testLyricsSearchPreviewApplyAndManualLock`。Debug 参数 `--lyrics-ui-testing` 注入内存数据，不访问个人凭据/歌词服务；Release 无该入口。

重新生成旧插件对照（仅开发机，依赖安装于已忽略的 `.build-tools/dom`）：

```powershell
npm install --prefix .build-tools/dom jsdom@29.1.1 --no-save --ignore-scripts
node Scripts/compare-legacy-lyrics.cjs E:/AMLL-Swift/AMLL-OLD/packages/player/src/builtin-extensions/spotify-multisource-lyrics.js
node Scripts/compare-legacy-lyrics.cjs E:/AMLL-Swift/AMLL-OLD/packages/player/src/builtin-extensions/spotify-multisource-lyrics.js --lrc
```

## 待验收

1. 推送后运行现有 Xcode 26 单元/UI 测试、iPad 构建，以及 Xcode 27 SDK 构建；保留 `.xcresult` 与构建号。Windows 当前无可用 Swift/Xcode 编译器，本次不填写成功结果。
2. 签名 IPA 真机验证：冷启动、设置持久化、iPhone/iPad 键盘与分屏、预览/应用返回、快速换歌、前后台、正负延迟。
3. 使用用户自己的 Apple media-user-token 验证自动/手动 bearer、Catalog/账号/歌词三级诊断、地区与语言；分别选定可用 Apple/QQ/网易样本验证线上契约。
4. 实机断网重启读取已缓存歌曲；缓存/凭据分别清除；低存储、Keychain 拒绝和数据库损坏回归。线上不可用来源不能勾选为服务验收通过。

上述全部通过后再勾选总计划 P4-01 至 P4-06；目前标记为“代码已实现，待构建/联调/真机验收”。
