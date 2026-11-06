# 设备与同类方案调研

核对日期：2026-11-06。只使用厂商文档和本机 Garmin 官方设备配置；下文「采用方式」是本项目的设计判断，不代表厂商承诺第三方应用能复制原生功能。

## FR255 可确认的约束

- [Garmin 设备参考](https://developer.garmin.com/connect-iq/device-reference/)：FR255 为 260×260、64 色、无触屏；FR255S 为 218×218，不能只改产品 ID 就认为适配完成。
- [Garmin 兼容设备](https://developer.garmin.com/connect-iq/compatible-devices/)列出的当前 API level 是 5.2；安装时仍需确认用户固件。
- 本机官方 `Devices/fr255/compiler.json`：`watchApp.memoryLimit=524288`，`datafield.memoryLimit=262144`，`background.memoryLimit=65536`。设备配置版本 `3d0fb192a2cf01699aefd0f384af3f527e5885bd`；不是推测硬件总 RAM。
- [MapView API](https://developer.garmin.com/connect-iq/api-docs/Toybox/WatchUi/MapView.html)的支持列表包含 FR955/965，不含 FR255。因此保留 FR255 自绘地图方案，日后可为支持机型单独实现原生后端。
- [Position.Info](https://developer.garmin.com/connect-iq/api-docs/Toybox/Position/Info.html)的字段可为空；[Position.Quality](https://developer.garmin.com/connect-iq/api-docs/Toybox/Position.html)区分不可用、最后已知、差、可用、好。`accuracy` 是质量枚举，不是以米为单位的精度。
- [持久存储](https://developer.garmin.com/connect-iq/core-topics/persisting-data/)单值上限 32 KB；这不等于应用拥有无限存储或可以随意读写手表文件系统。
- [ActivityRecording API](https://developer.garmin.com/connect-iq/api-docs/Toybox/ActivityRecording.html)提供开始、暂停/停止、保存 FIT 的会话能力；需要正确权限、生命周期和实机验证，不能保证原生跑步的全部训练指标。

## 方案比较

| 方案 | 官方能力 | 本项目采用方式 |
|---|---|---|
| [FR255 原生课程](https://www8.garmin.com/manuals/webhelp/GUID-676967A0-1B23-4384-9BC9-76F3D643F1C8/EN-US/GUID-63B647CE-1409-4BE9-8A8B-33EFEFCBF255.html) | 课程选择、反向课程、查看与平移/缩放课程地图；[导航设置](https://www8.garmin.com/manuals/webhelp/GUID-676967A0-1B23-4384-9BC9-76F3D643F1C8/EN-US/GUID-A302AFEE-C535-4C80-9DDD-95B717620C5B.html)提供转弯提示选项 | 使用预先准备的路线，优先做路线叠加与偏航提醒。不假设第三方程序可直接读取原生课程文件。 |
| [COROS PACE 3 / PACE Pro](https://support.coros.com/hc/en-us/articles/31426902545428-COROS-PACE-3-vs-PACE-Pro-Comparison) | PACE 3 为轨迹导航；PACE Pro 有离线地图 | 将路线导航与底图解耦。底图缺失时仍提供路线、轨迹和方向；不拿两者处理器宣传数字推算 FR255 性能。 |
| [Suunto Race 离线地图](https://www.suunto.com/en-be/Support/Product-support/suunto_race/suunto_race/navigation/offline-maps/) | 按区域下载地图；可独立浏览或在运动中用；缩放、平移、手动回中和可设置回中时间；关闭底图仍可显示轨迹 | 分开「跟随」与「浏览」；提供明确回中动作和可选超时。FR255 采用按键菜单，底图在电脑侧预处理。 |
| [Garmin MapView 体验指南](https://developer.garmin.com/connect-iq/user-experience-guidelines/map-views/) | 有内置地图的机型可调用原生地图视图 | 留出渲染后端接口；FR255 版本不强行使用缺少的硬件/API 能力。 |

## 尚未验证

实际刷新耗时、最坏内存峰值、连续 GPS 的电量消耗、磁干扰下的朝向、长轨迹与 FIT 同时运行表现、数据字段与原生运动的集成。不采用上游「40 MB 包体流畅」作为本 fork 的验收结果。

渭南基线是图像底图，缩放需要预先准备地图级别；单纯缩放图片只会放大像素。OSM 的道路与地点完整性也不由本项目保证。
