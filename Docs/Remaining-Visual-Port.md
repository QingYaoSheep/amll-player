# 剩余视觉能力实施台账

2026-09-12，起始基线 `707e8f1a`。以用户批准的《AMLL 剩余视觉能力移植与验收计划》为本轮规范。保留 Apple Music 页面构图、28% 默认定位、浏览无模糊与短惯性、下一句恢复跟随；不增加音乐播放后端。

| 阶段 | 当前证据 | 尚未完成 |
|---|---|---|
| P0 | 已读取基线 CI 34698219471：Xcode 27 build/archive/IPA 成功；Xcode 26 无指定模拟器，测试未启动。新增显式创建 iOS 26 iPhone 16 Pro / iPad Pro 13-inch (M4) 脚本及两项通过的 Node 回归 | 新 CI、完整资源锁定、同输入冻结回放与叠片 |
| P1 信息文字 | 真实页面标题、艺人、专辑已接入 SwiftUI SDR Plus Lighter；减少透明度使用 normal，仅修改文字 | 实际背景合成真机验证、署名与辅助文字合成 |
| P1 HDR | 新增配置、能力限制、活动句及原遮罩空间覆盖模型和 Swift 测试；配置可选字段兼容旧存储，默认不启用 | **仅模型，未绘制**：浮点 Metal 图层、实时余量采集、SDR 扣除、逐帧变换/淡出一致性、开关和能力提示、HDR 真机验证 |
| P2 | 现有 Core Text 与 ruby 数据保留 | timed ruby、逐词罗马音绘制、完整断行/复杂文字对照 |
| P3 | 现有 Mesh 路径 | 完整 Mesh/Pixi 源码对照、模式/种子/上下文管理与背景验收 |
| P4 | 现有静态封面 | 动态资源查询、方/竖选择、无声视频、默认关闭与 Wi-Fi 策略、200MB LRU、取消请求、统一跑马灯与署名 |
| 综合签收 | 无本轮真机报告 | 全部 CI、15 分钟稳定性、60/120Hz、目标设备 HDR/视觉及辅助功能签收 |

HDR 实施语义固定为：每个真实活动句的已填充区域持续高光，直到该句结束；不是仅正在发声的词。逐行歌词激活整行，不制造逐词时间。歌词之外的信息文字保持 SDR；HDR 目标为线性白 1.5 倍并受实时余量限制。关闭 HDR 不关闭 Plus Lighter。普通长音 shadow 不算 HDR。

公开 API 依据：[SwiftUI BlendMode](https://developer.apple.com/documentation/swiftui/blendmode)、[Metal EDR 与浮点输出](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping)。使用浮点格式本身不代表已完成 HDR，必须验证实际显示输出。

所有阶段保持未勾选；不得用模型测试或 SDR 截图替代 Metal 接线与真机签收。
