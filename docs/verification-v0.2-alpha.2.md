# v0.2.0-alpha.2 · 静置 IQ! 修复验证

日期：2026-11-06；目标：普通 Forerunner 255。

## 已确认的错误与修复

用户提供的 alpha.1 实机日志有 4 条相同错误：`Symbol Not Found Error` / `Could not find symbol 'abs'`，堆栈指向 `MapView.onHeadingTick` 第 108 行。记录的固件为 29.05，ConnectIQ-Version 为 6.0.4。原始用户日志仅保留本地，不提交仓库或打包分发。

触发条件是定位有效、速度低于 0.7 m/s、罗盘返回方位。定时回调在判断方向变化时调用 `Math.abs`，目标设备运行时没有该符号。

[Garmin Math 文档](https://developer.garmin.com/connect-iq/api-docs/Toybox/Math.html#abs-instance_function)将该模块函数标为 API 6.0.3；但本例实机仍明确报告符号缺失，因此不以日志中的版本号推定函数一定可用，也不要求用户升级固件来规避。修复直接用 `cd > 1.0 || cd < -1.0`，保持原阈值语义并消除该 API 依赖。

## 同一组测试的修复前后对比

运行环境：SDK 9.3.0、Java 17、本机 FR255 模拟器。新增测试替换传感器输入，直接执行实际 `MapView.onHeadingTick`，而非复制一份逻辑测试。

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 静止时正负两个方向更新 | 缺少 abs，ERROR | PASS |
| 跨北向 / 罗盘数据缺失 | 缺少 abs，ERROR | PASS |
| 运动中 / 定位过期时不覆盖方向 | PASS | PASS |
| 连续调用 120 次定时回调 | 缺少 abs，ERROR | PASS |
| 原有 10 项定位/浏览状态测试 | 10 PASS | 10 PASS |
| 总计 | 11 PASS、3 ERROR | **14 PASS、0 FAIL、0 ERROR** |

120 次是快速确定性回调测试，不等于已完成 120 秒实机静置，也不证明整机长期稳定性。MonkeyDo 仍返回 1，保留 alpha.1 中记录的运行器返回码异常；以上通过结论指逐项日志及最终摘要。

发布 PRG 和测试 PRG 编译均成功。构建启用 `-w` 后会显示既有动态容器类型推断警告，未隐藏警告；这些警告仍需后续类型整理。安装文件大小、SHA-256、精确源码和远端 CI 结果见随包 `build-info.json`。测试包、签名私钥和原始用户崩溃日志不进入安装 ZIP。

## 手表复测

替换为 alpha.2 后，在室外等到「GPS 正常」，静置 3–5 分钟并缓慢转动表盘，再步行/停下重复一次。确认不出现 IQ!，方向仍正常更新。其他显示、内存、续航和长时间稳定性继续按 [VALIDATION.md](VALIDATION.md) 验收。

alpha.1 已确认存在本错误，不再推荐安装。回退请使用保存的 v0.1 基线。
