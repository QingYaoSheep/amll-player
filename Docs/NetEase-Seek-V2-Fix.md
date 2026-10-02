# 网易云无损跳转与歌词恢复：第二轮修复

## 当前状态

上一轮 1def3336／dea1ec05 的自动测试通过，但用户确认声音同步与点击弹簧均未修复；保留“设备验收失败”，不能沿用旧通过结论。

本轮已复现真实 FLAC 解码位置错误并完成精确寻址 A/B。生产页面、完整自动回归及实际网易云设备结果分别记录，未执行项目不标记解决。

## 真实音频证据

48 秒测试音频每两秒切换已知频率，使用真实 AVPlayer 与 MTAudioProcessingTap 读取解码 PCM。交替音量制造不同 FLAC 帧长度；不依赖模拟播放器，也不只检查 currentTime。

- [iOS 原路径复现](https://github.com/QingYaoSheep/amll-player/actions/runs/37020761274)：目标 36.25 秒，媒体时间约 36.28 秒，但 PCM 约 1681 Hz，对应约 34 秒；目标声音应为 1760 Hz。
- [HTTP 精确寻址 A/B](https://github.com/QingYaoSheep/amll-player/actions/runs/37020912640)：同一字节范围服务器、同一 FLAC、相同前后跳序列。默认资源寻址有 1 次音频内容错位；仅设置精确时长／寻址选项后为 0 次。用户报告使用“无损”，与 FLAC 路径吻合。
- 自动测量只能证明固定测试资源，实际网易云账号音源仍需安装复测。

修复在资源装载时创建带 AVURLAssetPreferPreciseDurationAndTimingKey=true 的 AVURLAsset，再构造 AVPlayerItem。零容差 seek 本身不足以修复默认估算字节位置。[Apple 选项说明](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey)、[Apple 工程师的 FLAC 寻址说明](https://developer.apple.com/forums/thread/665417)。精确寻址可能增加初次准备时间；不通过更改 offset 掩盖声音落点。

## 请求和画布

点击歌词与进度条保存不可变目标、曲目和入口。网易云请求与实际确认分离：等待时冻结最后可信时钟，10 秒超时恢复实际状态并提示重试。回调须匹配请求、媒体 item、曲目与资源代次。

确认连同对应快照直接提交，并保留在后续普通快照中；bufferingNewest 不会丢失唯一确认。旧请求、切歌、音源替换及取消回调不可确认新请求。

生产 CADisplayLink 每帧只采样一次完整播放状态。新建画布首帧使用当前确认位置；保留画布恢复重新锚定，不依赖隐藏前的累计逐字时钟。

确认后复用“返回当前歌词”操作重置跟随状态；位置保留当前呈现值，以原弹簧和逐行错峰接续。真实时间、正文／音译遮罩独立重置，提前滚动仍只用于视觉调度。

## 脱敏诊断

设置 → 帮助与故障排查 → 播放跳转诊断，可导出请求、目标、实际媒体时间、资源代次、画布代次和有限行轨迹。最多 800 条，跳转附近采样 13 秒、最高 60 Hz；不记录歌词正文、Cookie、完整媒体 URL 或账户信息。导出为临时 JSON，包含构建提交。

## 待验证

- 生产页面点击／隐藏恢复及弹簧轨迹；
- 当前提交完整单元/UI 回归与两路 IPA 包检查；
- 真机网易云无损前后 seek、真实声音片段、隐藏进度条、暂停及弱网；
- 设备确认声音落点、重新显示同步、点击动画三项后，才能全部标记解决。
