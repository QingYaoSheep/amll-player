# Apple Music 风格首页与私人 FM

## 范围与实现

接续首页方案既有实现，保留首页／音乐库／搜索导航、迷你播放器与三服务播放适配。首页采用大标题、圆形账户菜单、3:4 精选海报和方形封面横排；普通首页卡片不叠加播放按钮。歌词生产文件、播放时钟、无损 seek、HDR、音译与封面合成本轮不修改。

| 能力 | 实现 |
|---|---|
| 首页结构 | `MusicHomeProviding`、`MusicHomeStore`，栏目稳定身份、独立状态、最多三个并发请求、分页与重复条目 |
| 账户入口 | 当前来源及连接状态、三来源切换、账号、设置、设备／AirPlay；真实头像或系统账户图标 |
| Apple Music | 原始推荐分组与理由、个人电台、直播电台、年度 Replay；权限不足保留统一连接提示 |
| 网易云 | 新碟、放松／快乐／伤感分类歌单、既有个人栏目、用户主动启动的私人 FM |
| Spotify | 最近播放、常听、个人歌单、收藏与关注歌手；不新增受限的新发行／推荐请求 |
| FM | 单播放器、自动补歌合并、有界历史／待播／去重、暂停与迟到请求隔离、普通队列备份及暂停恢复 |

## 本次闭合

- 将上一轮尚未提交的 Replay 分页模型、请求、首批种子及“查看全部”入口接入同一数据链。
- 推荐组缺少内嵌 contents 时，先创建其可观察状态，再发布分组；后续真实推荐完成会更新精选，避免一直显示回退卡片。
- FM 开始播放前，以实际交接时刻捕获普通队列和进度；中断取消尚未完成的启动。
- FM 显式重试和恢复播放共享一个补歌任务，结束后释放任务句柄，避免重复请求或后续不再续播。
- 在 FM 队列点播时同步裁剪历史；避免点击待播末尾再补歌超出61条，写出无法恢复的记录。
- 保留 FM 最多两次重试、五首不可播放后暂停、切源／重启恢复为暂停，以及退出后恢复普通随机／循环配置。

## 两轴审查

### Standards

发现并修正队列点播没有执行 FM 历史裁剪的问题：50首历史＋当前＋10首待播时，点播尾部后补歌可能超过持久化上限。新增通过真实 AVPlayer 的边界及保存校验测试。

### Spec

发现并修正未内嵌内容的推荐组无法可靠更新顶部精选的问题。新增 Observation 行为测试；补全生产页面 FM 启动、禁用随机、队列状态与退出恢复流程。真实账号和设备结果分别记录。

## 验证

固定本轮起点为 `50e183c4fe6350532d86b8d9f2bd08f0b62dad1d`。原工作区补丁与文件清单保存在 `Builds/Home-FM-Completion-20261025/initial-worktree.patch` 和 `initial-status.txt`；独立歌词回放修改保留。

| 验证 | 状态 |
|---|---|
| 本地 Node 回归 | 15项通过；当前工作区的既有回放修改未提交 |
| 首页模型、推荐及 Replay | 9项通过，包含非内嵌推荐的可观察更新与 Replay 续页 |
| FM、真实 AVPlayer、无损 seek | FM播放10项、队列状态2项、seek7项通过 |
| iPhone／iPad 页面与截图 | 手机8项＋FM补测1项通过；iPad首页及大字体2项通过，保留原始截图 |
| 两路 Xcode27 IPA | 同提交直接包成功；完整回归539单元通过，UI29项中3项失败，因此没有测试后IPA |
| 实际账号 | 网易云首页与私人 FM 已获用户设备确认；Apple Music 私人数据仍需单独账号验收 |
| 真机性能 | iPhone16Pro／13英寸iPadPro十五分钟、温度、后台及锁屏续播待验收 |

完整回归沿用原断言，已有歌词／封面失败独立记录，不据此放宽测试或生成“测试通过”的包。专项页面使用显式 DEBUG 夹具，不能替代真实账号验收。

## 官方及协议依据

- [Apple WWDC25 新设计系统](https://developer.apple.com/videos/play/wwdc2025/356/)：内容与控制分层，系统导航及材质。
- [Apple Music Replay](https://developer.apple.com/documentation/applemusicapi/get-the-user%27s-replay-data)：最近符合资格的年份及 top-songs／top-albums／top-artists。
- [Apple Music 直播电台](https://developer.apple.com/documentation/applemusicapi/get-the-apple-music-live-radio-stations)：`filter[featured]=apple-music-live-radio`。
- [Spotify 2026开发模式迁移](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)：按当前可用能力展示栏目。
- 网易云新增栏目和 FM 沿用 `ReferenceCaptures/netease-inputs.json` 固定的社区来源及许可证，不增加服务器或解锁服务。

## 已交付直接包与设备确认

- 实现提交 `af9837ef`；Swift6测试夹具修正 `b07d8403`；现有首页导航回归改走账户菜单 `b6b1ec09`。
- [两路构建](https://github.com/QingYaoSheep/amll-player/actions/runs/40154504568)：`b6b1ec091e0822bf4f51d6c5d340b9536731384c` 直接 IPA 已成功；完整回归539单元通过、29UI中3项失败，没有测试后IPA。
- [首页／FM专项](https://github.com/QingYaoSheep/amll-player/actions/runs/40154504563)：28单元和8项手机UI通过；FM定位修正及iPad检查由下述补测闭合。
- 直接包 `Builds/Home-FM-Completion-20261025/b6b1ec09-direct/AMLLPlayer-Xcode27-direct-unsigned.ipa`；22,579,776字节；SHA-256 `a526e3cb065b0d3b4d8e4c9e75a54a57bb82d92b93ab014917c9615736510fc7`。已读取包内 Info.plist 核对提交号和 `net.stevexmh.amllplayer`。
- 2026-10-25 用户安装该包后确认：网易云首页大卡与封面横排、右上账户菜单、私人 FM 连续跳歌、退出 FM 后恢复普通队列为暂停，均正常。
- 同日匿名实测新碟与放松／快乐／伤感分类四个公开接口，均返回 HTTP200／业务200，且具有预期的数据与分页字段；脱敏结果保存在 `Builds/Home-FM-Completion-20261025/public-api-results.json`。
- 两轴复核修正后均无新的确定阻断项。原11项已跟踪回放工作区补丁与任务开始时逐块相同，另两项未跟踪文件仍保留；未提交或改写它们。

保留首轮并发编译失败日志：测试夹具的 MainActor 静态工厂返回非 Sendable 响应，已通过声明纯数据工厂 nonisolated 修正。基线 `6fdb99a1` 完整运行为531单元通过、28UI中5项失败：其中3项旧首页测试仍找独立设置按钮，现已改走真实账户菜单；另2项为既有歌词UI断言，保留断言并单独对照最终结果。

尚未执行的真实 Apple Music 私人接口、十五分钟热状态和性能验收，不包含在用户本次设备确认中。

## 自动回归与原始截图

`b6b1ec09` 完整回归：539单元零失败；29UI中26项通过、3项失败。两项既有歌词用例为 `testAppleMusicAndNetEasePlaybackControlsUseTheirExistingQueues` 和 `testImmersiveLyricsModeStaysOpenPersistsAndFallsBackInLandscape`；保留原断言。本轮新FM页面测试的失败发生在滚动定位队列按钮，功能断言尚未执行至退出环节；用户实际设备的同版本FM流程已确认正常。

首页／FM专项 `40154504563`：28单元零失败；9UI中8项通过，包括3项改走账户菜单的原首页导航测试及5项卡片／详情／大字体测试。后续 `fb96c8fd` 补测再次28单元通过，FM测试仍因大幅惯性上滑越过菜单行而失败；iPad测试启动器在任何测试开始前退出（`Early unexpected exit / handleStalledWait`），不记为布局验收通过。`36e87c47` 改用现有快捷菜单测试的短距离双向拖动，并显式等待iPad启动；[补测运行40157080140](https://github.com/QingYaoSheep/amll-player/actions/runs/40157080140)。这两次补测与交付包的 `AMLLPlayer` 生产目录差异为零。

以下为 `b6b1ec09` 实际页面的原始模拟器截图，使用显式DEBUG示例内容，非真实账号推荐。已直接检查手机排版、卡片层次、菜单入口和大字体；不据此宣称真机性能或其他账号已验收。

- [iPhone首页海报与封面横排](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/b6-images-iPhone/AppleStyle-home-posters.png)
- [iPhone账户菜单](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/b6-images-iPhone/AppleStyle-home-account-menu.png)
- [iPhone长按操作](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/b6-images-iPhone/AppleStyle-home-context-menu.png)
- [iPhone辅助功能大字体](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/b6-images-iPhone/WWDC-home-accessibility-text.png)

完整日志 `b6-full.log`、首轮专项日志 `b6-scoped.log`、失败补测 `fb96-scoped.log`、两份原始截图/xcresult产物及直接包校验收据均保存在 `Builds/Home-FM-Completion-20261025`。

## 最终收尾核对 · 2026-10-30

取回并核对2026-10-25完成的 [36e87c47专项运行40157080140](https://github.com/QingYaoSheep/amll-player/actions/runs/40157080140)，结论为成功：

- 28项首页、FM队列／真实AVPlayer、seek测试全部通过。
- FM生产页面用例通过：从首页启动，经快捷菜单打开队列，检查随机禁用、FM歌曲及编辑入口隐藏，退出后恢复普通队列与编辑入口。
- iPad首页海报／长按／账户菜单、大字体与详情可达性2项通过。使用启动等待后没有再出现上一轮的测试启动器崩溃。
- 与首轮已通过的8项手机UI合并，计划中的本轮页面自动验证闭合；没有把专项补测描述为整个UI套件重跑。
- 最终补测提交为 `36e87c474d4a8ecc6e29e929f87d50b4b1886dff`，与交付包 `b6b1ec09` 的 `AMLLPlayer` 生产目录零差异。用户已安装并确认的直接IPA继续作为本轮交付包。
- 原始证据产物 `12585198223`（8,227,756字节），日志 `36e-scoped.log`；已下载至同一构建目录。完整回归的2项既有歌词UI失败仍保留，先前FM测试定位失败已单独补测通过；没有生成或宣称完整测试通过后的IPA。

已直接检查最终原始截图：

- [FM队列与退出入口](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/36e-images/iPhone/AppleStyle-personal-FM-queue.png)
- [退出后恢复的普通队列](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/36e-images/iPhone/AppleStyle-restored-ordinary-queue.png)
- [iPad首页](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/36e-images/iPad/AppleStyle-home-posters.png)
- [iPad大字体首页](E:/AMLL-Swift/Builds/Home-FM-Completion-20261025/36e-images/iPad/WWDC-home-accessibility-text.png)

产物ZIP的SHA-256 `fe1f1f1b7ecac9f201e335b4ef82bde4b4d489a963ecb329a646ba6d88a37d8c` 与GitHub产物摘要一致。FM／普通队列状态切换及iPad卡片文字未见明显遮挡；静态截图不能证明播放暂停或真机帧率，这些分别依据播放器测试、用户反馈和设备性能验收。

源码实现与本轮页面自动验证已完成。真实 Apple Music 私人栏目／Replay、其他未提供的实际账号权限、两台目标设备十五分钟热状态与性能，以及未执行的辅助功能／方向组合，继续保持待验收；不扩大用户此前设备反馈的覆盖范围。
