# 剩余视觉能力实施台账

## 当前 CI 门槛（2026-09-18 用户更新）

后续统一使用 Xcode 27 / iOS 27 SDK 执行构建、单元/UI 测试、iPad 构建、archive 和 IPA 检查，不再运行 Xcode 26 测试。下文的 Xcode 26 结果仅为历史证据，不是新增任务要求。工作流保留 iPhone 16 Pro 与 13 英寸 iPad Pro 参考型号，并显式创建 iOS 27 模拟器。

已复核 `ed82076e`：182 个单元测试全部通过（含 HDR GPU 读回与辅助文字），5 个 UI 测试中 1 个因两个“显示歌词”按钮同名导致选择歧义而失败。`c320883f` 为菜单动作增加独立标识；新的 Xcode 27 全套测试仍需运行确认。

## 2026-09-18 方形动态封面接线（待 Xcode 27 验证）

- 真实页面复用 Apple 目录查询；非 Apple 歌词来源只单独查询封面候选，不修改歌词来源或人工匹配。方形模式不裁切竖形视频冒充方形资源。
- 新配置默认关闭，开启后默认仅 Wi-Fi，蜂窝单独授权；网络策略变化、切歌和退出页面取消旧任务，迟到结果由请求代次拦截。离线、减少动态效果、无匹配或下载失败保留静态封面。
- 通过公开 AVAssetDownloadURLSession 下载 HLS，渐进视频通过 URLSession 下载；AVQueuePlayer 只接收完成缓存的本地 URL，始终静音，不配置音频会话、不发布音乐播放状态。首次视频帧就绪前保留静态图。
- 独立 200 MB 缓存按最近访问淘汰；HLS 包保留系统位置，索引记录沙盒相对路径。新增清理入口、超限拒收、缓存恢复、静态回退与切歌迟到回归测试。
- 竖形/沉浸反射仍未完成；HLS 真机下载、蜂窝切换、视频与 Spotify 同时运行、缓存性能仍待验证。不能以此把 P4 或全部移植标记完成。

2026-09-12，起始基线 `707e8f1a`。以用户批准的《AMLL 剩余视觉能力移植与验收计划》为本轮规范。保留 Apple Music 页面构图、28% 默认定位、浏览无模糊与短惯性、下一句恢复跟随；不增加音乐播放后端。

| 阶段 | 当前证据 | 尚未完成 |
|---|---|---|
| P0 | 已读取基线 CI 34698219471：Xcode 27 build/archive/IPA 成功；Xcode 26 无指定模拟器，测试未启动。新增显式创建 iOS 26 iPhone 16 Pro / iPad Pro 13-inch (M4) 脚本及两项通过的 Node 回归 | 新 CI、完整资源锁定、同输入冻结回放与叠片 |
| P1 信息文字 | 真实页面标题、艺人、专辑已接入 SwiftUI SDR Plus Lighter；减少透明度使用 normal，仅修改文字 | 实际背景合成真机验证、署名与辅助文字合成 |
| P1 HDR | 已有范围模型、浮点 Metal 着色器/渲染器和 Debug Core Text 字形验证入口；验证入口采集屏幕余量、替换式计算 SDR/HDR 区域并接入 Plus Lighter；新增 GPU 像素读回测试 | **仅 Debug 接线，生产未接入**：实际帧变换、长音发光、淡出/模糊一致性、生产设置及能力提示、持续显示余量变化、真机验证；GPU 测试尚待 CI |
| P2 | 分段 ruby 已接入 UTF-16/运行段映射与独立遮罩；逐词罗马音接入词下方排版，歧义/超宽回退行级并导出诊断；修复逐行注音留白 | 编译及新增测试待 CI；跨行 ruby 完整排布、原版辅助文字混色/强调、完整断行/复杂文字视觉对照 |
| P3 | 现有 Mesh 路径 | 完整 Mesh/Pixi 源码对照、模式/种子/上下文管理与背景验收 |
| P4 | 静态封面；统一页面标题/艺人/专辑已接入原版有限往返跑马灯，设置可控制；菜单展示数据中真实署名 | 跑马灯真机验证；动态资源查询、方/竖选择、无声视频、默认关闭与 Wi-Fi 策略、200MB LRU、取消请求、原版署名位置及混色 |
| 综合签收 | 无本轮真机报告 | 全部 CI、15 分钟稳定性、60/120Hz、目标设备 HDR/视觉及辅助功能签收 |

HDR 实施语义固定为：每个真实活动句的已填充区域持续高光，直到该句结束；不是仅正在发声的词。逐行歌词激活整行，不制造逐词时间。歌词之外的信息文字保持 SDR；HDR 目标为线性白 1.5 倍并受实时余量限制。关闭 HDR 不关闭 Plus Lighter。普通长音 shadow 不算 HDR。

公开 API 依据：[SwiftUI BlendMode](https://developer.apple.com/documentation/swiftui/blendmode)、[Metal EDR 与浮点输出](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping)。使用浮点格式本身不代表已完成 HDR，必须验证实际显示输出。

所有阶段保持未勾选；不得用模型测试或 SDR 截图替代 Metal 接线与真机签收。

## 2026-09-13 真实页面跑马灯

- `react-full/src/components/TextMarquee/index.tsx` → `AMLLMarqueeMotion` / `AMLLMetadataText`：保留 95% 宽度阈值、32pt/s、一次往返，静止右侧/运行双侧淡出。没有沿用旧近似无限循环。
- 紧凑与展开页面的标题、艺人、专辑统一接线并保留原字号及 SDR Plus Lighter；字号遵循 Dynamic Type/Bold Text。跑马灯设置在 AMLL 页面也可操作。
- 鼠标进入/离开对应原版事件；点击触发/停止为触屏主动适配。减少动态效果、关闭设置、切歌/文字变化、离屏与后台会清除动画；完整文本由 VoiceOver 读取。
- 数据中的真实歌词作者/歌曲作者可在菜单查看，不生成虚假署名。菜单并非原版署名位置，不计为完整署名视觉移植。
- 新增轨迹数值与实际 UILabel/CAAnimation 接线测试，尚待 CI；生产 HDR、背景及动态封面仍未完成。

### 动态封面目录发现基础

已按本地插件 0.29.21 实现 `歌曲 include=albums → 专辑 extend=editorialVideo&platform=web`，解析 `motionDetailSquare` / `motionDetailTall` 的字符串、url、href、video 包装。资源结果保留专辑和 storefront；请求取消在跨请求边界检查。缺少专辑关联返回无资源，损坏专辑响应报告错误。

这只是可测试的目录发现方法，尚无页面调用、匹配调度、无声视频、Wi-Fi 策略或媒体缓存。不得把资源 URL 查询当成 P4 完成。新增 URL 形态和请求合约测试；来源 SHA-256 见 `ReferenceCaptures/remaining-visual-source-hashes.json`。

## 2026-09-13 HDR 浮点绘制验证入口

- 新增 `LyricsHDR.metal` 与 `LyricsHDRRenderer`：RGBA16Float、extendedLinearSRGB、透明 CAMetalLayer。着色器按原字形 alpha 和羽化覆盖计算 SDR/HDR 替换值，不重复叠加普通白字。
- Debug 歌词预览增加可折叠 HDR 字形验证区，使用真实 Core Text 栅格及 AMLLWordMask，拖动 0–5 秒验证已填充/未填充/失活状态。每次绘制查询窗口屏幕 current/potential EDR headroom，目标不超过 1.5；HDR 关闭仍保留 SDR Plus Lighter，减少透明度采用普通混色。
- 新增 GPU 浮点像素读回测试：已填充 1.5、未填充 0.3、无字形区域透明；另测图层色彩空间/格式/尺寸。尚未在 Windows 执行这些 Apple GPU 测试。
- 此入口不是生产歌词引擎。生产动画、blur、shadow、转场和 EDR 合成仍需统一接线及验证；不开放生产 HDR 开关，不标记 P1 完成。

## 2026-09-13 辅助文字接线

- `AMLLCoreTextLayout.RubyFragment` 保留词/分段索引、UTF-16 范围、视觉运行方向及原时间。渲染器复用缓存注音栅格，按分段时间更新遮罩，不生成注音时间。
- 每个换行正文均预留注音高度。跨行词目前仍将 ruby 放在首个视觉行上；不计为完整跨行 ruby 移植。
- 有明确对应且宽度可容纳的逐词罗马音放在词下方。过宽或分词复制造成对应歧义时保持行级文本，Debug 轨迹 schema 2 导出逐行 diagnostics。服务端独立行级罗马音继续保留。
- 新增分段时间/范围、换行留白、罗马音开关及回退测试。Windows 仅执行格式和 diff 检查，Swift 测试与视觉效果待 CI/真机。
- HDR Metal、辅助文字 Plus Lighter、完整 Mesh/Pixi、动态封面与综合验收仍未完成；本轮未开放这些未完成能力的开关。

## 2026-09-13 基线复核

`0f173e32` 的 CI 34699214261：Xcode 27 build/archive/IPA 通过；模拟器创建成功，Xcode 26 执行 176 个单元测试（3 失败）及 5 个 UI 测试（2 失败）。新 HDR 模型测试通过。浏览恢复真实边界的产品错误已修复；字号与文本保留测试已按来源及主动差异修正。UI 测试更新到当前画布，并为初始入口缺失收集诊断；等待新运行确认，不能宣称已修复全部 UI 问题。

原 CI visual-review artifact `10299841954` 的界面树确认音乐信息按钮存在，但 identifier 为 `miniPlayerBar`，其容器标识覆盖了 `openNowPlaying`。已在系统底栏容器增加 `.accessibilityElement(children: .contain)`，与旧迷你栏保持一致；不是通过绕开入口让测试通过。待新 CI 确认。
