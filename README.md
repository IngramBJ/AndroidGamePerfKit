# AndroidGamePerfKit

AndroidGamePerfKit 是一个面向 Android 游戏的轻量性能测试工具包，重点兼容 Windows PowerShell 与 ADB。日常使用采用运行时配置：工具自动读取设备信息和前台游戏，测试时直接在控制台输入时长、坐标、标记点等参数，不需要手工编辑JSON。

当前版本：1.6.0。设备序列号、厂商、型号、分辨率和前台游戏包名可自动识别；常用用例参数在启动测试时输入并记住上一次值。每轮自动生成可双击查看的离线HTML报告，并按游戏、用例、时间和设备归档。工具还能一键扫描历史结果并生成适合Excel、AI和人工查看的轻量批量汇总包。`.state/runtime-config.json` 由工具自动维护，只用于把运行时参数传给采集核心，测试人员不需要打开或修改它。

SurfaceFlinger 直方图解析同时兼容 AOSP 的 `presentToPresentHistogram` 和华为/HarmonyOS 的 `present2present histogram` 格式。

Perfetto作为可选的短时诊断模式集成。控制台选择“Perfetto专项诊断”，或在战斗、首次加载、冷启动用例中按提示启用。Trace会保存为 `raw/perfetto/trace.perfetto-trace` 并自动进入结果ZIP；工具不自动下载或运行trace processor。

## 一体化菜单（推荐）

日常测试不需要再手工输入PowerShell命令。推荐双击工具根目录中的无闪窗入口：

```text
Start-AndroidGamePerfKit.vbs
```

长稳坐标和战斗时长校准使用独立入口，不会开始性能采集：

```text
Start-Longrun-Calibrator.vbs
```

首次使用先按 `S`，把目标游戏切到手机前台后让工具自动识别设备和包名，再输入便于辨认的游戏显示名称并确认目标FPS。战斗、首次加载、内存恢复、长稳、省电、后台竞争和低存储会在开始前询问本轮参数；高风险操作仍要求二次确认。

长稳测试会现场询问总分钟数、每局秒数、是否自动重开，以及每个点击步骤的名称、X/Y坐标和点击后等待毫秒数。输入完成后会自动记住，下次可直接复用或重新设置。

工具包默认采用已验证的 GamePerf Lite 思路：

- SurfaceFlinger timestats：FPS、帧间隔分布和长帧；
- Android `/proc`：进程/关键 Unity 线程 CPU、RSS、系统可用内存、Swap、CPU 频率与 thermal zone；
- `dumpsys` 与 logcat：电池、电源、温控、PSS、存储、启动时间和异常证据；
- Perfetto 不作为普通测试的必需项，避免重型 Trace 和 Unity ATrace marker 洪泛。

测试或离线自检运行期间按 `Esc` 会安全终止当前项目、结束其子进程、按需尝试cleanup并返回主菜单。短按也会被记录，不需要一直按住；每个新任务开始前会清除历史按键状态，因此Esc不会延迟到下一项才生效。`Ctrl+C` 不再由工具捕获，保持PowerShell默认行为：直接关闭整个工具；这种关闭方式可能来不及恢复省电模式、电池模拟、占位文件或后台采集器，因此正常中止请使用 `Esc`。发行包仅保留VBS入口，不再提供CMD，所以启动时不会出现批处理黑窗闪烁。

VBS启动后会创建一个正常可见的PowerShell窗口，并读取本机运行时配置。菜单模式还会尝试通过ADB进行只读设备识别（设备列表、厂商、型号、分辨率和前台包名）；不会启动测试、创建结果目录或修改手机状态。只有选择具体测试项目后才进入相应用例。

## 运行要求

- Windows PowerShell 5.1 或 PowerShell 7；
- Android Platform Tools，`adb.exe` 已加入 PATH；
- 手机已开启 USB 调试并授权；
- 普通采集不需要 root；
- Perfetto诊断需要Android 10/API 29或更高版本，并且设备提供`perfetto`命令；
- `storage-5gb` 需要设备 shell 提供 `fallocate`。工具不会自动退化到会产生大量真实写入的 `dd`。

如果使用推荐的VBS双击入口，不需要修改执行策略。只有直接从 PowerShell 调用 `.ps1` 时，才建议在当前窗口临时允许脚本：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 打包给他人使用（纯净发行版）

不要直接压缩自己正在使用的工具目录，因为其中可能已有 `results` 和 `.state/runtime-config.json`。在工具根目录打开PowerShell，执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-CleanRelease.ps1
```

脚本会先运行离线自检，然后生成 `AndroidGamePerfKit-v<版本>-clean.zip`。发行包自动排除全部测试结果、校准结果、运行时设备/游戏会话、项目专用配置、已有ZIP和Trace，只保留通用示例配置及全部测试能力。生成后可将这个 `-clean.zip` 上传到网盘、企业聊天、GitHub Release或内部制品库。接收方解压后双击 `Start-AndroidGamePerfKit.vbs`，按 `S` 识别自己的设备和游戏即可。

## 三步开始

1. 连接并授权手机，打开目标游戏，让它停留在前台。
2. 双击 `Start-AndroidGamePerfKit.vbs`，按 `S` 自动识别设备和前台游戏，并输入游戏显示名称与目标FPS。
3. 选择测试用例，根据控制台问题输入本轮时长、时间点、坐标或后台包名，然后开始测试。

每次结果固定输出到：

```text
results/<游戏名称>/<case>/<yyyyMMdd-HHmmss>_<设备标签>/
```

同级还会生成：

```text
results/<游戏名称>/<case>/<yyyyMMdd-HHmmss>_<设备标签>.zip
```

## 一键批量汇总与填表

主菜单选择 `[17] 一键汇总全部测试`。该功能不要求连接手机，只递归读取 `results` 中每轮测试的 `metadata.json` 和 `summary.json`，不会读取或复制大型logcat、dumpsys、`samples.csv`、Perfetto Trace。完成后自动打开批量HTML报告，并输出：

```text
batch-reports/<yyyyMMdd-HHmmss>/
├─ batch-summary.csv       Excel或测试记录表的数据源，每次测试一行
├─ batch-summary.json      适合程序和AI批量分析
├─ batch-report.html       可搜索的本地总览
└─ anomalies.txt           失败、警告和待复核记录

batch-reports/<yyyyMMdd-HHmmss>.zip
```

CSV/JSON包含游戏、包名、设备、用例、时间、测试状态、数据质量、平均FPS、P95/P99、长帧、CPU、UnityMain、RSS、可用内存、Swap、温度、Perfetto状态、自动判定、警告和原结果路径。需要AI填表时，通常只需发送这个小型ZIP和目标Excel模板；只有异常RUN需要进一步定位时，再补充对应的完整结果ZIP。

高级命令行用法：

```powershell
.\AndroidGamePerfKit.ps1 -Command batch
```

也可扫描另一个结果目录：

```powershell
.\AndroidGamePerfKit.ps1 -Command batch -ResultsRoot D:\ArchivedGamePerfResults
```

## 新设备怎么接入

连接新设备后按 `S`。工具自动读取序列号、厂商、型号和分辨率，并更新报告设备标签；旧设备序列号不会阻止单台新设备接入。然后运行预检，检查 RAM、存储、电池、thermalservice、SurfaceFlinger timestats、`fallocate`、`unzip` 和 `awk`。

预检中“游戏 PID 不存在”只会给出警告，因为冷启动用例本来就允许游戏尚未运行。包不存在或 `awk` 不可用则会阻止正式执行。

## 新游戏怎么接入

先把新游戏切到手机前台，再按 `S`。工具会依次探测 Activity 与 Window 服务，兼容 `topResumedActivity`、`mResumedActivity`、`mCurrentFocus`、`mFocusedApp` 和顶部Activity等常见OEM格式；Activity继续自动解析。若系统没有向ADB暴露前台包名，控制台会让你直接输入。游戏显示名称和目标FPS也在同一流程中输入。显示名称会成为结果目录的第一层，例如 `results/Demo-Game/...`。长稳坐标、后台应用、测试时长等都在选择对应测试时设置。

`configs` 目录仅保留给直接调用PowerShell或CI的高级兼容模式，双击菜单不依赖人工JSON配置。

## 用例目录

查看所有入口：

```powershell
.\AndroidGamePerfKit.ps1 -Command list
```

### battle-60s

稳定战斗基线或 60 秒压力窗口。运行前进入目标战斗并等待加载结束。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case battle-60s -Config .\configs\my-game.json
```

可临时覆盖时长：

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case battle-60s -DurationSec 90 -Config .\configs\my-game.json
```

### longrun

菜单会现场询问总分钟数、每局秒数和点击坐标。自动化关闭时只采集、由人操作；开启时按本轮输入的 `battleSeconds` 和点击步骤循环。点击步骤可从校准JSON/TXT导入、粘贴一行坐标序列或手工输入。导入时会比较当前分辨率和rotation，状态不一致默认拒绝复用。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case longrun -Config .\configs\my-game.json
```

手机端采样在独立 shell 进程中执行；活动运行状态记录在 `.state/active-run.json`。即使上轮异常退出，也可先运行统一 cleanup，移除残留采集器。

如果点击序列第1步就是“开战”，请选择“开始测试后立即执行第1步”。执行时序为“点击第1步开战 → 等待每局战斗秒数 → 执行其余结算/进入关卡步骤 → 再次点击第1步”。如果点击序列只包含战斗结束后的操作，则关闭该选项，工具会沿用“先等待当前战斗结束 → 执行全部步骤”的模式。启动前会逐项显示名称、坐标和等待时间。

### 长稳校准助手

双击 `Start-Longrun-Calibrator.vbs`。该工具独立于正式性能采集，只在校准阶段使用ADB读取手机触摸事件，不会在手机创建文件。校准时会询问第1步是否为“开战”：选择是时，应从开战按钮页面开始，按“开战 → 结算/继续 → 进入下一关”形成完整循环；该模式会随JSON/TXT导入主工具。

坐标模式会探测同时提供 `ABS_MT_POSITION_X/Y` 的触摸设备。每一步按提示直接点击手机按钮，工具把原始触摸范围换算成当前逻辑分辨率下的 `input tap X Y` 坐标；OEM禁止读取触摸事件时自动提供手工输入回退。

计时支持两种模式：

- Enter标记：看到战斗开始和结算界面时各按一次Enter，适用于任何需要战斗内操作的游戏；
- 手机两次点击：点击开始按钮后等待，战斗结束再点击结算按钮，适用于战斗过程中不需要触屏的自动战斗游戏。

建议测3～5局。工具按“最长一局 + max(5秒, 10%)”生成安全的 `recommendedBattleSeconds`。输出位于：

```text
Longrun-Calibrator/calibration-results/<游戏>/<时间_设备>/
├─ longrun-calibration.json
├─ coordinates.txt
├─ calibration-log.txt
├─ taps.csv
└─ battle-times.csv
```

`calibration-log.txt` 会在每次记录坐标或完成一局计时后立即更新，其中 `StepCopy=` 是单步坐标，`CurrentPasteLine=` 是截至当前可直接粘贴到主工具的完整序列；即使中途退出，已完成的记录也会保留。完整结束后，`coordinates.txt` 中的 `PasteLine=` 也可直接粘贴到主工具；还可在长稳测试中导入 `longrun-calibration.json`，同时带入点击步骤和建议单局时间。校准结果只存在电脑，纯净打包时会自动排除。

### memory-recovery

先记录 T0 PSS，采集一段战斗，再提示回到约定的主页/恢复状态，并在 0/30/60/180 秒记录 PSS 节点。额外输出 `pss-nodes.csv` 与每个节点的原始 `dumpsys meminfo`。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case memory-recovery -Config .\configs\my-game.json
```

### battery-saver

同一稳定战斗中执行 OFF 阶段和 ON 阶段。流程为：模拟拔电、确认 OFF、采集、写入 `low_power=1`、再次读取 `dumpsys power`、确认真实 ON 后继续采集。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case battery-saver -Config .\configs\my-game.json
```

关键原则：`settings get global low_power` 不是成功证据。若 `dumpsys power` 不能确认 ON，本轮直接失败并恢复，不会把结果记为正式省电样本。

### storage-5gb

在菜单中输入目标剩余空间和安全下限后，使用 `/data/local/tmp` 的稀疏/预分配占位文件调整 `/data` 可用空间，然后执行冷启动、主页可操作和首战加载流程。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case storage-5gb -Config .\configs\my-game.json
```

安全约束：

- 目标空间不得低于 `minimumSafeFreeGb`；
- 只使用名称以 `gpk_storage_filler_` 开头的明确文件；
- `fallocate` 不可用时停止，不使用 `dd` 写入数十 GB；
- `finally`/cleanup 会删除占位文件并重新记录存储状态。

建议先完成正常剩余空间的 `cold-start-first-battle` 基线，再运行低存储用例，比较中位数。单次 5 GB 样本不应被直接定义为存储临界值。

### first-load

30 秒轻量“首次 vs 第二次”窗口。默认第 6 秒提示首次触发，第 18 秒提示同目标第二次触发；提示时同时记录 Windows UTC 和 Android uptime。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case first-load -Config .\configs\my-game.json
```

运行前应重启游戏进程并进入目标场景，但不要提前打开单位预览或播放目标特效。该用例适合首次单位、特效、技能、材质或资源初始化。它不启用 Unity atrace marker。

### manual-marker

通用人工事件窗口。开始前可输入多个提示秒数，用于切场、结算、召唤、技能峰值等。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case manual-marker -Config .\configs\my-game.json
```

### background-pressure

开始前输入后台应用包名、稳定等待时间和MemAvailable目标。工具启动这些后台包后记录MemAvailable，再执行标准战斗窗口；若当前MemAvailable高于目标，会把本轮标成“仅后台竞争”，不会冒充2GB/4GB真机。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case background-pressure -Config .\configs\my-game.json
```

这里测试的是“当前设备 + 当前可用内存 + 后台竞争”，不是改变物理 RAM。2 GB/4 GB 容量覆盖仍应使用对应真机或相同 AVD 配置，并且模拟器绝对 FPS 不应与真机横向归因。

### cold-start-first-battle

自动解析 Activity，`force-stop` 后用 `am start -W` 冷启动，保存 Android Activity 启动结果；随后由测试者在主页完全可操作、首战完全加载时按 Enter 打标。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case cold-start-first-battle -Config .\configs\my-game.json
```

`am start -W` 的 `TotalTime` 不等于 Unity 主页完全可操作时间，因此二者分开保留。

### perfetto-trace

5～300秒的专项诊断窗口。菜单中选择综合、CPU/卡顿或首次加载/I/O类型，开始后在手机复现目标操作。Perfetto在设备后台按固定时长录制，因此不会依赖ADB对Ctrl+C的传递。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case perfetto-trace -DurationSec 30 -Perfetto -PerfettoProfile cpu-jank -PerfettoDurationSec 30 -Config .\configs\my-game.json
```

也可以给已有短用例追加Perfetto，例如：

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case first-load -DurationSec 45 -Perfetto -PerfettoProfile load-io -PerfettoDurationSec 45 -Config .\configs\my-game.json
```

可选类型为`balanced`、`cpu-jank`和`load-io`。普通Lite测试默认不录制；长稳不建议全程开启Perfetto。

## 非交互模式

CI 或无人值守场景可加 `-NonInteractive`。需要人工确认的主页/首战时间会改用配置的固定等待值，并在 marker 名称中标记为 `assumed`，数据质量不等同于人工确认。

```powershell
.\AndroidGamePerfKit.ps1 -Command run -Case cold-start-first-battle -NonInteractive -Config .\configs\my-game.json
```

## 统一结果内容

每轮测试结束后，直接打开结果目录中的 `report.html`，或在主菜单选择 `[16] 打开最新自动测试报告`。它会离线展示游戏、包名、设备、用例、数据质量、FPS、P95/P99、严重长帧、CPU、内存、温度和Perfetto采集状态，并给出基础风险提示。普通结果不必发送给AI；只有需要解释Perfetto线程时间线、复杂logcat、跨版本回归或异常根因时，再提供ZIP做深入分析。

每个结果目录至少包含：

```text
metadata.json            配置、设备标签、包名、工具版本、主机信息
summary.json             FPS/帧分布、CPU、UnityMain、RSS、内存、温度、告警
samples.csv              统一时间序列
report.html              可双击查看的离线自动测试报告
raw/
  device-samples.tsv     手机端原始轻量采样
  markers.csv            人工/自动时间点
  logcat.txt              本轮 logcat
  surfaceflinger-final.txt
  start/                  开始时 dumpsys/SurfaceFlinger/gfxinfo/内存/存储
  end/                    结束时同口径快照
  preflight/              能力探测原始证据
  perfetto/               启用时包含Trace、实际配置和采集日志
```

用例会按需要追加 `pss-nodes.csv`、`am-start-W.txt`、省电前后 SurfaceFlinger、占位后存储等证据。

`summary.json` 的 `dataQuality` 规则保守：没有 SurfaceFlinger 或有效采样时为 `partial`。SurfaceFlinger 输出存在 OEM 格式差异；解析器无法可靠识别直方图时，原始文件仍保留，P95/P99 会留空而不是推测。

## cleanup 与异常恢复

正常执行无论成功或失败都会进入统一恢复：

- 恢复运行前 `low_power`；
- 仅在本轮模拟拔电时执行 `dumpsys battery reset`；
- 删除本轮低存储占位文件；
- 停止手机端轻量采样器；
- 停止本轮Perfetto、拉取Trace并删除设备端临时配置和Trace；
- 关闭 SurfaceFlinger timestats；
- 停止本轮由工具启动的后台竞争应用。

若 PowerShell 被强制关闭、电脑注销或 USB 中断，重新连接后执行：

```powershell
.\AndroidGamePerfKit.ps1 -Command cleanup -Config .\configs\my-game.json
```

cleanup 是幂等的，可以重复执行。它只删除 `/data/local/tmp/gpk_*` 与 `/data/misc/perfetto-traces/gpk_*.perfetto-trace` 命名空间和状态文件中记录的明确目标，不清应用数据，也不删除游戏资源。

## 测试口径建议

- 平均 FPS 必须与 P95、P99、>100 ms 数量/比例一起判断；
- 目标 30 FPS 时，平均值接近 30 仍可能包含严重离散长帧；
- 首次加载重点比较第一次与第二次，并结合 logcat/I/O/PSS/主线程证据；
- 长稳应比较首末窗口和全程 RSS/温度趋势，不能只看全程平均；
- OEM 能力缺失要记录为覆盖缺口，不应把缺失指标补成 0；
- 工具给出的阈值应被视为项目经验线，不是所有 Android 游戏的行业统一标准。

## 离线自检

不连接设备也可以检查 PowerShell 语法、配置读取和 SurfaceFlinger 示例解析：

```powershell
.\tests\Run-SmokeTests.ps1
```
