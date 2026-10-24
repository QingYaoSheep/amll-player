# 歌词动画风格

## 用户行为

“歌词外观 → 动画 → 精细动画调整 → 逐字动画风格”提供 AMLL 和 Apple Music 16.4。
默认 AMLL。两种风格分别保存弹簧、缩放、非当前行模糊、逐字强调、隐藏已播放行、
跑马灯、逐字渐变宽度与提前滚动。首次切换复制当前选项，此后独立保存；重置仅影响
当前风格的动画选项。字体、对齐、真实时间、偏移、音译、背景与 HDR 共用。

Apple Music 16.4 是用户指定的风格名称。本实现依据用户提供的 LyricsBlossom Windows
产物做有限适配，并非 Apple 官方源码或 Apple Music 16.4 的完整复刻。

## 本次重新核实的证据

目标：`D:/LyricsBlossom-windows/LyricsBlossom.exe`，57,901,568 bytes。
SHA-256：`d64d2b413c1abbc0b4ea57d4530e31e344ecb0b172b79fb8604d70c2185f98ed`。
使用已有 Ghidra 12.2 工程 `D:/Ghidra/lbproj/LB`，以 `-readOnly -noanalysis` 读取。
工具输出属于本地 Ghidra/PE 检查，不是 REA MCP Evidence。

仅凭旧聊天结论和 SwiftUI 重建文件不能判定调用用途。本次通过 std::function 的
`target_type` 返回函数、RTTI 名称、回调表和构造函数追踪发现：

| 参数或路径 | 原始位置与验证 | 采用结果 |
|---|---|---|
| `(0.23,1,0.32,1)` | `FUN_14039dec0` 的 double 常量可直接还原 | 曲线存在，但不能证明用于歌词；不应用到歌词 |
| 160ms、目标 `(1,1)` | `FUN_1403a03c0` → `FUN_140158f90`；getter `1403a03b0` 返回 `PrivacyActionButtonLayer::<lambda_4>` | **隐私按钮回弹**，排除 |
| 100ms、目标 `(.97,.97)` | `FUN_1403a04a0`；getter `1403a0490` 返回 `PrivacyActionButtonLayer::<lambda_3>` | **隐私按钮按压**，排除 |
| 上述参数的 from/to | `FUN_140158f90` 保存当前值为起点、参数为目标；目标写入 `+0x50` | 旧聊天的 `from=` 标注错误 |
| 歌词逐行状态 | `FUN_1401e6460` 调用 `FUN_1403014c0`；渲染 `FUN_1403165c0` 由 `LyricsRenderer::renderLine` 的三组 lambda RTTI 锚定 | 确认属于真正歌词路径 |
| 行位置／缩放固定弹簧 | `FUN_140303510` 固定参数分支分别写 `LineRenderState +0x1f8/+0x370`：`+0x18=1`、`+0x20=100`、`+0x28=18` | 新风格采用质量 1、刚度 100、阻尼 18 |
| 参数含义及求解方式 | `FUN_140156380` 使用 `sqrt(k*m)`、`sqrt(4*m*k-c*c)` 与解析阻尼方程；`FUN_1403014c0` 将两组输出写入行 Y／scale | 确认是弹簧；“歌词路径没有弹簧”的旧结论不成立 |
| 逐字浮动、强调、背景声部专属参数、亮度、模糊 | 现有材料尚不足以建立完整参数和事件映射 | 沿用 AMLL，未用推测值补齐 |
| 通用 300ms、示例 1.055 放大／26pt 光晕／0.62s 长音阈值、全页 bloom | 尚未证明属于目标歌词动效，或重建文件明确标为设计选择 | 不采用 |

新风格选择的是上述**固定参数分支**；未完整移植源程序按多种条件自适应求参的分支。
保留当前焦点交接、逐行错峰、浏览直接跟手、seek 确认及真实逐字时钟。
这张表界定当前实现覆盖，不能将“适配两项参数策略”描述为整套歌词动效已完整复刻。

原始只读分析输出、脚本和哈希清单保存在
`E:/AMLL-Swift/Builds/Lyric-Animation-Styles-20261024/`；不打包或提交第三方程序。

## 工程接口

- `LyricsAnimationStyle`：可持久化风格标识，未知字符串回退 AMLL。
- `LyricsAnimationProfiles`／`LyricsAnimationOptions`：独立的选项快照；现有扁平字段仍是当前活动值，兼容所有既有设置入口。
- `LyricsAnimationMotion`：集中解析已核实的运动参数，未适配项目复用现有引擎。
- `AMLLRenderEnvironment.animationStyle`：可选回放字段，旧数据缺失时仍为 AMLL。

切换仅重新配置现有引擎参数；保留呈现位置、速度、调度截止时间、焦点状态及逐字时钟。
不改变布局缓存键、不创建新播放器或显示时钟。画布视觉缓存仍通过完整 configuration
比较失效，动态封面及 Plus Lighter 合成路径不变，HDR 上限仍为 1.2。

## 验证与交付状态

覆盖旧配置／未知风格、首次复制、独立保存和局部重置；显式 AMLL 与旧输入轨迹对照；
固定弹簧的独立解析采样、60/120Hz 和不规则间隔；零时间风格切换不重置歌词时钟及呈现值。
UI 测试从真实快捷菜单进入设置，切换、分别修改选项并重启恢复。

Windows 无 Xcode；Apple 编译、单元/UI 测试结果以对应 GitHub Actions 提交为准。
普通／沉浸歌词、三来源真实账号、Plus Lighter/HDR 视觉以及设备流畅度仍需真机验收。
此前 `78c69185` 的完整 CI：523 个单元测试通过；4 个 UI 测试失败（首页旧设置入口 3 个、
既有沉浸歌词上隐几何 1 个）。本次不放宽这些断言，也不把它们记为本次通过。
