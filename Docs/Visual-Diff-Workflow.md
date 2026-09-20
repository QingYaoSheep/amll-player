# 同输入截图叠片

运行 `node Scripts/build-amll-browser-reference.cjs E:/AMLL-Swift/AMLL-OLD`，随后运行 `node Scripts/serve-amll-browser-reference.cjs`。打开 `http://127.0.0.1:4178/visual-diff.html`。

选择原版和原生的 PNG、各自对应的 JSON。PNG 必须为内容区域原尺寸，不能预先位移或缩放来修正差异。两端应在同一 Apple 系统使用同一字体与播放帧采集。Windows 输出仅用于工具与算法验证。

JSON 必填：`lyricSHA256`、`artworkSHA256`、`scenarioSHA256`、`configurationSHA256`（均为实际输入文件的 64 位小写 SHA-256），`width`、`height`（物理像素），`displayScale`、`frame`（从零计数），`font`（实际解析的字体名称与字重），`coordinateSpace`（固定为 `content-physical-pixels`）。无封面时两端使用无封面状态及空文件哈希。配置文件必须包含完整视觉设置。

工具拒绝元数据不同或图片尺寸不符的输入，输出 50% 叠片、绝对像素差图及报告。RGB 与 alpha 均参与差异统计，alpha 差异在差图中可见。网页缩略显示不改变计算像素。

通道误差不是几何误差、DeltaE2000 或 HDR 亮度。工具不会自动签收视觉门槛；HDR 显示、背景色差、轨迹和辅助功能需要独立证据。
