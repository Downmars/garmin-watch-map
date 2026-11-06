# 构建环境搭建

这份文档把「从零到生成第一个 `.prg`」需要的东西列全，以及常见的坑。

---

## 1. Python 与 Pillow

```bat
python --version
pip install pillow
```

`make_city_pack.py` 和 `make_icon_final.py` 都依赖 Pillow。

---

## 2. JDK 17

Connect IQ 的编译器 `monkeyc` 是 Java 程序。

- 下载：[Adoptium Temurin 17](https://adoptium.net/temurin/releases/?version=17)
- 或者用 `winget install EclipseAdoptium.Temurin.17.JDK`

装完确认：

```bat
java -version
```

> 如果你不想装到系统里，也可以把 JDK 解压到 `tools\jdk17\jdk-17.0.2\`，
> `build-city.bat` 会自动把它加到 PATH。

---

## 3. Connect IQ SDK

1. 打开 <https://developer.garmin.com/connect-iq/sdk/>
2. 下载 **SDK Manager**（Windows 版）
3. 运行 SDK Manager，安装最新的 **Connect IQ SDK 9.x**
4. 安装完成后，SDK 一般在：
   ```
   %APPDATA%\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.3.0-2026-10-20-95888f262
   ```

把这一层目录（**包含 `bin\monkeyc.bat` 的那层**）设为环境变量：

```bat
set CIQ_SDK=%APPDATA%\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.3.0-2026-10-20-95888f262
```

### 验证 SDK 可用

```bat
"%CIQ_SDK%\bin\monkeyc.bat" --version
```

---

## 4. 开发者密钥

1. 打开 <https://developer.garmin.com/connect-iq/developer-key/>
2. 用 Garmin 账号登录，生成一个开发者密钥
3. 下载 `developer_key.der`，放到仓库根目录

```bat
set CIQ_KEY=D:\path\to\garmin-map\developer_key.der
```

> ⚠️ `developer_key.der` / `.pem` 是**私钥**，不要提交到仓库（已在 `.gitignore` 里）。

---

## 5. 跑第一次构建

```bat
build-city.bat --name test --lat 36.10 --lon 120.43 --km 4 --zoom 15
```

`--km 4` 只覆盖 4 公里，下载量小，适合先验证环境。

成功的话最后会打印：

```
完成: dist\test.prg (X.X MB)
```

---

## 常见错误

| 现象 | 原因 / 解决 |
|---|---|
| `'java' is not recognized` | JDK 没装或在 PATH 里；装 JDK 17 或放到 `tools\jdk17\` |
| `A valid 'project.manifest' property was not defined` | `monkey.jungle` 格式不对，必须只有 `base.barrelPath` / `base.resourcePath` / `project.manifest` 三行 |
| `Unknown app type: watchapp` | SDK 9.x 里 `type` 要写 `watch-app`（带连字符），不是 `watchapp` |
| `A bitmap resource matching the provided launcher icon can't be found` | `resources/drawables/` 下必须有 `launcher.png`，且 `drawables.xml` 里有 `<bitmap id="LauncherIcon" .../>` |
| `Invalid explicit typing of a local variable` | Monkey C 局部变量不能写显式类型（`var x as Number` ✗），只能靠推断 |
| `Cannot override ... getInitialView with a different return type` | SDK 9.x 的签名是 `as [Views] or [Views, InputDelegates]` |
| 瓦片下载大量失败 | OSM 限流；降低 `--km`，或隔几分钟再跑（脚本有 3 次重试 + 3 个镜像） |
| 编译超大包时 Java 内存不足 | 脚本已设 `-Xmx4g`；机器内存小就把 `--km` 调小 |

---

## 编译产物在哪

```
dist\<name>.prg
```

`.prg` 就是安装包，复制到手表 `GARMIN\Apps\` 即可，不需要上架 Connect IQ Store。
