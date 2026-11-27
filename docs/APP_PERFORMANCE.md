# 启动、任务列表与本机完成反馈验证

根据 2026-11-26 更新的 PRD 第 9 节，首页需在冷启动后 6 秒内显示孩子、任务和余额。主要列表首屏 <1.5 秒，任务完成反馈 <500 毫秒。页面应适应系统字号，儿童正文不小于 14sp。

## 已登录家庭有 75 道错题时的冷启动

测量从发出冷启动指令开始，到实际屏幕上同时出现孩子昵称、服务端已确认的余额、当天任务及其操作按钮为止。家庭目录通过权限和删除核验后，相同目录可以跳过重复写入。首页同时请求任务、余额和家庭日期时，共用一次受访问权限保护的本机快照，离线操作按队列顺序投影到任务。金币和 XP 使用已经确认的数值。[本轮完整首页实测](../build/trial-acceptance-20261127/ready-home.json) · [离线与权限回归](../test/offline_tasks_test.dart)

## 2026-11-27 从首页打开错题本

在 Android 10 模拟器的 Release 包中，已登录家庭有 75 道错题。三次从首页点击“错题本与拼音复习”，在点击后只采一张接近时限的屏幕图，分别在 **1.483、1.473、1.466 秒**内采到第一道题。随后三次均能点开同一题的详情。计时开始于电脑发出触摸指令前，结束于截图到达电脑后。这些数值是题名已经出现的上界。[时限截图与操作结果](../build/trial-acceptance-20261127/optimized-deadline/results.json)

同一包高频采集整屏截图时，题名首次可见的上界增至 2.13–2.67 秒。本轮覆盖本机在线错题列表，其他主要列表与真机仍需各自计时。[逐帧记录与请求数](../build/trial-acceptance-20261127/optimized-catalog.json)

## 2026-11-26 已登录家庭的完整首页

**中文 OCR 修复后的 Release 在 Android 10 模拟器上，一次安装后的五次常规冷启动全部在 6 秒内出现完整可操作首页，每轮重装后的三次冷启动有两次达到目标。** 两组均使用相同的 x86_64 AOT APK 和本机测试签名。Android 和 iPhone 实机仍待测量。[本机验收索引](../build/acceptance-20261126/DELIVERY.md) · [本轮 APK 指纹](../build/acceptance-20261126/release-ocrfix-package.json)

### 一次安装后持续使用

测试家庭已有一项已完成任务、一项待开始任务，钱包已确认 25 金币和 20 XP。连续五次均保留安装和家庭数据，强制结束进程后重新启动，核对首页上的已确认余额、当日任务和操作按钮。完整首页观测上界中位数为 **5.630 秒**，最慢为 **5.979 秒**。[服务端任务、钱包与流水](../build/acceptance-20261126/release-completed-task.json)

| 常规使用 | 第 1 次 | 第 2 次 | 第 3 次 | 第 4 次 | 第 5 次 |
|---|---:|---:|---:|---:|---:|
| 系统首帧 | 2.229 秒 | 2.289 秒 | 2.226 秒 | 2.098 秒 | 2.153 秒 |
| 完整首页观测上界 | [5.630 秒](../build/acceptance-20261126/release-H1.json) | [5.694 秒](../build/acceptance-20261126/release-H2.json) | [5.979 秒](../build/acceptance-20261126/release-H3.json) | [3.733 秒](../build/acceptance-20261126/release-H4.json) | [5.216 秒](../build/acceptance-20261126/release-H5.json) |

### 每轮重装并在线暖机后

每轮保留本机账号数据，重新安装同包并在线确认家庭快照，再强制结束进程和启动。完整可操作首页的观测上界依次为 8.022、5.595、5.903 秒。首轮在 7.491 秒时仍未显示完整首页。

| 最终 Release | 系统首帧 | 同轮任务快照 HTTP 200 | 最后一张尚未完整的截图开始 | 第一张完整截图结束 |
|---|---:|---:|---:|---:|
| [第 1 次](../build/acceptance-20261126/release-G1.json) | 3,992 ms | 8,452.49 ms | 7,490.82 ms | 8,022.10 ms |
| [第 2 次](../build/acceptance-20261126/release-G2.json) | 2,180 ms | 5,985.23 ms | 5,055.23 ms | 5,594.90 ms |
| [第 3 次](../build/acceptance-20261126/release-G3.json) | 2,152 ms | 6,241.62 ms | 5,365.59 ms | 5,903.16 ms |

三轮首次显示的任务和余额来自该家庭启动前已在线确认的加密快照，各轮新的任务快照 HTTP 200 均出现在第一张完整截图之后。同包另做了首页操作验证，点按“开始”后界面显示“暂停”，对应任务在服务端进入进行中，另一项任务仍待开始。钱包余额与奖励流水保持原值。[本轮首页操作回执](../build/acceptance-20261126/release-home-action-after-ocr.json)

### 完成任务的保存提示

在同一安装包完成一项普通任务后，首页钱包显示 25 金币和 20 XP，服务端分别写入一条奖励流水。此次从主机发出点按命令到首次截到“完成记录已保存本机”用了 1.37 秒。ADB 点按在 0.335 秒前已返回，1.07 秒时仍未看到成功提示。这次采样超过 500 毫秒目标，尚需定位本机保存和界面显示各自占用的时间。[奖励与截图记录](../build/acceptance-20261126/release-completed-task.json)

### 观测方式与构建对照

在 Android 10（API 29、x86_64、SwiftShader）模拟器上，逐次确认进程消失，从主机发出启动命令开始计时。普通入口恢复凭据并检查账号、家庭和孩子的访问范围。连续两张截图同时显示大厅标题、孩子昵称、已确认余额、当日任务及其操作按钮时，取第一张匹配截图的结束时间作为上界。昵称匹配允许头像加载后发生的位置变化。首页可在当轮服务端请求完成前使用此前已经确认、仍可访问的加密快照。[常规冷启动示例](../build/acceptance-20261126/release-H1.json) · [重装后冷启动示例](../build/acceptance-20261126/release-G1.json)

| 构建与环境 | 系统首帧 | 完整首页观测 |
|---|---:|---|
| Profile C，启动、家庭权限和任务缓存读取并行优化 | 4.895、4.120、3.944 秒 | 8.816–9.352、6.672–7.211、7.182–7.717 秒。首轮期间主机同时在编译。[第 1 次](../build/acceptance-20261126/profile-C1.json) · [第 2 次](../build/acceptance-20261126/profile-C2.json) · [第 3 次](../build/acceptance-20261126/profile-C3.json) |
| Profile E，绑定就绪后即开始初始化，加入家庭目录收窄检查 | 6.205、10.500 秒 | 10.863–11.396、14.925–15.458 秒。两轮均与主机大型 Release 编译重叠。[第 1 次](../build/acceptance-20261126/profile-E1.json) · [第 2 次](../build/acceptance-20261126/profile-E2.json) |
| Release C，相同 Flutter 代码、x86_64 AOT、开启 R8、本机测试签名 | 2.064、2.125 秒 | 连续采样在 4.587–5.126 秒间出现完整首页。第二次在 5.939 秒前首次截图即匹配。六秒定点采样只能给出上界。[构建指纹](../build/acceptance-20261126/release-c-package.json) · [连续采样](../build/acceptance-20261126/release-RC1.json) · [定点采样](../build/acceptance-20261126/release-RC2.json) |
| 上一修订 Release F，修复中文 OCR 前 | 0.807、0.876、0.928 秒 | 完整首页上界为 2.334、2.409、2.111 秒。[第 1 次](../build/acceptance-20261126/release-F1.json) · [第 2 次](../build/acceptance-20261126/release-F2.json) · [第 3 次](../build/acceptance-20261126/release-F3.json) · [当时的首页操作回执](../build/acceptance-20261126/release-home-action.json) |

上述两组共八次验收使用同一修订版 APK，SHA-256 为 `e237998a4bb147a3a3565f5f2684c27904297a8290b700ad9d9604815f74c780`。已逐文件核对 220 个构建输入，包括 Flutter 源码、Android 配置及依赖清单。[本轮源码核对](../build/acceptance-20261126/package-source-match-ocrfix.json) · [本轮构建记录](../build/acceptance-20261126/release-ocrfix-package.json)

## 2026-11-24 已登录家庭的首页读取

提交 `c861fbb` 在 Android 10 模拟器上冷启动一个在线家庭，孩子与钱包出现的中位观测区间为 11.565–12.246 秒，系统首帧为 4.945 秒。该轮未单独标记任务卡的出现时间。[六次交错冷启动记录](../build/acceptance-20261124-startup/online-profile-ab.json)

| 测量对象 | 条件 | 结果 |
|---|---|---|
| 查询钱包和家庭时区所需的数据 | Windows 真实加密 SQLite，经 Drift 工作 isolate 读取同一份含 1,000 条任务的快照。预热后新旧查询交替执行 20 对 | 完整快照 512,351 字节，去掉任务数组的摘要 313 字节。单次读取中位耗时从 5.822 毫秒降到 2.152 毫秒。任务列表仍会读出全部任务并合并本机待同步操作。 |
| 接受邀请后读取家庭目录 | 同一邮箱验证码会话、GoTrue、PostgreSQL 15.19 和 PostgREST 16.5。每个 HTTP 请求都附加 120 毫秒延迟，预热后新旧交替各 5 次 | 一般家庭所需请求从 3 次减至 2 次（含接受邀请），中位耗时从 382 降至 265 毫秒。多页家庭仍会依次翻页。 |

这两组计时分别覆盖缓存读取和远端家庭目录，完整首页还需数据库权限检查、余额加载和画面渲染。整机冷启动和任务反馈按设备、构建模式与观测方式单独记录。[本机逐次测量与交付记录](../build/acceptance-20261124-startup/DELIVERY.md)

## 生产入口启动测量

`scripts/measure_android_startup.ps1`默认构建`lib/main.dart`的profile APK，不传入后端配置；安装到所选测试设备，固定采样5次。每次先强制停止并确认旧进程消失，再执行`am start -W`；首次安装后的样本单独标识，超时样本保留，只有Status ok且LaunchState COLD的TotalTime纳入首帧统计。它不会挑选最快一次代替整组结果。

```powershell
pwsh -File scripts/measure_android_startup.ps1 -UseChinaMirror
# 同时采集原生与Dart的固定阶段耗时
pwsh -File scripts/measure_android_startup.ps1 -TraceStartup -UseChinaMirror
```

默认只操作专用`emulator-5580`；传入`-DeviceId`可在指定的专用测试手机上运行。脚本覆盖该设备上的同包名安装并强制停止进程，不能拿已有家庭数据的日常安装做此无后端场景。`-Samples`允许1–10次；`-Mode debug`用于对照，不作为正式性能依据。`-UseExistingApk`跳过构建时，报告明确记录`entrypoint_built_this_run=false`：只核对构建模式，调用者需先确认它由生产入口生成，不能拿应用级测试入口的APK替代。

每组输出独立的`build/startup_results/startup-<mode>-<UTC时间>.json`和每次启动的系统原始结果，记录APK摘要、字节数、设备/API、全部样本、超时数量及有效样本中位数/最小/最大值。中断时保留已完成样本且`collection_complete=false`。启动后再次读取语义树确认配置页可见；`screen_verified_at_ms`包含ADB和UIAutomator开销，只是读取时的观察值，**不是首页就绪时间或TTFD**。不保留语义树内容或完整系统日志。

`-TraceStartup`通过编译定义`MEASURE_STARTUP=true`开启固定阶段计时：Android的Activity创建、插件注册、自定义通道注册和首个Flutter画面；Dart的绑定、首帧、初始化整体以及通知/数据库/凭据/Supabase/远程提醒阶段。默认关闭，release构建即使传入该定义也不输出；普通交付debug包不开启。只记录阶段名、耗时和ok/error，不记录异常正文、身份、题目、密钥或地址，不上传云端。计时观察器失败不影响原返回值和异常。

阶段使用各自的单调时钟；Android毫秒转换为微秒统一存储，分辨率仍为毫秒。阶段彼此嵌套，不应相加，也不能直接拼成跨原生/Dart的统一时间轴。Dart首帧指`StartupGate`首次画面，初始化完成也不表示账号家庭和首页网络数据已经加载完成。

2026-11-05首次profile基线（生产入口，未开启阶段计时）：5次COLD首帧依次4557、4269、3701、4424、3910ms，中位数4269ms，范围3701–4557ms，全部确认配置页可见，无超时。APK为138362808字节，SHA-256为`41649c02993cf996493d806edcc9029686e8f76789b2ac6d4abe9c47f12e599b`，报告为`startup-profile-20261104T205134596Z.json`。此前debug包13.282秒的观察包含资源解包/JIT等开销；构建模式不同，这组结果不能声称是代码优化幅度，也不能替代指定真机上的完整首页验收。

测量口径依据：[Flutter建议在真机profile模式诊断性能](https://docs.flutter.dev/perf/ui-performance)、[Android区分首次显示与完整可用时间](https://developer.android.com/topic/performance/issues/launch-time)。所有本机报告保持`qualifies_for_prd_acceptance=false`。

同日加入阶段计时后再固定采样5次，首帧中位数4038ms（3937–4304ms），报告为`startup-profile-20261104T205541755Z.json`。它把初始化等待缩小到通知链，因此继续拆分该链并预先设定采样3次；未改初始化顺序、清理逻辑或权限行为。细分组首帧3715/4105/3993ms，无超时，报告为`startup-profile-20261104T205946584Z.json`；计时APK为138362808字节，SHA-256 `8e2701c9223c8f582937a814892de556cdc58f3ed033e9ed523d3165d5924548`。

| 细分阶段 | 3次中位数 | 观察范围 |
|---|---:|---:|
| Android插件注册 | 51ms | 42–60ms |
| 时区加载 | 15.752ms | 13.281–16.408ms |
| 首次通知插件调用 | 1495.877ms | 1417.761–1539.269ms |
| 原生任务提醒清理 | 76.047ms | 50.793–87.157ms |
| 插件通知清理 | 5.491ms | 2.531–8.865ms |
| Dart初始化整体 | 1588.934ms | 1554.461–1692.885ms |

通知调用计时包含MethodChannel往返、平台线程排队及方法执行，不能直接认定插件方法本身耗费约1.5秒CPU；需要平台跟踪或指定真机进一步区分。当前数据不支持以跳过时区校验或旧提醒清理作为优化。此次交付是可复现测量与定位证据，**尚未证明启动性能达标或实现了性能提升**。

### Android方法采样与Flutter时间线

同日使用上述生产入口profile包（SHA-256 `8e2701c9223c8f582937a814892de556cdc58f3ed033e9ed523d3165d5924548`），在同一专用模拟器分别采集一次Android方法采样和一次Flutter启动时间线。没有改业务代码、跳过清理或关闭渲染功能。这两次带跟踪的运行单独保存，不计入前述13个profile基线/阶段样本；采样会改变线程调度，不能作为优化前后对照。

- Android使用`am start -W --start-profiler /data/local/tmp/lp-startup-20261105.trace --sampling 1000 --clock-type dual -n com.learningplanet.learning_planet/.MainActivity`，随后`am profile stop`并拉取文件。ART v3双时钟记录没有溢出，共5019条；只计算成对闭合的调用，133个结束时仍开放的栈帧排除。采样推导的区间不是每次方法真实进入/退出的精确时点。
- 本次`FlutterLocalNotificationsPlugin.initialize`区间约5.262ms墙钟/3.004ms线程CPU；`FlutterJNI.nativeSurfaceCreated`约1172.158ms墙钟/0.463ms线程CPU。前者不支持“通知插件初始化消耗1.5秒CPU”的判断，后者指向原生绘图表面创建期间的等待，尚未归因到指定硬件或具体引擎缺陷。本次系统首帧5732ms、Dart通知调用158.065ms；变化说明跟踪影响时序，不表示实现优化。
- `flutter run --profile --no-pub --no-dds --trace-startup --use-application-binary=build/app/outputs/flutter-apk/app-profile.apk -d emulator-5580`保存另一轮引擎时间线：从引擎进入到首帧构建839.958ms、首帧光栅化2760.136ms。时间线包含程序快照读取435.245ms和首帧提交502.615ms等嵌套区间，不能相加或等同进程冷启动TTID。原始时间线可在Flutter/Perfetto工具中继续检查。

本机证据位于`build/startup_results/method-trace-20261105/`和`build/startup_results/flutter-trace-20261105/`。该轮仍只验证无后端配置页；保留默认通知初始化与账号恢复前清理，后续应在 Android 和 iPhone 及真实首页上继续定位。方法采样解释参照[Android方法跟踪说明](https://developer.android.com/studio/profile/traceview)和[ART记录格式实现](https://android.googlesource.com/platform/art/+/002aca7141e7baf488b02f330b307f059c47a84d/tools/dmtracedump/tracedump.cc)。

## 实现

- 首页与任务管理均使用`SliverList.builder`；任务管理在[安全区域修复](TASK_ACCESSIBILITY.md)中从`ListView.builder`改为与同步提示同页滚动。保留既有日期过滤和排序，按任务ID跟踪重排，按孩子隔离滚动位置。数据仍为完整缓存，优化的是构建和布局，不是后端分页。下文历史性能测量仍对应各自当时的版本，不代表改动后的重新测量。
- 普通任务完成后，在持久队列提交成功时显示两秒提示“完成记录已保存本机，奖励待同步确认”。网络回复不阻塞此提示，金币/XP仍只显示服务端确认值；失败走原错误提示。
- 任务优先级和成长分类文字改为14sp，遵守系统字号。新增4项Widget回归覆盖1,000条数据的按需构建、末尾可达、完成后重排、保存失败和360px/两倍字号。

## Android应用级测试

`integration_test/task_flow_test.dart`使用真实Flutter页面、Android插件、KeyStore和SQLite3MultipleCiphers；账号/家庭为合成数据，网络适配器故意不回复。测试不连接Supabase、不调用模型或发送通知。

每次在应用支持目录的`integration-fixtures/task-flow-*`独立目录建库，并为安全存储使用独立键名。验证完成命令先落盘、余额不提前增加、数据库关闭重开后同一命令和任务投影仍在、文件无明文标题。结束时仅清理当次临时库和密钥，不读取或修改正常业务数据库。

首次安装测试依赖后，启动专用模拟器并运行：

```powershell
pwsh -File scripts/test_android_app.ps1 -UseChinaMirror
```

脚本默认设备`emulator-5580`，使用profile构建；可用`-DeviceId`和`-DeviceLabel`指定专用测试手机。环境变量只在当前进程设置并恢复。测试入口与普通APP包名相同，会替换该设备上的安装入口，须使用专用测试设备。测试结束后用`build_android.ps1 -NoPub -UseChinaMirror`恢复普通调试产物，不能把测试入口APK当作用户安装包。

输出为`build/integration_results/task_flow.json`与两张PNG。JSON区分预置数据首页就绪、任务页首次可操作、任务完成提示和滚动帧统计；截图转换在计时完成后执行。首屏计时包含测试轮询开销，记录为观察值，不以这些单次结果设立CI性能门槛。

2026-11-05本机实测通过（1条应用级场景；测试框架另外报告tearDownAll）：

| 观察项 | 单次结果 | 口径 |
|---|---:|---|
| 预置数据首页钱包出现 | 643.364ms | `pumpWidget`至已确认钱包文字出现；不是完整冷启动 |
| 任务页首个可操作画面 | 56.412ms | 点击“任务管理”至完成按钮可命中 |
| 本机完成提示 | 109.164ms | 点击完成至持久提交成功提示出现，远端仍未回复 |
| 滚动构建平均/P90 | 2.226 / 3.846ms | 10次拖动，21个采集帧 |
| 滚动绘制平均/P90 | 12.685 / 22.370ms | SwiftShader；3帧超过测试工具绘制预算 |

真实原生加密库和安全存储调用、持久队列重开、同命令ID、任务完成投影、服务端余额不提前增加均通过。1倍/2倍字号PNG已人工查看，列表和操作可显示；2倍字号下标题使用AppBar既有省略行为，列表允许滚动。该单次采样仍有绘制超时，不宣称流畅度或PRD性能已全部达标。

### Android10补充观测

2026-11-05，同一任务场景在API29 AOSP/WHPX/SwiftShader上通过；报告保存为`build/integration_results/task-flow-api29-swiftshader/task_flow.json`，根目录`task_flow.json`同步为此次记录。上表API36数据及截图已保留至`task-flow-api36-original/`，不能把两个环境混为一个样本。

API29预置首页就绪1322.807ms、任务页244.973ms、本机完成反馈217.254ms；滚动构建平均/P90为4.653/10.033ms，绘制平均/P90为32.833/47.776ms，1个构建帧和20个绘制帧超预算。功能断言及1倍/2倍字号截图通过，但uniform链接错误仍在，不代表图形/性能验收。

同日host后端的任务运行曾在图形缓冲区通信中白屏，未通过；失败及同APK配置页对照见[Android10图形记录](ANDROID_GRAPHICS.md)。脚本增加默认180秒驱动阶段上限及按运行区分的失败截图目录；不覆盖编译或驱动开始前的应用启动等待。

## 验收边界

这组历史测量使用 Windows/WHPX 上的 Android API 36 x86_64 模拟器，配置为 Emulator 37.2.13、SwiftShader、4 核和 2 GB 内存。测试使用预置家庭数据，JSON 中记录为 `qualifies_for_prd_acceptance=false`。

尚需在指定两类手机上，以profile模式分别测量正常冷启动、真实数据主列表、完成反馈、断网/恢复、后台/重启和大字号。iOS还需macOS/Xcode编译签名；模拟器上的KeyStore和加密库验证不能代替真机安全存储及备份验收。

方法依据：[Flutter集成测试](https://docs.flutter.dev/cookbook/testing/integration/introduction)、[性能测量](https://docs.flutter.dev/cookbook/testing/integration/profiling)、[真机profile模式建议](https://docs.flutter.dev/perf/ui-performance)。
