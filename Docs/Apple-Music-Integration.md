# Apple Music 原生接入台账

2026-10-01，基线 `8bd19c28`。执行用户批准的完整接入计划，使用 SystemMusicPlayer.shared。

| 环节 | 当前工程 | 验证 |
|---|---|---|
| 官方授权 | MusicAuthorization、订阅更新、用户 storefront、权限说明、重签诊断入口 | Apple 设备及实际签名待验证 |
| 双服务 | 共享目录/播放/资料库接口、Spotify 兼容适配、持久来源选择、旧缓存 ID 兼容 | 新增隔离与切源测试，等待 Xcode 27 |
| 数据浏览 | 主页五分区、目录与资料库搜索、建议/历史、详情、分页、下载过滤与原生名称排序 | 编译和自动测试待 CI |
| 系统播放 | 250ms 前台采样、外部 seek 修订、上下文位置起播、随机/循环、系统 AirPlay/音量 | 编译和实际设备待验证 |
| 写入 | 官方收藏/加资料库、创建/追加、仅应用创建歌单编辑/重排/删除条目 | 真实写入与权限待验证 |
| 歌词与封面 | 统一曲目标识、ISRC、三源歌词、人工匹配/offset、独立音译、原静音动态封面 | 保留现有回归；设备并发待验证 |
| 发布 | 保留 Xcode 27 直接 IPA 与测试后 IPA 两路 | 本次提交构建待运行 |

## 配置与设备验证

1. 签名方必须为重签后的实际显式 Bundle ID 开启 MusicKit App Service，配置对应证书/描述文件。默认工程 Bundle ID 为 net.stevexmh.amllplayer。不能用不同 App ID 的签名成功来证明服务可用。
2. 工程包含 MusicKit、NSAppleMusicUsageDescription；自动开发者 token 和用户 token 由官方 MusicKit 请求管理。不内置私钥、token 服务器或网页登录 token 抓取。
3. 设置 → 登录到 Apple Music 完成系统授权，然后运行安装环境验证。选择当前来源 Apple Music，在搜索结果播放歌曲，检查系统音乐、锁屏、控制中心外部切歌与正反 seek。
4. 记录重签 Bundle ID、设备/系统、安装工具及服务配置；不要记录证书私钥、令牌或带凭据 URL。
5. 分别验证拒绝/受限、订阅失效、同步资料库关闭、AirPlay、前后台、动态封面启用/循环时歌曲不暂停，以及 15 分钟资源有界性。Windows 和模拟授权不能代替以上结果。

## 数据与能力边界

- 当前来源升级默认 Spotify；切换来源只停止观察和替换 UI 数据，不发送播放/暂停/队列重建。两者授权可并存。
- 目录、资料库和歌单条目位置分别保存。Spotify 旧缓存键不变；Apple 曲目键按服务/范围命名，ISRC 不自动跨版本共享 offset。
- 私人页面缓存为内存，受连接代次、地区和权限变化约束；不把临时连接 UUID 伪装成 Apple 账号 ID。
- 系统队列只显示公开可读的当前条目；完整外部队列通过系统音乐查看。应用发起的上下文播放交给原专辑/歌单，不拼接第一页队列。
- MV 只检索、详情、官方打开；本应用不另建视频音乐播放器。未核实公开支持的取消收藏/系统队列删除操作不开放。歌单条目编辑只允许应用创建的歌单，全部条目准备完成后才能编辑，保留重复位置。
- Song.hasLyrics 不提供官方逐字正文。MusicKit 凭据不发送给歌词和动态封面发现服务。

## 官方依据

[MusicKit 自动 token](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)、[系统播放器](https://developer.apple.com/documentation/musickit/systemmusicplayer)、[订阅状态](https://developer.apple.com/documentation/musickit/musicsubscription)、[资料库请求及已下载过滤](https://developer.apple.com/documentation/musickit/musiclibraryrequest)、[歌单上下文起播](https://developer.apple.com/documentation/musickit/musicplayer/queue/init(playlist:startingat:))、[应用创建歌单编辑限制](https://developer.apple.com/documentation/musickit/musiclibrary/edit(_:name:description:authordisplayname:))、[收藏](https://developer.apple.com/documentation/applemusicapi/add-resource-to-favorites)。

当前不能宣称实际重签授权、设备音频/视觉或性能验收通过。
