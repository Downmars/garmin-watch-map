# 瓦片策略与合规

## 瓦片从哪来

`tools/make_city_pack.py` 从 **OpenStreetMap HOT 渲染服务**拉取：

```
https://{a|b|c}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png
```

脚本会把相邻 2×2 张 256px 瓦片拼成一张 512px 大瓦片再存进资源里，减少资源数量。

## 版权

- 地图数据 © **OpenStreetMap contributors**
- 许可：[ODbL 1.0](https://opendatacommons.org/licenses/odbl/)
- 渲染风格：HOT（Humanitarian OSM Team）样式

**本仓库不含任何瓦片图片**。仓库里只有下载/拼接/编译的脚本，
瓦片由使用者在构建时自行下载。

如果你把生成好的 `.prg` 分发出去，请在使用说明里保留：

> Map data © OpenStreetMap contributors, ODbL.

## 使用政策（重要）

遵守 OSM 的 [瓦片使用政策](https://operations.osmfoundation.org/policies/tiles/)：

- 不要批量爬取整个城市所有缩放级别
- 单次构建控制在合理的瓦片数量（本项目一次最多几百张）
- `User-Agent` 已设置为 `offline-map-builder/1.0`，请勿改成浏览器 UA 绕过限流
- 需要高频/大量使用，请自建瓦片服务器或用商业瓦片服务

## 包体怎么估

| zoom | 分辨率 | 单张覆盖 | 20 km 覆盖需要 | 约包体 |
|---|---|---|---|---|
| 15 | ~2 m/px | ~2.0 km | 10×10 = 100 张 | ~28 MB |
| 14 | ~4 m/px | ~4.0 km | 5×5 = 25 张 | ~7 MB |
| 13 | ~8 m/px | ~7.9 km | 3×3 = 9 张 | ~2.5 MB |
| 12 | ~16 m/px | ~15.8 km | 2×2 = 4 张 | ~1 MB |
| 11 | ~32 m/px | ~31.6 km | 1 张 | ~0.3 MB |

> 实测：40.5 MB（14×11 张 z15）在 Forerunner 255 上运行流畅。

## 想覆盖更大范围

单包硬做会爆内存。推荐**双包**策略：

1. **概览包**：`--zoom 12` 覆盖整城（1–4 张，约 1 MB）
2. **细节包**：`--zoom 15` 只覆盖常去的区（几公里见方）

两个 `.prg` 可以同时装在手表上，按需切换。

## 国内城市的坐标偏移

OSM 数据使用 **WGS-84** 坐标系。国内部分地图服务（高德/百度）用 GCJ-02 / BD-09，
两者之间有几个百米的偏移。

本项目直接使用 OSM 瓦片 + 手表 GPS（WGS-84），**两端一致**，所以不需要纠偏。
只有当你混用国内商业地图底图时才需要考虑坐标转换。
