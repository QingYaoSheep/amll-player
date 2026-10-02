# 网易云起播后闪退修复

## 故障与证据（2026-10-02）

用户反馈：网易云模式下每首歌曲出声几秒后退出。当前源码在 MainActor 内创建 MPMediaItemArtwork 的同步图片提供闭包，MediaPlayer 可在其他线程请求图片。Swift 6 为该闭包插入执行器检查，使锁屏封面请求触发 SIGTRAP。

将原闭包不改变行为地提取为生产工厂，使用本地生成的 UIImage 在后台调用实际 MediaPlayer image(at:)。原版完整应用回归 [36974219797](https://github.com/QingYaoSheep/amll-player/actions/runs/36974219797) 退出，崩溃报告为 EXC_BREAKPOINT / SIGTRAP，故障线程依次包含：

1. _dispatch_assert_queue_fail
2. _swift_task_checkIsolatedSwift
3. closure #1 in static NetEaseNowPlayingArtwork.make(_:)
4. NetEasePlaybackCallbackTests 的后台图片请求

不访问网易云、不使用账号、不播放音源的 [最小复现](https://github.com/QingYaoSheep/amll-player/actions/runs/36974880255) 同样退出。只将工厂改为 nonisolated、保持图片与请求不变后，[同一最小复现](https://github.com/QingYaoSheep/amll-player/actions/runs/36975430412) 已通过。完整应用修复后回归和两路交付另行记录。

## 改动

- 图片提供闭包在显式 nonisolated 工厂中创建，持有同一不可变 UIImage；保留封面、锁屏信息和图片质量。
- 网易云播放器状态 KVO 与锁屏命令入口显式使用 Sendable 回调，防止同类入口继承 MainActor；状态、队列及 seek 仍通过 MainActor Task 执行。没有关闭 Swift 并发检查。
- 新增真实 MediaPlayer 后台封面请求回归，运行于现有 Xcode27 测试路由。保留原登录、播放、歌词、音译及封面配置。

## 验证与边界

原版后台封面回调已在 iOS27 模拟器的完整 AMLL 应用内复现进程退出，不是网络错误或图片测试断言。修复后的相同离线最小复现已通过。GitHub Actions 两路仍按原规则产出直接 IPA 和测试通过后 IPA。

未收到本次用户设备的原始 ips；用户设备上持续播放、切歌、前后台及锁屏控制的同症消除仍须安装修复包复核。模拟器结果不等同于账号权限或设备后台音频验收。

原始日志、完整 xcresult 和崩溃报告保存在 E:/AMLL-Swift/Builds/NetEasePlaybackCrash。独立诊断分支 codex/netease-playback-crash-repro 不改动生产工作流。保留工作区已有歌词与回放修改。
