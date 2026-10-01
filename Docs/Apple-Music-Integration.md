# Apple Music 原生接入台账

2026-10-01，基线 `8bd19c28`，当前工程提交 `01e55d22`。执行用户批准的完整接入计划，使用 SystemMusicPlayer.shared。

| 环节 | 当前工程 | 验证 |
|---|---|---|
| 官方授权 | MusicAuthorization、订阅更新、用户 storefront、权限说明、重签诊断入口 | Apple 设备及实际签名待验证 |
| 双服务 | 共享目录/播放/资料库接口、Spotify 兼容适配、持久来源选择、旧缓存 ID 兼容 | 当前提交隔离、切源与旧存储自动回归通过 |
| 数据浏览 | 主页五分区、目录与资料库搜索、建议/历史、详情、分页、下载过滤与原生名称排序 | Xcode 27 设备归档通过；真实账号数据待验证 |
| 系统播放 | 250ms 前台采样、外部 seek 修订、上下文位置起播、随机/循环、系统 AirPlay/音量 | Xcode 27 编译及模拟服务测试通过；系统音乐真机待验证 |
| 写入 | 官方收藏/加资料库、创建/追加、仅应用创建歌单编辑/重排/删除条目 | 真实写入与权限待验证 |
| 歌词与封面 | 统一曲目标识、ISRC、三源歌词、人工匹配/offset、独立音译、原静音动态封面 | 保留现有回归；设备并发待验证 |
| 发布 | 保留 Xcode 27 直接 IPA 与测试后 IPA 两路 | `01e55d22` 两路归档及包检查通过，324 项单元与 5 项 UI 零失败 |

## 2026-10-01 开发者令牌失败与系统同步分离

用户通过全能签安装后报告开发者令牌请求失败；相同证书和工具安装的 Lyricify Mobile 能同步系统当前歌曲和歌词，但尚未验证目录歌单与搜索。因此不能由该比较断定本应用目录令牌应可用，也不能把原因直接归于签名服务。

修复系统授权与目录服务耦合：授权通过后立即启用 SystemMusicPlayer 观察，不等待订阅/storefront 请求；这些请求失败仅撤下目录、资料库写入与目录起播能力，保留当前系统歌曲/进度与歌词链路。现有队列的控制仍使用同一 SystemMusicPlayer，不抓取网页令牌、不新增服务器或另一套播放器。目录恢复、权限撤销、断开、迟到请求以及订阅更新继续使用独立代次检查。

登录页分别显示系统同步和歌单/搜索状态，目录未验证时不误报无订阅或云资料库关闭；安装诊断先读取系统歌曲，再检查目录请求。新增令牌失败、授权后立即观察、断开时迟到结果的回归，并扩展离线恢复覆盖。Windows 未执行旧实现 Swift 红灯，Apple 平台单元/UI 和两路 IPA 等待当前提交 CI；实际重签环境系统歌曲及歌词同步仍待安装确认。此修改不声称已解决官方开发者令牌签发，也不保证未验证的设备授权成功。

## 系统同步实测与本地封面补充

用户确认安装 b182e181 后歌曲名称、歌手、歌词和真实播放进度正常；主页歌单仍报开发者令牌失败，专辑封面未显示。该实测确认基本同步可用，不代表目录授权通过。新增只读 MediaPlayer 系统封面补充，可靠目录 ID 优先、否则严格匹配标题/艺人/专辑/时长，避免外部切歌时配错封面。其他播放控制仍全部使用 SystemMusicPlayer。

系统 PNG 独立缓存，24 MiB／最多 6 图，后台 actor 串行写入；异步结果匹配曲目代次，断开取消待处理结果，系统清理文件后重新获取。迷你栏、普通播放器、两种歌词页和 Mesh/Pixi 均支持本地图片，原远程图片路径保留。新增真实 PNG 读取、迟到结果、匹配及缓存预算回归。只有队列文本且没有 Song 模型的条目仍保留原边界，不通过弱化匹配猜测封面。

封面修复当前待 Xcode 27 CI 和设备显示确认。目录 token 签发仍是独立阻塞，不宣称通过本地封面解决歌单/搜索；自动 token 需要对应实际 App ID 的官方 MusicKit 服务配置或另外明确授权的官方 token 方案。

## 当前交付与自动验证

源码及测试提交 `01e55d22a66c74b83d4ea6f62f51d61b89a6782b` 的 [Xcode 27 CI 36801350703](https://github.com/QingYaoSheep/amll-player/actions/runs/36801350703) 已完成两路归档及包检查。iPhone 执行 324 项单元测试和 5 项 UI 测试，全部通过；iPad 与通用 iOS 27 模拟器构建通过。UI 实际验证未配置 Spotify 时可进入 Apple Music 授权页，未模拟真实授权成功。

| 产物 | Artifact ID | IPA 字节数 | SHA-256 |
|---|---|---|---|
| 直接 IPA | `11135498100` | 21,580,192 | `e7f9404313bfaba3598d86201cfb620c80240f2c7deca8d0592d09b963ab322d` |
| 测试后 IPA | `11136424847` | 21,580,192 | `1df38fa77fbefe93b7bbffd270ebede123acb8ec7276ee143eadd5bd11c80c5c` |

测试结果产物为 `11136701209`，视觉附件为 `11136746178`。本地交付目录为 `E:/AMLL-Swift/Builds/AppleMusic-01e55d22`，包含两份 unsigned IPA、安装说明与 `build-manifest.json`。两路都可重签；直接版与测试版仍按各自任务独立构建，不以直接构建成功代替测试。

Windows 15 项 Node 回放/轨迹/性能比较工具回归通过，固定音译词典哈希校验通过（包内资源 21,565,125 字节），修改文件格式与 diff 检查通过。代码审查发现的授权代次、订阅观察恢复、迟到结果、歌单编辑加载及错误归属问题已修复并加入回归。

**仍待实际设备验证：**第三方重签 MusicKit 服务配置、真实账号授权/订阅/资料库、系统音乐外部操作、官方写入、AirPlay、动态封面并发音频与 15 分钟设备资源/视觉检查。上述项目没有以编译、模拟服务或 UI 导航测试替代，不标记完整设备接入验收通过。

## 配置与设备验证

1. 签名方必须为重签后的实际显式 Bundle ID 开启 MusicKit App Service，配置对应证书/描述文件。默认工程 Bundle ID 为 net.stevexmh.amllplayer。不能用不同 App ID 的签名成功来证明服务可用。
   用户当前暂不确定签名服务是否支持此配置；保持现有 Bundle ID，不自动修改签名身份。设备上的安装环境验证入口用于记录实际结果。
2. 工程包含 MusicKit、NSAppleMusicUsageDescription；自动开发者 token 和用户 token 由官方 MusicKit 请求管理。不内置私钥、token 服务器或网页登录 token 抓取。
3. 设置 → 登录到 Apple Music 完成系统授权，然后运行安装环境验证。选择当前来源 Apple Music，在搜索结果播放歌曲，检查系统音乐、锁屏、控制中心外部切歌与正反 seek。
4. 记录重签 Bundle ID、设备/系统、安装工具及服务配置；不要记录证书私钥、令牌或带凭据 URL。
5. 分别验证拒绝/受限、订阅失效、同步资料库关闭、AirPlay、前后台、动态封面启用/循环时歌曲不暂停，以及 15 分钟资源有界性。Windows 和模拟授权不能代替以上结果。

## 数据与能力边界

- 当前来源升级默认 Spotify；切换来源只停止观察和替换 UI 数据，不发送播放/暂停/队列重建。两者授权可并存。
- 目录、资料库和歌单条目位置分别保存。Spotify 旧缓存键不变；Apple 曲目键按服务/范围命名，ISRC 不自动跨版本共享 offset。
- 私人页面缓存为内存，受连接代次、地区和权限变化约束；不把临时连接 UUID 伪装成 Apple 账号 ID。
- 本应用创建的歌单 ID 按安装 Bundle ID 保存，重启及断开重连后保留。只对当前真实资料库返回的匹配项目展示编辑入口，实际编辑仍由 MusicLibrary 校验应用创建权限；不会将其他可追加歌单视为本应用创建。该记录不缓存私人歌单名称或内容。
- 系统队列只显示公开可读的当前条目；完整外部队列通过系统音乐查看。应用发起的上下文播放交给原专辑/歌单，不拼接第一页队列。
- MV 只检索、详情、官方打开；本应用不另建视频音乐播放器。未核实公开支持的取消收藏/系统队列删除操作不开放。歌单条目编辑只允许应用创建的歌单，全部条目准备完成后才能编辑，保留重复位置。
- Song.hasLyrics 不提供官方逐字正文。MusicKit 凭据不发送给歌词和动态封面发现服务。

## 官方依据

[MusicKit 自动 token](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)、[系统播放器](https://developer.apple.com/documentation/musickit/systemmusicplayer)、[订阅状态](https://developer.apple.com/documentation/musickit/musicsubscription)、[资料库请求及已下载过滤](https://developer.apple.com/documentation/musickit/musiclibraryrequest)、[歌单上下文起播](https://developer.apple.com/documentation/musickit/musicplayer/queue/init(playlist:startingat:))、[应用创建歌单编辑限制](https://developer.apple.com/documentation/musickit/musiclibrary/edit(_:name:description:authordisplayname:))、[收藏](https://developer.apple.com/documentation/applemusicapi/add-resource-to-favorites)。

当前不能宣称实际重签授权、设备音频/视觉或性能验收通过。

## 代码审查与首次构建修复

首个工程提交 `e5a4cc43` 的 Actions `36797370941` 找到登录页 Section 构造与 Combine 观察闭包显式 self 两处编译问题，已修复。增加独立授权检查代次、完整歌单加载状态、跨切源设备结果隔离、原子随机起播及入队连接校验；补充对应异步回归。歌词页提供实际 Apple Music 收藏与系统队列入口，歌词操作继续保留在菜单中。

后续修复 Swift 6 SDK 的 SystemMusicPlayer 异步标注兼容和 MainActor 资料库回调，保留完整严格并发检查。`c0f4b9c9` 的 Actions `36799377223` 直接 IPA 成功，323 项单元测试零失败；5 项 UI 测试中唯一失败为旧“仅连接 Spotify”断言，与新增双服务入口冲突。`01e55d22` 更新该用例，实际进入 Apple Music 登录页并检查授权按钮，同时继续验证 Spotify 登录流程，不触发模拟系统授权。被替代的 `0a004d9e` 测试运行已取消，不计为通过。
