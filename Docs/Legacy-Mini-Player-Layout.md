# 旧系统迷你播放器与标签栏布局

## 修正范围（2026-10-02）

用户在 iOS 18 报告起播后音乐信息栏遮挡首页、音乐库与搜索。原实现把回退 MiniPlayerBar 的底部 safeAreaInset 加在整个 TabView 外；修正将占位移到各标签页 NavigationStack 的底部安全区，让系统标签栏独立布局，不硬编码其高度。

iOS 26.1 及之后继续使用 tabViewBottomAccessory，现代路径不增加回退占位。iOS 18 至 26.0 沿用原迷你播放器样式与控制。无歌曲或未连接时不显示；全屏歌词、播放控制与转场入口保持现有实现。

## 回归与结果

LegacyMiniPlayerUITests 使用现有歌词/播放夹具，检查播放器底边位于标签栏顶边之上、三个标签无交叠且可点击，并检查歌词打开及关闭后的布局。Debug 可强制旧布局分支，Release 不包含该强制入口。

[修正布局回归 36979519355](https://github.com/QingYaoSheep/amll-player/actions/runs/36979519355) 已通过：1 项真实 UI 测试零失败，检查几何、标签点击与歌词打开/关闭。[原版布局回归 36978928745](https://github.com/QingYaoSheep/amll-player/actions/runs/36978928745) 真实失败：播放器底边 836pt、标签栏顶边 791pt，超出允许边界 44pt。只移动底部占位容器后，同一条回归通过；没有通过改高度或禁用控件绕过。

构建机无法下载 iOS 18.0／18.5 模拟器；上述回归实际运行于 iOS 27.0、iPhone 16 Pro 模拟器，强制旧布局路径。该结果不等同于 iOS 18 设备验收。

生产提交 bc4c2acf 的直接归档与 IPA 包检查已通过。用户已安装该修复包，确认“已正常，未再遮挡”，iOS 18 的播放器位置与三个标签点击得到设备复测。设备型号与具体 18.x 版本未记录；该反馈不扩大为所有设备/尺寸验收。[Xcode 27 两路构建 36980653151](https://github.com/QingYaoSheep/amll-player/actions/runs/36980653151) 全部通过：404 项单元／8 项 UI 测试零失败，iPad／SDK 构建、设备归档及 IPA 包检查通过。两份 IPA 均来自 bc4c2acf86593e9b20ece99841618b31ad6d7d9f，已下载至 E:/AMLL-Swift/Builds/LegacyMiniPlayer。

直接包 SHA-256：93b6c81882680ab1ea12e9188bcdc073f77208f9f13eb80800c1d71230f556a0。测试后包 SHA-256：aacdd14ca7c279a55dca8029f2a41b7ef82241f1afaa31845e34cba086eb2280。manifest.json 保存产物和设备反馈；原版／修正 xcresult、截图及日志保存于同目录。
