# Garmin 手表离线地图 / 在线地图

在 **Garmin Forerunner 255**（以及同代 Connect IQ 3.x 手表）上显示城市街道级地图、实时轨迹和方向箭头。

Garmin Connect IQ **不支持原生地图**，官方商店也没有离线地图包。这个项目把整条流水线自动化：

```
城市坐标 → 下载 OSM 瓦片 → 拼接 512px 大瓦片 → 生成 Connect IQ 资源 → 编译 .prg → 侧载到手表
```

换一个城市只需要改两个数字（经纬度）。

> 目标：让每个城市的人都能给自己生成一份离线地图包，不必依赖别人做好。

---

## 特性

| 功能 | 说明 |
|---|---|
| 离线地图 | z15 街道级（约 2 m/px），40 MB 包在 FR255 实测流畅 |
| 实时轨迹 | GPS 定位点 + 运动方向箭头叠加在地图上 |
| 在线地图 | 需要手机连着网，实时拉瓦片（无需预生成包） |
| 数据字段版 | 运动页面里内嵌小地图，不打断活动记录 |
| 一键换城市 | `build-city.bat --name beijing --lat 39.9042 --lon 116.4074` |

---

## 快速开始（3 步）

### 1. 装依赖

| 依赖 | 说明 |
|---|---|
| Python 3.9+ 与 Pillow | `pip install pillow` |
| JDK 17 | Connect IQ 编译器要求 |
| Connect IQ SDK 9.x | <https://developer.garmin.com/connect-iq/sdk/>（用 SDK Manager 安装） |
| 开发者密钥 | 免费注册：<https://developer.garmin.com/connect-iq/developer-key/>，得到 `developer_key.der` |

把 `developer_key.der` 放到仓库根目录，或者用环境变量指定（见下）。

### 2. 设置环境变量

```bat
set CIQ_SDK=C:\Users\you\AppData\Roaming\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.3.0-2026-10-20-95888f262
set CIQ_KEY=C:\path\to\developer_key.der
```

> `CIQ_SDK` 指向**包含 `bin\monkeyc.bat` 的那一层目录**。

### 3. 生成某个城市的地图包

```bat
build-city.bat --name qingdao --lat 36.10 --lon 120.43 --km 24 --zoom 15
```

产物在 `dist\qingdao.prg`，复制到手表 `GARMIN\Apps\` 即可。

其他城市示例：

```bat
build-city.bat --name beijing  --lat 39.9042 --lon 116.4074 --km 20 --zoom 15
build-city.bat --name shanghai --lat 31.2304 --lon 121.4737 --km 20 --zoom 15
build-city.bat --name chengdu  --lat 30.5728 --lon 104.0668 --km 20 --zoom 15
```

---

## 参数说明

| 参数 | 含义 |
|---|---|
| `--name` | 输出文件名（只用于命名） |
| `--lat` `--lon` | 地图中心点经纬度 |
| `--km` | 覆盖边长（公里），越大包体越大 |
| `--zoom` | 瓦片级别 |
| `--out` | 可选，指定输出 `.prg` 路径 |

### 包体估算

一张 512px 瓦片约 250–300 KB：

| zoom | 每张覆盖 | 20 km 需 | 约包体 |
|---|---|---|---|
| 15 | ~2.0 km | 10×10 = 100 张 | ~28 MB |
| 13 | ~7.9 km | 3×3 = 9 张 | ~2.5 MB |
| 12 | ~15.8 km | 2×2 = 4 张 | ~1 MB |
| 11 | ~31.6 km | 1 张 | ~0.3 MB |

**实测上限**：40.5 MB（14×11 张 z15）在 Forerunner 255 上运行流畅。再大没有验证过。

> 想覆盖整座城市又不想包体爆炸：用 `--zoom 12` 做全域概览（1–4 张），常去的片区再单独做一个 `--zoom 15` 细节包。

---

## 安装到手表

1. USB 连接手表，长按 **LIGHT** 键 → 选 **USB Mass Storage**
2. 打开电脑上的 `GARMIN` 磁盘，把 `.prg` 复制进 `GARMIN\Apps\`
3. 拔线，手表应用列表里出现「轨迹地图」

> 不需要发布到 Connect IQ Store，侧载即可。

---

## 项目结构

```
.
├── app/                  离线地图 Watch App
│   ├── manifest.xml
│   ├── monkey.jungle
│   └── source/MapApp.mc          地图渲染 + 轨迹 + 方向箭头
├── online/               在线地图 Watch App（实时拉瓦片）
├── app-field/            运动数据字段版（页面内嵌小地图）
├── probe/                Communications 连通性探测小工具
├── tools/
│   ├── make_city_pack.py         主流水线：下载 → 生成 → 编译
│   ├── gen_tiles.py              瓦片生成器（重试 + 镜像回退）
│   ├── make_icon_final.py        图标渲染
│   ├── build_online.ps1          在线版多机型构建
│   └── build_devices.ps1         离线版多机型构建
├── build-city.bat        一键入口
└── docs/
```

`app/source/MapData.mc`、`app/resources/drawables/tile_*.png`、`drawables.xml`
都是**构建时生成**的（按城市坐标算出来），不在仓库里。第一次跑 `build-city.bat` 时自动生成。

---

## 数据来源与合规

- 瓦片来源：**OpenStreetMap HOT** 渲染（`*.tile.openstreetmap.fr/hot`）
- 地图数据 © **OpenStreetMap contributors**，遵循 [ODbL](https://opendatacommons.org/licenses/odbl/)
- 本仓库**不包含**任何瓦片图片，只包含生成脚本；运行时由使用者自行下载
- 请遵守 [OSM 瓦片使用政策](https://operations.osmfoundation.org/policies/tiles/)：控制单次下载量、不要批量爬取整城所有级别
- 在线地图版本中的高德（AMap）瓦片仅用于个人学习调试，商用请接入带 key 的正式服务

如果你把生成的 `.prg` 分发给别人，请注意其中包含 OSM 数据，需要保留上述署名。

---

## 已知限制

| 限制 | 说明 |
|---|---|
| 设备 | 主要为 FR255 开发；同代 CIQ 3.x 手表理论可用，需在 manifest 加机型 |
| 内存 | watch app 堆约 512 KB，瓦片走 Rez 资源而非运行时加载 |
| 包体 | 单包 40 MB 实测 OK，再大会影响安装与运行 |
| 缩放 | 定位在固定 zoom，不做多级缩放（Connect IQ 内存限制） |
| 坐标系 | WGS-84；GCJ-02 偏移在境外瓦片上不存在，国内 OSM 数据本身已是 WGS-84 |

---

## 想给自己的城市做包？

1. Fork 本仓库
2. 跑一次 `build-city.bat` 生成你城市的包，本地验证能用
3. 如果改了渲染逻辑/性能优化，欢迎提 PR；**不要 PR 瓦片文件**（体积 + 版权）

---

## 致谢

- [OpenStreetMap](https://www.openstreetmap.org/) 及其贡献者
- Garmin [Connect IQ SDK](https://developer.garmin.com/connect-iq/)

## 许可证

代码部分见 [LICENSE](LICENSE)。地图数据版权归 OpenStreetMap contributors（ODbL）。
