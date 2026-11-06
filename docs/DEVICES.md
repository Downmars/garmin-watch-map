# 机型适配

## 已测试

| 机型 | product id | 状态 |
|---|---|---|
| Forerunner 255 | `fr255` | ✅ 主力开发机，离线/在线均实测流畅 |
| Forerunner 255 Music | `fr255m` | 同代，理论可用 |
| Forerunner 255S | `fr255s` | 同代，理论可用 |
| Forerunner 255S Music | `fr255sm` | 同代，理论可用 |
| Venu 4 41mm | `venu441mm` | 在线版已编译，未充分实测 |
| Venu 4 45mm | `venu445mm` | 在线版已编译，未充分实测 |

## 加一个新机型

1. 确认 SDK 里装了该机型的 device profile：
   ```
   <SDK>\Devices\<product_id>\
   ```
   `SDK Manager` 里可以勾选安装。

2. 在对应的 `manifest.xml` 的 `<iq:products>` 里加一行：

   ```xml
   <iq:product id="fr265"/>
   ```

3. 重新编译：

   ```bat
   pwsh -File tools\build_devices.ps1 fr265
   ```

   或者直接用 `monkeyc`：

   ```bat
   "%CIQ_SDK%\bin\monkeyc.bat" -f app\monkey.jungle -o dist\map_fr265.prg -d fr265 -y developer_key.der
   ```

## 屏幕尺寸

地图代码按 260×260 绘制（FR255 的 MIP 屏）。其他分辨率的手表会自动居中，
但边缘可能留白或裁切。要精确适配，改 `MapApp.mc` 里基于 `dc.getWidth()` /
`dc.getHeight()` 的计算即可（大部分已经是自适应的）。

## 内存限制

| 项 | 值 |
|---|---|
| watch app 堆 | 约 512 KB |
| 单包实测上限 | 40 MB（瓦片走 Rez 资源，不占运行时堆） |

瓦片是**编译期资源**（Rez），运行时按需绘制，所以包大不等于内存爆。
真正的限制是**安装包体积**和**绘制性能**。
