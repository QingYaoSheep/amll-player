# 沉浸模糊提交延迟

用户在确认顶部羽化消除白线后，仍报告模糊下层内容有延迟。顶部羽化与该性能问题分别验收；不改已经确认的羽化、倒影映射、视频显示、层序或背景自身模糊。

## 复现入口

沿用已有真实窗口和 `ImmersiveLiveBlurSurface.capture` → 实际 Metal drawable 测试接口，增加 `testEncodedBlurDoesNotWaitForTheMainActorToSubmit`。暖机后采样绿色输入，在提交前安排 300ms 主线程工作；断言已编码 GPU 帧无需等待这段主线程工作，且真实 drawable 读回为绿色。在途上限仍为两个。

生产诊断新增独立“提交等待 P95”：从后台编码完成至实际 command.commit 的等待，样本至多 120 条。原有采样、GPU、帧龄指标保留；不得把这个指标当作实际视频帧龄或完整设备帧率。

Windows 无 Apple Metal 运行时，此回归须在固定测试提交的 Xcode 27 运行中取得失败结果，之后才能确认该调度链路对故障的贡献。当前仅添加测量和回归，不先改 GPU 提交行为。设备诊断待用户补充；尚未宣称延迟解决。
