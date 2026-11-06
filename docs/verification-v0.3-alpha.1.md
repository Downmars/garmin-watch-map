# v0.3.0-alpha.1 验证报告

日期：2026-11-06；目标：普通 Forerunner 255；SDK 9.3.0 / Java 17。

## 已完成

- 发布包及测试包编译成功，保留编译器警告输出。
- **32 项 Monkey C 测试逐项 PASS，摘要 passed=32、failed=0、errors=0**。包括既有定位/静置崩溃回归，以及运动会话、菜单、轨迹、恢复逻辑。
- 原生 `ActivityRecording.Session` 的开始、暂停、继续、保存在 FR255 模拟器中返回成功。本项是原生调用验证，尚未导出并解析完整活动 FIT，也未在 Garmin Connect 中验收。
- 模拟器真实 Storage 中完成 800 点的双槽写入和读回，测试后清理专用测试键。损坏最新摘要可回退前一份；写入失败保留可用记录；确认丢弃后两槽均改为空轨迹。
- 4000 次追加后缓冲仍只有 800 个条目；失联、暂停和大跳点断段；恢复后的历史轨迹没有实时位置标记或活动中的 FIT 会话。
- 菜单绘制、丢弃前确认、取消、保存失败重试和存储失败提示均有回归测试。
- 开启满容量地图绘制后，`System.getSystemStats().usedMemory` 采样为 **88,280 B**；满容量恢复存储测试采样为 **131,968 B**。这两个采样来自不同测试场景，不是发布包/实机长时间峰值，也不包含已验证的耗电结论。

测试包与原始日志随本地验证记录保留，安装 ZIP 只包含发布 PRG 和可供检查的测试输出，不含测试 PRG、签名私钥或用户活动。

## 验证边界

MonkeyDo 仍返回 1，与逐项 PASS 和摘要不一致；沿用之前记录的 SDK 运行器异常，不隐藏退出码。FR255 编译器对部分动态数组访问给出类型推断警告，不能称为零警告构建。

未完成：实机菜单布局、暂停后的 FIT 数据内容、Connect 同步、强制终止时的 FIT 行为、2 小时稳定性和实际内存/耗电。用户对 v0.2 的功能验收不替代这些 v0.3 验收项。新版本保持 alpha 和草稿 PR。

## 设计依据

- [Garmin ActivityRecording.Session](https://developer.garmin.com/connect-iq/api-docs/Toybox/ActivityRecording/Session.html)：使用 start/stop 在同一会话内开始与暂停，检查 save/discard 返回值后才释放会话。
- [Garmin ActivityRecording](https://developer.garmin.com/connect-iq/api-docs/Toybox/ActivityRecording.html)：目标设备支持原生活动记录；清单增加 Fit 权限，不复制原生运动的全部指标假设。
- [Garmin Storage](https://developer.garmin.com/connect-iq/api-docs/Toybox/Application/Storage.html)：单值大小有限，使用有界整数坐标数组、数值版本与序号、校验和双槽；不保存 Session 对象或持久化 Symbol。

两槽属于失败回退策略，不承诺设备断电时的文件系统原子性。恢复只恢复屏幕摘要，不声称重启后能够继续同一 FIT。实机操作见 [INSTALL-V03.md](INSTALL-V03.md)。
