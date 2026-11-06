# 渭南离线地图 · Forerunner 255

这是以 https://github.com/cc2994358194-create/garmin-watch-map 为基础的本地构建。

安装包：`dist/weinan-fr255.prg`，约 **9.31 MB**。原始源码版本：`79897ff15d0cb27eb8b1caa66e76639644ac02fa`，本地修正见下文。

已使用 Connect IQ SDK 9.3.0、Java 17 完成编译；121 张地图图片和四项自动检查通过。最终安装包已在 FR255 模拟器中启动，并通过 24 秒合成 GPX 回放检查定位跟随、由北转东的方向变化、轨迹和累计里程显示。尚未在实体手表上验证。

## 地图范围

- 型号：Garmin Forerunner 255（普通版；不是 255S 或 Music 版）。
- 中心：WGS-84 北纬 34.5000°、东经 109.5000°，渭南主城区。
- 请求范围：以中心为基准，边长约 20 公里；按地图网格向外对齐后约 22.2×22.2 公里。
- 级别：zoom 15，中心处约 3.94 米/像素。
- 资源：11×11 张 512×512 地图图片，由 484 张原始瓦片拼接。
- 范围是渭南主城区及周边，不是渭南全市行政区域。
- 中心点参考：[联合国地名资料](https://ungegn.un.org/dashboard/cities/details?id=2419)。

## 安装与使用

1. 用数据线连接手表，打开 Windows 文件资源管理器中的 Garmin 设备。
2. 把 `dist/weinan-fr255.prg` 复制到手表的 `GARMIN/APPS` 文件夹。手表需要留出足够空间。
3. 安全断开连接，在手表应用列表中打开“渭南地图”。
4. 到室外等待 GPS 定位。未定位时会显示预设的渭南中心；定位后会跟随当前位置。

UP/DOWN：上下平移；START：切换为左右平移，再次按下切回。手动平移后约 5 秒恢复跟随定位。BACK：退出。

这是独立地图应用，显示定位、临时轨迹和累计距离。它没有路线规划、转弯导航或 FIT 活动保存；退出后轨迹不保存。在地图范围外无法显示当地底图，视图会停在边界。

## 在这台电脑重新构建

双击 `build-weinan.bat`，或者在此目录执行：

```powershell
.\build-weinan.ps1
```

图片已缓存，重复构建会复用缓存。若本机代理失效，可仅对本次下载使用直连：

```powershell
.\build-weinan.ps1 -Direct
```

只重新编译现有地图（不下载）：

```powershell
.\build-weinan.ps1 -CompileOnly
```

更改中心或范围：

```powershell
.\build-weinan.ps1 -Lat 34.5000 -Lon 109.5000 -Km 20 -Zoom 15
```

脚本默认使用此任务目录下的 `work/venv`、`work/jdk17`、`work/connectiq-sdk`，以及 SDK Manager 安装的 FR255 资料。移动工程到其他电脑后，可设置 `CIQ_PY`、`CIQ_JAVA`、`CIQ_SDK`、`CIQ_KEY` 指向相应依赖。`CIQ_JAVA` 应指向 `java.exe`。

本地签名文件是工程根目录中的 `developer_key.der`，已被 Git 忽略。请自行备份，不要公开或提交。它由本机生成，不是 Garmin 账号密码，也不需要上传到 Garmin。

## 此版本的修正

- 为渭南设置中心坐标和应用名。
- 下载失败即中止，避免用空白图片生成安装包；增加有效图片检查、下载缓存和节流。
- 网格向外对齐，确保完整覆盖所请求的中心区域。
- 为地图资源名加入分隔符，避免较大网格的编号冲突。
- 启用 Garmin 图片压缩，降低安装包体积。
- 明确设置 Monkey C 源码路径。
- 修正弧度距离换算重复乘以 π/180 的错误，并处理 GPS 速度为空的情况。
- 移动时使用轨迹方向，避免一秒罗盘刷新覆盖运动方向。
- 在地图上显示 OpenStreetMap 署名。

## 数据来源与许可

地图数据 © OpenStreetMap contributors，遵循 [ODbL](https://www.openstreetmap.org/copyright)。

底图 © OpenStreetMap France，HOT 样式，遵循 [CC BY-SA 2.0](https://www.openstreetmap.fr/open-data/)。下载服务规则见 [OpenStreetMap France Usage Policy](https://www.openstreetmap.fr/usage/)。

程序代码为原仓库 MIT 许可，见 `LICENSE`。地图素材沿用其自身许可；重新分发时请保留署名和许可信息。
