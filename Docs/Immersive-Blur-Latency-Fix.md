# 沉浸模糊提交延迟

用户在确认顶部羽化消除白线后，仍报告模糊下层内容有延迟。顶部羽化与该性能问题分别验收；不改已经确认的羽化、倒影映射、视频显示、层序或背景自身模糊。

## 复现入口

沿用已有真实窗口和 `ImmersiveLiveBlurSurface.capture` → 实际 Metal drawable 测试接口，增加 `testEncodedBlurDoesNotWaitForTheMainActorToSubmit`。暖机后采样绿色输入，在提交前安排 300ms 主线程工作；断言已编码 GPU 帧无需等待这段主线程工作，且真实 drawable 读回为绿色。在途上限仍为两个。

生产诊断新增独立“提交等待 P95”：从后台编码完成至实际 command.commit 的等待，样本至多 120 条。原有采样、GPU、帧龄指标保留；不得把这个指标当作实际视频帧龄或完整设备帧率。

Windows 无 Apple Metal 运行时，复现通过已有 Xcode 27 CI 执行。固定测试提交 `680339e7d95ebc13cc43b5c3ae2f0b034614adc2` 的 [运行](https://github.com/QingYaoSheep/amll-player/actions/runs/37292852771) 已完成：473 项单元中仅新增用例失败，8 项 UI 零失败。真实后台编码完成后至提交的等待为 **298.5177ms**，超过 200ms 门槛；实际绿色 drawable 和两任务上限断言通过。这证明现有提交路径把主线程工作加入画面延迟，尚不证明它是用户设备唯一瓶颈。用例本身耗时 0.978 秒；完整 CI 的编译及 Xcode 清理耗时另外记录。

复现命令是现有工作流的 `xcodebuild test -project AMLLPlayer.xcodeproj -scheme AMLLPlayer -destination "platform=iOS Simulator,id=$CI_IPHONE_UDID" -resultBundlePath build/Xcode27-tests.xcresult CODE_SIGNING_ALLOWED=NO`。目标用例为 `ImmersiveArtworkMediaTests.testEncodedBlurDoesNotWaitForTheMainActorToSubmit`；失败输出为 `298.51770833329283 is not less than 200.0`，其他用例不改门槛。

## 按证据验证的因素

1. 已编码输出等主线程：取消编码后的主线程提交跳转，应使同一压力场景的提交等待显著下降。
2. 模糊滤镜本身耗时：如果第一项修正后 GPU P95 仍高，则该耗时仍会造成延迟，须另做滤镜测量，不能以调小半径达标。
3. 视频采样滞后：若提交和 GPU 耗时低但视频运动仍错位，须比较媒体帧时间与呈现时间；现有帧龄只表示捕获到输出，不冒充解码帧龄。

## 窄范围修复

Metal 编码及 command.commit 均在原串行渲染队列执行，主线程只接收计数、首帧可见状态和测试主动要求的读回。用一个互斥的提交登记隔离代次：配置、资源、离屏及后台失效后，旧编码不能提交；后台通知仍等待已经提交的工作被调度。完成回调清理登记，即使原视图已销毁也释放占用。保留现有两个在途槽位、显示调度、滤镜、缩放、颜色和帧输入。

模拟器的完成时间在 GPU 回调中采样，不再把等待主线程更新诊断的时间误算为 GPU 完成时间。设备仍使用 drawable 的真实呈现时间。停止时在同一串行队列清理 CI 缓存，避免与正在编码的 CIContext 并发操作。没有新增播放器或逐帧 CPU 大图回传。

审查补充：配置失效只改变接受代次，已提交命令保留至完成清理，避免后续后台通知漏掉尚未调度的工作。新增真实窗口回归：提交后在主线程繁忙期间调整配置，再进入后台；必须执行已有命令的调度屏障、隐藏旧画面，恢复后实际 drawable 必须显示新输入，且在途不超过两个。

`d94370f1ebb7f6cdde578ae47d58b254180b8455` 的 [两路 Xcode 27 CI](https://github.com/QingYaoSheep/amll-player/actions/runs/37296907759) 全部通过：474 项单元、8 项 UI 零失败，iPad／SDK 构建、归档与包检查成功。相同 300ms 主线程压力下，实际提交等待由 298.5177ms 降为 **0.0151ms**，真实绿色 drawable 与两个槽位验证通过。这是该压力场景的编码到提交等待，不代表整幅画面的设备端帧龄。

两份 IPA 内嵌完整提交均已核对；直接 SHA-256 `c53f98f260052291376bcb3e1db4e273c6e56a7342960e18984ff5c59ab00750`，测试版哈希与完整清单位于 `E:/AMLL-Swift/Builds/Artwork-Blur-Latency-20261005/verification.json`。两轮审查均通过，原有 13 项工作区文件按哈希核对未改动。

后续用户提供 iPhone 16 Pro、Mesh 背景诊断：33.3 FPS、采样 P95 20.87ms、GPU P95 7.16ms、提交等待 P95 0.11ms、帧龄 P95 44.80ms、在途 -1/2。提交等待已不占主要时间，但截图采样与计数异常仍需单独优化，不宣称消除所有感知延迟或设备发热。顶部羽化、倒影、沉浸显示及隐藏歌词音量条的已完成状态保留。
