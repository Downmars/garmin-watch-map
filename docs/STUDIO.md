# 离线地图制包器 · Windows x64

打开 FR255-Atlas-Studio.exe。示例项目含渭南主城区、西安钟楼和三条合成演示路线。

1. 点「添加」输入地区名称、WGS84 中心和边长。已有 GPX 时，点「从 GPX 建立地区」，软件会根据路线估算范围。点「载入预览底图」可在联网时查看覆盖区域。
2. 选中左侧地区，点「导入 GPX」加入一条或多条路线。也可以点「手绘路线」，依次点选转弯位置，保存为 GPX 并加入该地区。手绘相邻点以直线相连。
3. 点「保存项目」，得到项目 JSON 和同目录的路线文件夹。把两者一起发送给其他制包者，就能继续编辑。
4. 点「生成手表安装包」并选择 ZIP 保存位置。把 ZIP 发给使用 FR255 的人；接收者解压，把其中的 weinan-fr255.prg 放到 GARMIN/Apps。地图菜单中选择「地图地区」或「GPX 路线」。

第一次制包，在「制包设置」选择 [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 的目录和 Java 17 JDK 的 java.exe。用 SDK Manager 安装普通 Forerunner 255 设备配置。选择自己已有的 .der 签名，或点击「创建新签名」。保存私钥备份，以后更新自己的包时继续使用。Windows EXE 随附 Python、Pillow、界面和手表应用模板。Garmin SDK、设备配置和 JDK 由制包者一次性安装。只接收 PRG 的人只需要手表和 USB 数据线。

首轮下载需要网络，底图按地区缓存。框选范围为正方形，使用 WGS84 经纬度；非 WGS84 路线应先转换。项目可以包含 1–8 个地区、每个地区最多 16 条路线。制包器检查 GPX 是否越界，将路线简化到最多 192 个点，保留分段和端点，过于复杂时会提示拆分。FR255 候选包限制为 180 张合成底图和 15 MB PRG，防止误选过大范围。每个项目生成一个安装包，包内切换即时生效。加入新地区和路线后，再生成一次并同名覆盖。

路线蓝线用于查看预设路径，深红色轨迹记录实际移动。选中地区时进入浏览，选择路线时地图移到起点，BACK 回中。此次范围为导入、手绘和离线切换；剩余距离与偏航提醒属于后续导航功能。

若提示 `Invalid device id specified: 'fr255'`，在「制包设置」中检查 **FR255 设备目录**。默认自动读取 Garmin SDK Manager 的下载位置。Windows 常见设备目录为 `%APPDATA%\Garmin\ConnectIQ\Devices\fr255`，应包含 `compiler.json` 与 `fr255.bin`。设备目录缺失时，在 SDK Manager 的 Devices 页安装普通 Forerunner 255。alpha.2 会先检查设备配置，并把选中的目录传给编译器。本版本使用 Garmin SDK 9.3.0 验证。

## 在线底图

点「在线底图」填写获准用于此应用的 HTTPS XYZ 栅格瓦片模板和手表上的署名，保存项目并重新生成 ZIP。模板应按 WGS84 经纬度使用 Web Mercator、256×256 像素瓦片、Y 向南递增，提供 z13 和 z15，各含一个 `{z}`、`{x}`、`{y}`。例如 `https://tiles.example.invalid/{z}/{x}/{y}.png` 仅演示格式。地址会写入项目和生成的 PRG，仅使用允许公开的客户端令牌。请求只包含当前可视瓦片坐标，采用 Garmin 图片接口，该接口不提供自定义请求头。图源须允许这种访问及署名方式。

旧项目或留空地址只用离线地图。配置图源后，在线图片经手机 Garmin Connect 按需取得，离线图片先显示。每次只发起一个有效请求，最多保留视口中心附近四张在线图片。请求等待 15 秒后放弃，失败后间隔 30 秒再试。超出当前地区时会寻找包内其他覆盖该位置的底图。网络状态切换不改变视口、GPX 选择或运动记录。测试时可先在已打包地区观察「在线」，再断开蓝牙观察「离线」，最后恢复蓝牙。实机表现受图源与手机网络影响。

## 从源码运行

安装 Python 3.11+（带 tkinter）、Pillow。在仓库目录执行：

```powershell
python -m pip install Pillow
python tools/atlas_studio.py
```

生成桌面 EXE：

```powershell
python -m pip install pyinstaller==6.16.0
python tools/freeze_studio.py
```

自动化制包可以用 `python -X utf8 tools/atlas.py examples/atlas.json --check` 检查项目，再指定 `--sdk`、`--java`、`--key`、`--output`。UTF-8 模式可在英文版 Windows 重定向日志时正确输出中文地区名。项目使用稳定的地区/路线 id 和相对 GPX 路径，格式见 examples/atlas.json。底图生成、GPX 解析和桌面界面分别使用同一套制包逻辑。底图和编译在临时目录完成，校验全部通过后才替换输出 ZIP。个人 GPX 会成为计划路线的一部分，只把成品分享给预期的接收者。

底图、数据许可与手表安装步骤见 [安装说明](INSTALL-V05.md)。
