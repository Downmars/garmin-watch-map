# Garmin FR255 离线地图 · 渭南示例

基于 [cc2994358194-create/garmin-watch-map](https://github.com/cc2994358194-create/garmin-watch-map) 的持续迭代 fork，目标机型为普通 **Forerunner 255**。保留上游 MIT 许可和历史；当前优先维护 `app/` 的离线地图。

**先看 [迭代计划](docs/ROADMAP.md)、[设备与方案调研](docs/RESEARCH.md)、[验证标准](docs/VALIDATION.md)、[版本记录](CHANGELOG.md)。**

## 当前能力

- 渭南主城区离线街道图：中心 WGS-84 34.5000, 109.5000，覆盖约 22.2×22.2 km。
- 自绘地图、GPS 位置、方向、临时轨迹和估算距离；FR255 五键操作。
- v0.1 基线有下载缓存、失败中止、范围校验、压缩与 Windows 构建脚本。
- v0.2 alpha 在独立分支开发定位质量/过期提示、断段和浏览保持。请以对应分支的 CHANGELOG 和验证报告为准。

目前没有目的地搜索、自动寻路、多级缩放或 FIT 保存。退出后不保留完整活动。`online/`、`app-field/` 和 `probe/` 为上游原型，尚未纳入本 fork 的实机发布范围。

FR255 不支持原生 `WatchUi.MapView`，使用预生成图像底图。FR955/965 等机型有不同 API 能力，不能直接套用此处的功能与内存结论。

## 安装与操作

1. 将为 **fr255** 编译的 `.prg` 复制到手表 `Internal Storage/GARMIN/Apps`；传输完成后断开 USB。
2. 从手表应用列表打开「渭南地图」，室外等待有效定位。
3. UP/DOWN 平移，START 切换上下/左右轴。v0.2 浏览模式中 BACK 先回中，再次 BACK 才退出；v0.1 则会在约 5 秒后自动回中。

文件夹卡顿或显示空白时，先排查 MTP 连接、USB 线和其他 Garmin 程序占用，不通过随意新建系统目录解决。详见 [渭南说明](WEINAN.md)。

## 开发与验证

需要 Python + Pillow、Java 17、Garmin Connect IQ SDK 和 FR255 官方设备配置，以及本地生成的签名私钥。私钥不能提交。SDK 安装见 [Garmin 官方入门](https://developer.garmin.com/connect-iq/connect-iq-basics/getting-started/)。

本机已准备依赖和地图时：

```powershell
.\build-weinan.ps1 -CompileOnly
python -m unittest discover -s tests -v
```

首次生成地图使用 `.\build-weinan.ps1`，仅代理不可用时加 `-Direct`。脚本提供 `CIQ_PY`、`CIQ_JAVA`、`CIQ_SDK`、`CIQ_KEY` 环境变量覆盖；Java 变量指向可执行文件。城市资源由脚本生成，不在 Git 中。

切换到 `iteration/v0.2-reliability` 后，可以指定 `-OutFile` 避免覆盖旧包，并构建 Monkey C 单元测试：

```powershell
.\build-weinan.ps1 -CompileOnly -TestBuild -OutFile dist\navigation-tests.prg
```

启动 Garmin 模拟器后，用 SDK 的 `monkeydo.bat dist\navigation-tests.prg fr255 /t` 执行，Java 需在 PATH 中。本机自动验证也可直接调用 SDK 对应 Java 入口。只编译测试包不代表测试已经执行。

GitHub CI 运行不联网的 Python 测试、语法/XML 和提交内容检查。Monkey C 测试需要本地 SDK，实机测试由使用者完成并记录；三者不能互相替代。

## 版本与贡献

- `main`：已经核验的基线与计划。
- `iteration/v0.2-reliability`：首轮定位与浏览改进；实机验收前为 alpha。
- 迭代在自己的 fork 内审查，不自动向上游提 PR。
- 只提交源码、测试与文档；排除私钥、SDK、生成底图、个人 GPX/FIT 和本地日志。

见 [贡献指南](CONTRIBUTING.md) 和 [待办](docs/BACKLOG.md)。

## 来源与许可

代码沿用 [MIT](LICENSE)。地图数据 © OpenStreetMap contributors，[ODbL](https://www.openstreetmap.org/copyright)；HOT 底图 © OpenStreetMap France，[CC BY-SA 2.0](https://www.openstreetmap.fr/open-data/)。下载遵循该提供方的 [使用规则](https://www.openstreetmap.fr/usage/)。包含底图的安装包分发时也必须保留署名和相应许可。
