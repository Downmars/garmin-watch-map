# Garmin FR255 离线地图 · 渭南示例

基于 [cc2994358194-create/garmin-watch-map](https://github.com/cc2994358194-create/garmin-watch-map) 的持续迭代 fork，目标机型为普通 **Forerunner 255**。保留上游 MIT 许可和历史；当前优先维护 `app/` 的离线地图。

**先看 [迭代计划](docs/ROADMAP.md)、[设备与方案调研](docs/RESEARCH.md)、[验证标准](docs/VALIDATION.md)、[版本记录](CHANGELOG.md)。**

当前候选版 **v0.6.0-alpha.4** 提供 Windows 桌面制包器，可选地区、导入或手绘 GPX 并生成 FR255 安装 ZIP。项目可选填已获授权的 HTTPS XYZ 在线图源。手表先显示已打包的底图，通过手机取到在线图片后更新，失联或请求失败时使用本地底图。未配置在线地址的项目保持纯离线。地图状态提示和比例尺使用透明背景；屏幕轨迹结合定位间隔和速度判断跳变，修复正常骑行/开车时超过 50 米就断线的问题。见 [制包器说明](docs/STUDIO.md) 和 [手表操作](docs/INSTALL-V05.md)。

v0.4.0-alpha.1 已交付街道/概览双级地图、比例尺及缩放按键模式。见 [v0.4 验证报告](docs/verification-v0.4-alpha.1.md)。

记录入口统一为「开始记录」，在「设置 → 活动类型」选择步行、跑步、骑行或通用轨迹，并记住上次选择。

用户已反馈 v0.3.0-alpha.3 功能暂且正常，见 [阶段反馈](docs/acceptance-v0.3.md)，其原包继续作为回退点。v0.3 alpha.1/alpha.2 有长轨迹恢复超时问题，不建议回退到这两版。v0.4 按 [方案](docs/PLAN-V04.md) 分阶段实现；最近轨迹概览入口和地图信息页留待后续。

## 当前能力

- 渭南主城区离线街道 z15 / 概览 z13：中心 WGS-84 34.5000, 109.5000，覆盖约 22.2×22.2 km；概览横向视野约为街道的 4 倍。
- 自绘地图、GPS 位置、方向、800 点简化轨迹和估算距离；FR255 五键操作。
- v0.1 基线有下载缓存、失败中止、范围校验、压缩与 Windows 构建脚本。
- v0.2 提供定位质量/过期提示、断段和浏览保持，并修复静止罗盘更新兼容性错误。
- v0.3 候选版支持新步行/跑步、暂停/继续、保存或确认丢弃 FIT、退出菜单及双份轨迹恢复摘要。
- alpha.2 缓存轨迹投影、跳过屏幕外线段并减少重复画线；模拟器长轨迹绘制改善，实机手感待复测。
- alpha.3 分批校验/恢复摘要，恢复时保护原数据；减少保存校验和退出写入的重复工作，真实模拟器启动至退出检查通过。

- v0.4 缩放保持地理中心，轨迹沿用投影缓存；直接计算可见瓦片，每次定时器回调最多准备一个新瓦片编号，最多维护 4 个可见编号。图片对象在绘图回调内使用，缓存交给系统管理。

目前没有目的地搜索、自动寻路、多次活动列表或自动显示整条轨迹的入口。恢复摘要仅保留最近的简化屏幕轨迹，不接续上次 FIT 会话；完整活动交由 Garmin 原生 FIT 保存。FIT 在实机的内容和 Connect 同步仍待验收。`online/`、`app-field/` 和 `probe/` 为上游原型，尚未纳入本 fork 的实机发布范围。

FR255 不支持原生 `WatchUi.MapView`，使用预生成图像底图。FR955/965 等机型有不同 API 能力，不能直接套用此处的功能与内存结论。

## 安装与操作

1. 将为 **fr255** 编译的 `.prg` 复制到手表 `Internal Storage/GARMIN/Apps`；传输完成后断开 USB。
2. 从手表应用列表打开「离线地图」（旧包名称为「渭南地图」），室外等待有效定位。
3. START 循环切换“上下 → 左右 → 缩放”。上下/左右模式中 UP/DOWN 平移；缩放模式中 UP 放大到街道、DOWN 缩小到概览。BACK 从浏览回中，在跟随模式打开运动菜单。菜单中 UP/DOWN 选择、START 确认、BACK 返回地图。

文件夹卡顿或显示空白时，先排查 MTP 连接、USB 线和其他 Garmin 程序占用，不通过随意新建系统目录解决。详见 [渭南说明](WEINAN.md)。

## 开发与验证

需要 Python + Pillow、Java 17、Garmin Connect IQ SDK 和 FR255 官方设备配置，以及本地生成的签名私钥。私钥不能提交。SDK 安装见 [Garmin 官方入门](https://developer.garmin.com/connect-iq/connect-iq-basics/getting-started/)。

本机已准备依赖和地图时：

```powershell
.\build-weinan.ps1 -CompileOnly
python -m unittest discover -s tests -v
```

首次生成双级地图使用 `.\build-weinan.ps1`，仅代理不可用时加 `-Direct`。也可通过 `-Lat`、`-Lon`、`-Km` 指定小区域进行开发。v0.4 固定使用 z15/z13；旧 `build-city.bat` 单层入口已停用，避免覆盖双级资源。脚本提供 `CIQ_PY`、`CIQ_JAVA`、`CIQ_SDK`、`CIQ_KEY` 环境变量覆盖；Java 变量指向可执行文件。城市资源由脚本生成，不在 Git 中。

可以指定 `-OutFile` 避免覆盖旧包，并构建 Monkey C 单元测试：

```powershell
.\build-weinan.ps1 -CompileOnly -TestBuild -OutFile dist\navigation-tests.prg
```

启动 Garmin 模拟器后，用 SDK 的 `monkeydo.bat dist\navigation-tests.prg fr255 /t` 执行，Java 需在 PATH 中。本机自动验证也可直接调用 SDK 对应 Java 入口。只编译测试包不代表测试已经执行。

GitHub CI 运行不联网的 Python 测试、语法/XML 和提交内容检查。Monkey C 测试需要本地 SDK，实机测试由使用者完成并记录；三者不能互相替代。

## 版本与贡献

- `main`：v0.2 功能验收基线与计划；长时间内存/续航测试仍待完成。
- `iteration/v0.3-recording`：运动记录与恢复候选版；实机验收前为 alpha。
- `iteration/v0.4-browsing`：基于 v0.3 分支的双级缩放候选版，单独审查新改动。
- `iteration/v0.5-packs`：桌面制包器、地区及 GPX 切换。
- `iteration/v0.6-hybrid`：可选在线底图与离线回退，见 [验证记录](docs/verification-v0.6-alpha.1.md)。
- 迭代在自己的 fork 内审查，不自动向上游提 PR。
- 只提交源码、测试与文档；排除私钥、SDK、生成底图、个人 GPX/FIT 和本地日志。

见 [贡献指南](CONTRIBUTING.md) 和 [待办](docs/BACKLOG.md)。

## 来源与许可

代码沿用 [MIT](LICENSE)。地图数据 © OpenStreetMap contributors，[ODbL](https://www.openstreetmap.org/copyright)；HOT 底图 © OpenStreetMap France，[CC BY-SA 2.0](https://www.openstreetmap.fr/open-data/)。下载遵循该提供方的 [使用规则](https://www.openstreetmap.fr/usage/)。包含底图的安装包分发时也必须保留署名和相应许可。
