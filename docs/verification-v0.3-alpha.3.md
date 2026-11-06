# v0.3.0-alpha.3 验证报告

日期：2026-11-06（Asia/Shanghai）；目标：普通 Forerunner 255；SDK 9.3.0 / Java 17。

## 实机证据与原因

用户提供的日志记录于北京时间 19:57:08：`Watchdog Tripped Error - Code Executed Too Long`，固件 29.05、Connect IQ 6.0.4。调用链为 `SnapshotStore.checksum → valid → load → MapView.restoreSnapshot → onShow`。启动在同一个回调中读取、校验两份长摘要并恢复坐标；旧 load 对某些有效的较旧摘要还会重复调用 valid。

此前单元测试通过未覆盖真实事件回调的 Watchdog 执行预算。本次新增真实启动检查；不把模拟器运行耗时等同于实机限制，也不通过删除用户摘要规避崩溃。用户原始日志未提交或打包。

## 修复

- `onShow` 只建立恢复任务并启动 100 ms 定时器，立即返回；读取一个槽、每批最多校验 32 对坐标、每批最多恢复 32 个投影点分开执行。
- 校验完整摘要后才使用它；保留旧格式、旧校验算法、序号选择和损坏槽回退。恢复时显示等待画面，完成后再启用 GPS 和常规刷新。
- 恢复中拒绝新运动和摘要写入，避免部分轨迹覆盖旧数据；BACK 可以退出，隐藏时停止恢复定时器，重新显示时接着恢复。
- 真实启动检查还复现了退出时 `SnapshotStore.valid → save → checkpoint → shutdown` 的 Watchdog。保存时将范围检查和哈希计算合并为一次遍历；退出先处理 FIT 状态，再按需保存一次，已成功保存且无变化的不再写入。丢弃操作仍按原要求清空两个槽。
- 保留 alpha.2 的投影缓存和可见线段绘制优化，未改动 FIT 会话协议与地图资源。

定时器语义依据 [Garmin Timer.Timer](https://developer.garmin.com/connect-iq/api-docs/Toybox/Timer/Timer.html)。这里是前台应用分批处理，非后台服务；不在单个回调内循环排空任务。

## 验证

- **47 项 Monkey C 测试逐项 PASS，摘要 passed=47、failed=0、errors=0。** 覆盖满容量旧格式、末尾校验错误回退、单边空坐标/坏表头、空数据/读取失败、恢复中退出不写入、隐藏后继续、画面绘制、保存校验兼容和退出去重；保留原有定位、记录、菜单与平移回归。测试运行器仍返回 1，异常与原始日志保留。
- 正式包、测试包与独立启动检查包均编译成功；正式包有 41 条动态类型推断警告。4 项 Python 离线测试通过。测试中的完整地图/恢复后地图/双槽存储内存采样分别为 146,112 / 146,176 / 227,840 B，不是长期峰值。
- `tests/smoke/RecoverySmoke.mc` 用独立应用 ID 和专用 Storage 键，装入两份各 800 条（含断段）的合成 v1 摘要；运行真实 `onShow`、`Timer` 回调、地图绘制、checkpoint 和 onStop。
- 最终真实事件检查：**78 次恢复回调，7,812 ms 完成恢复，最慢回调采样 16 ms；800 条记录完整、历史状态、地图绘制 PASS、保存 PASS、正常退出；运行器退出码 0。** 地图绘制后内存采样 **113,968 B**。时间与内存只是本机模拟器样本，非实机峰值或硬实时承诺。
- 初次事件检查已成功进入地图，但在退出时出现上述保存 Watchdog。失败日志与修复后通过日志分别保留，不能把中间成功进入地图当作完整流程通过。
- 旧 v1 校验参考仍用于测试；新的一遍检查/计算与旧结果一致，并继续拒绝无效范围数据。测试包与真实事件检查包均不包含在安装包中。

普通 Monkey C 单元运行器沿用已有异常：逐项 PASS 时仍可能返回 1，保留摘要、原始日志与退出码；真实事件检查单独判断成功。正式编译保留类型推断警告，数量记录在 `build-info.json`。

## 复现真实事件检查

先用 `python tests/smoke/prepare_recovery.py <工作区临时目录>` 生成隔离清单、合成资源和 jungle。使用本地 SDK、FR255 配置与本地私钥编译打印出的 jungle，再按普通应用运行（不加 `/t`）。成功日志必须同时包含 `RECOVERY_SMOKE_DONE`、`RECOVERY_SMOKE_RENDER_PASS`、`RECOVERY_SMOKE_SAVE_PASS`、`RECOVERY_SMOKE_STOPPED`，且运行器返回 0、没有 Error。不要把检查包装到手表。

## 待实机确认

用户在同一份现存长轨迹上覆盖 alpha.3，确认恢复完成、平移、正常退出后重开均无 IQ!。满容量恢复预计需要等待数秒，以实际手表为准。长期稳定性、耗电、完整 FIT 文件内容和 Connect 同步仍未由本次验证覆盖。本版仍为 alpha；操作见 [INSTALL-V03.md](INSTALL-V03.md)。
