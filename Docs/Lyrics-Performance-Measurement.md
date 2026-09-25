# 原生歌词画布性能测量

Debug → 歌词渲染预览 → 开启“AMLL source port · validation”，选择 60／120 Hz，开启“记录原生帧耗时”。使用同一共享歌词、配置、设备方向与封面，分别录制快速往返浏览、自动换句、密集逐字、长音、多声部及独立音译。导出两次 `amll-frame-performance.json` 后运行：

```text
node Scripts/compare-amll-performance.cjs before.json after.json
```

报告先检查来源 ID、歌词文档 SHA-256、视口、显示缩放、完整配置与目标刷新率，再给出 CPU P95、长帧数和缓存峰值。导出同时包含逐帧 CPU、引擎、排版、栅格、图层、drawable 等待、GPU 提交及已完成 GPU 命令时间。GPU 回调可能晚于发起帧，数值适合定位瓶颈，不是同步的一帧端到端 GPU 时间。缓存字节数只覆盖画布管理的图像、Metal 字形纹理与 drawable 估算；系统及 Core Image 内部缓存不在其中。首次构建时的排版时间计入下一次采样。

当前 Windows 环境没有 Swift、Xcode 或 Apple 设备；尚无同设备优化前后轨迹。因此 P95 下降 30%、120 Hz 主线程 P95 ≤4 ms、60 Hz ≤8 ms、15 分钟丢帧 <1% 均保持**待测量**。两路 IPA 也须待 GitHub 推送凭据恢复后由 Xcode 27 工作流产生，不以 Node 结果代替。
