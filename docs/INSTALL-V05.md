# FR255 地图 · v0.6.0-alpha.1

结束正在记录的运动，解压安装包。只把 weinan-fr255.prg 复制到手表 Internal Storage/GARMIN/Apps，等待复制完成再断开 USB。使用原版本时保持同名覆盖，保留原轨迹数据。应用列表中的新名称为「离线地图」。

在跟随状态按 BACK 打开地图菜单。「地图地区」切换当前地区，「GPX 路线」列出当前地区的路线。UP/DOWN 选择，START 确认。浏览状态的第一次 BACK 会先回中，第二次打开菜单。选中路线后地图移到起点，蓝线表示计划路线，深红线表示实际记录。选「隐藏计划路线」可关闭叠加。地图页 START 循环切换上下、左右、缩放模式。

若制包时设置了在线底图，手表会经连接的手机与 Garmin Connect 请求当前视野的图片，图片到达后覆盖本地底图。断开手机、请求出错或超时会切回当前位置的已打包底图，保持视角。恢复连接后自动重试。包外显示「无离线覆盖」，GPX 和记录轨迹仍使用原来的坐标。地图上「在线」后显示所用图源署名。图源留空的项目只显示离线底图。

示例 GPX 为合成折线，用于演示切换。新增地区或 GPX 时，用桌面制包器更新项目并重新生成安装 ZIP。包内已有的地区与路线在手表上离线切换。真实手机蓝牙传图耗时、真机内存、长时间续航仍待验证。

地图数据 © OpenStreetMap contributors，ODbL：https://www.openstreetmap.org/copyright 。底图 © OpenStreetMap France，CC BY-SA 2.0：https://www.openstreetmap.fr/open-data/ 。服务使用条件：https://www.openstreetmap.fr/usage/ 。
