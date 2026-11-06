# 贡献指南

## 只想给自己的城市做个包？不用改代码

这是最常见的需求，**不需要 fork 或提 PR**：

```bat
build-city.bat --name yourcity --lat 30.5728 --lon 104.0668 --km 20 --zoom 15
```

生成的 `dist\yourcity.prg` 直接拷到手表 `GARMIN\Apps\` 就能用。
如果构建过程顺利，说明你的环境没问题，也没有需要反馈的东西。

---

## 想改进代码？

欢迎 PR。改动前请确认：

### 1. 本地能构建通过

```bat
build-city.bat --name smoke --lat 36.10 --lon 120.43 --km 2 --zoom 15
```

必须看到 `BUILD SUCCESSFUL` 才算通过。用 `--km 2` 的小包做冒烟测试，
别用整个城市来验证（慢且触发 OSM 限流）。

### 2. 不要提交这些

| 文件 | 原因 |
|---|---|
| `developer_key.der` / `.pem` | 私钥 |
| `dist/*.prg` | 编译产物 |
| `app/resources/drawables/tile_*.png` | OSM 瓦片，版权 + 体积 |
| `app/source/MapData.mc` | 构建时按坐标生成 |
| `appdata/`、`temp/` | SDK 与缓存 |

`.gitignore` 已经覆盖，但 `git add -f` 之前请想清楚。

### 3. 改了什么，说清楚

PR 描述里写：

- 解决什么问题（例如「静止时罗盘抖动」「z15 包编译内存不足」）
- 在哪个机型上测过
- 有没有影响包体大小

---

## 代码结构速查

| 文件 | 职责 |
|---|---|
| `app/source/MapApp.mc` | 离线地图渲染、GPS 轨迹、方向箭头、平移 |
| `online/source/OnlineApp.mc` | 在线地图（运行时拉瓦片） |
| `app-field/source/MapField.mc` | 运动数据字段版 |
| `tools/make_city_pack.py` | 主流水线：算瓦片范围 → 下载 → 拼接 → 生成资源 → 编译 |
| `tools/gen_tiles.py` | 瓦片下载（重试 + 镜像回退 + 灰色占位） |
| `tools/make_icon_final.py` | 图标渲染（320px 渲染后降采样到 40px） |

### 关键常量

- 瓦片是世界坐标（Web Mercator）的 512px 图片，`MapData.ORIGIN_X/Y` 是最左上角的全局像素坐标
- `MapData.WORLD` = `256 << zoom`，所有经纬度换算都基于它
- 中心点来自 `MapData.CENTER_LAT/LON`（构建时写入），**不要在 `MapApp.mc` 里写死坐标**

---

## 机型适配

加新机型见 [docs/DEVICES.md](docs/DEVICES.md)：

1. SDK Manager 里装该机型的 device profile
2. `manifest.xml` 的 `<iq:products>` 加一行
3. `pwsh -File tools\build_devices.ps1 <productid>`

---

## 已知的坑

见 [docs/BUILD.md](docs/BUILD.md) 的「常见错误」表，包括：

- SDK 9.x 的 `type` 必须是 `watch-app`（带连字符）
- `minSdkVersion` 不是 `minApiLevel`
- Monkey C 局部变量不能显式标类型
- `getInitialView` 在 SDK 9.x 的返回类型是 `[Views] or [Views, InputDelegates]`
- `%TEMP%` 目录不存在会导致 `Can't create cache file`

遇到新坑，欢迎补进那张表。

---

## 提交规范

提交信息用中文或英文都行，能说清就行：

```
修复静止时方向箭头抖动
add z12 overview preset
```

不用严格遵守 Conventional Commits。
