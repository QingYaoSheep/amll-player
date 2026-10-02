# 网易云无损跳转与歌词恢复：第二轮修复

## 当前状态

上一轮 1def3336／dea1ec05 的自动测试通过，但用户确认声音同步与点击弹簧均未修复；保留“设备验收失败”，不能沿用旧通过结论。

本轮已复现真实 FLAC 解码位置错误并完成精确寻址 A/B。2026-10-02，用户安装 `cf169b13` 后确认网易云无损音质下三项均恢复：点击歌词前后跳的声音落点、隐藏歌词拖动进度后重新显示的同步、点击歌词的弹簧与逐行错峰。设备验收通过；最终回归提交 `523cc2a0` 的 422 项单元／8 项 UI 测试零失败，两路 Xcode 27 IPA 均通过归档及包检查。

## 真实音频证据

48 秒测试音频每两秒切换已知频率，使用真实 AVPlayer 与 MTAudioProcessingTap 读取解码 PCM。交替音量制造不同 FLAC 帧长度；不依赖模拟播放器，也不只检查 currentTime。

- [iOS 原路径复现](https://github.com/QingYaoSheep/amll-player/actions/runs/37020761274)：目标 36.25 秒，媒体时间约 36.28 秒，但 PCM 约 1681 Hz，对应约 34 秒；目标声音应为 1760 Hz。
- [HTTP 精确寻址 A/B](https://github.com/QingYaoSheep/amll-player/actions/runs/37020912640)：同一字节范围服务器、同一 FLAC、相同前后跳序列。默认资源寻址有 1 次音频内容错位；仅设置精确时长／寻址选项后为 0 次。用户报告使用“无损”，与 FLAC 路径吻合。
- 自动测量证明固定测试资源；实际网易云无损音源的声音落点已由用户安装 `cf169b13` 复测确认。

修复在资源装载时创建带 AVURLAssetPreferPreciseDurationAndTimingKey=true 的 AVURLAsset，再构造 AVPlayerItem。零容差 seek 本身不足以修复默认估算字节位置。[Apple 选项说明](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey)、[Apple 工程师的 FLAC 寻址说明](https://developer.apple.com/forums/thread/665417)。精确寻址可能增加初次准备时间；不通过更改 offset 掩盖声音落点。

## 请求和画布

点击歌词与进度条保存不可变目标、曲目和入口。网易云请求与实际确认分离：等待时冻结最后可信时钟，10 秒超时恢复实际状态并提示重试。回调须匹配请求、媒体 item、曲目与资源代次。

确认连同对应快照直接提交，并保留在后续普通快照中；bufferingNewest 不会丢失唯一确认。旧请求、切歌、音源替换及取消回调不可确认新请求。

生产 CADisplayLink 每帧只采样一次完整播放状态。新建画布首帧使用当前确认位置；保留画布恢复重新锚定，不依赖隐藏前的累计逐字时钟。

确认后复用“返回当前歌词”操作重置跟随状态；位置保留当前呈现值，以原弹簧和逐行错峰接续。真实时间、正文／音译遮罩独立重置，提前滚动仍只用于视觉调度。

## 脱敏诊断

设置 → 帮助与故障排查 → 播放跳转诊断，可导出请求、目标、实际媒体时间、资源代次、画布代次和有限行轨迹。最多 800 条，跳转附近采样 13 秒、最高 60 Hz；不记录歌词正文、Cookie、完整媒体 URL 或账户信息。导出为临时 JSON，包含构建提交。

## 验证与交付

- 真实 iOS AVPlayer 使用生产精确寻址入口，MP3／AAC／FLAC 三种编码的四个前后跳目标均通过解码音频内容检查；7 项请求事务回归通过。
- `cf169b13` 直接 IPA 构建与包检查通过，已交付用户。完整回归的 8 项 UI 测试通过，422 项单元测试出现 9 个失败断言；失败涉及本轮测试夹具，不能标记自动验证通过：[首次完整回归](https://github.com/QingYaoSheep/amll-player/actions/runs/37025842213)。
- 回归提交 `6e2c1bc1` 修正遮罩时钟的显示行原点、离屏 Debug 额外绘制，以及没有 AVPlayerItem 的旧队列测试。浏览夹具改用与真实手势相同的分派，检查真实 CADisplayLink 轨迹和错峰；声音寻址与跳转确认逻辑未再变更。直接 IPA 已通过，422 单元测试剩余 3 个失败断言集中于两个生产页面测试，8 项 UI 通过：[第二次回归](https://github.com/QingYaoSheep/amll-player/actions/runs/37030121067)。
- 页面夹具在播放器缓冲时调用播放／暂停切换，而当时快照表示尚未播放，切换实际上重新发出播放；不能据此要求时间固定。`523cc2a0` 改为明确暂停，并等待真实媒体和模型时钟一致后再执行跳转断言。最终 [Xcode 27 两路 CI](https://github.com/QingYaoSheep/amll-player/actions/runs/37033641013) 全部成功：422 单元／8 UI 零失败，iPad／iOS 27 SDK 构建、设备归档和包检查通过。生产页面的 49 个 CADisplayLink 帧从浏览位置 369.5pt 连续恢复至 257.5pt，逐行错峰断言通过；隐藏后新建画布的确认时间与遮罩回归通过。
- 同一提交 `523cc2a014f2bb0e88e18bf6f580c98efbcfbc43` 的直接版及测试后版 IPA 分别保存至 `E:/AMLL-Swift/Builds/LyricsSeekV2/523cc2a0-direct` 和 `523cc2a0-tested`，可重新签名后安装。两份包的嵌入提交一致且不包含测试音频；SHA-256 分别为 `47740ce92b19e409937a122a949044b73c2002ad1f694d331cdd816b5d11ad76`、`daa80aff7274efb780e53fcd93c96d8ac4f41f2278e0a89aa028457e103c1f47`。
- 用户设备反馈：“全都没有问题了，你的修复圆满完成。”对应本次三项设备验收已通过，不覆盖未报告的弱网、其他编码、设备 HDR 亮度或长期性能测量。
- 本地证据、包哈希和设备反馈保存在 `E:/AMLL-Swift/Builds/LyricsSeekV2/evidence.json`。诊断不记录带签名 URL、Cookie 或歌词全文。
- 最终 `523cc2a0` 的 9 张固定歌词、封面和横屏图像与 `d4fa087c` 基线逐字节一致；工作区原有 13 处回放修改完整保留。
