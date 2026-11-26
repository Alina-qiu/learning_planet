# Android 本机联调

用电脑启动临时服务，在 Android 模拟器或连接电脑的 Android 手机上打开“学习星球·本机”。工作区已有[本机联调 APK](../build/app/outputs/flutter-apk/app-local-debug.apk)，包名为 `com.learningplanet.learning_planet.local`。[两款安装包的大小和 SHA-256](../build/child-isolation-20261127/DELIVERY.md) · [Android 构建说明](ANDROID_BUILD.md)

服务每次启动创建一个空测试家庭环境。试用期间保持服务运行，关闭或重开 App 都可以继续使用当前数据。服务关闭后，该次临时家庭的数据不会带入下次会话。

## 1. 启动电脑上的服务

在项目目录打开 PowerShell 7。这台电脑的配套工具位于 `D:\learning-planet-tools`。首次试用先缓存三项 Deno 服务的依赖，再启动本机服务。

```powershell
& ./node_modules/deno/deno.exe check --config supabase/functions/worksheet-render/deno.json supabase/functions/worksheet-render/index.ts supabase/functions/permanent-cleanup/index.ts supabase/functions/account-deletion/index.ts
& ./scripts/local_backend.ps1
```

看到 `LOCAL_BACKEND_READY http://127.0.0.1:54321` 后，保持这个窗口打开。服务仅监听电脑回环地址。

## 2. 打开模拟器并安装 APK

在另一个 PowerShell 窗口启动这台电脑已有的 Android 36 模拟器，等待系统桌面出现。使用已开启 USB 调试的手机时，可直接进入下一步。

```powershell
$env:ANDROID_HOME = 'D:/learning-planet-tools/android-sdk'
$env:ANDROID_AVD_HOME = 'D:/learning-planet-tools/avd'
& D:/learning-planet-tools/android-sdk/emulator/emulator.exe -avd learning_planet_api36 -port 5580
```

在项目目录另开终端，确认设备序号，配置端口转发并安装。下面使用 `emulator-5580`，手机使用 `devices -l` 列出的序号。

```powershell
$adb = 'D:/learning-planet-tools/android-sdk/platform-tools/adb.exe'
& $adb devices -l
& $adb -s emulator-5580 reverse tcp:54321 tcp:54321
& $adb -s emulator-5580 install -r ./build/app/outputs/flutter-apk/app-local-debug.apk
```

看到 `Success` 后，在设备上打开“学习星球·本机”。USB 断开或设备重启后，可重新执行上面的 `reverse` 命令。

## 3. 登录并创建测试家庭

在 App 输入 `parent@example.test`，点“发送验证码”。在项目目录的 PowerShell 中读取测试邮件。

```powershell
& ./scripts/local_backend.ps1 -Command mail -Email parent@example.test
```

把 8 位验证码输入 App，点“验证并登录”。在“创建家庭”页填写家庭名称和孩子昵称，核对年级，按需填写教材，点“创建并开始”。看到创建成功回执后，点“查看已创建的档案”进入冒险大厅。首次设置家长 PIN 时，在“更多”中选“进入家长模式”，输入自己的 4 至 6 位数字 PIN，点“验证”，再点“确认设置”。可用其他 `@example.test` 地址试用不同账号，测试邮件由电脑本机接收。

## 4. 结束本次试用

在项目目录运行以下命令。停止后如要再次试用，请重新启动服务，在 App 退出旧账号，以新验证码登录并创建测试家庭。单次服务会话最长 24 小时。

```powershell
& ./scripts/local_backend.ps1 -Command status
& ./scripts/local_backend.ps1 -Command stop
```

## 在其他电脑或代码更新后构建

新检出的源码需要安装仓库的 npm 依赖以取得 Deno。按本机集成环境准备 Node 24、PostgREST、GoTrue、Storage 和 MinIO，以及 Android SDK 和 Flutter。用 Node 24 配套的 npm 执行 `npm ci` 并运行 `flutter pub get`，再按上面的步骤启动服务。[本机服务工具](STORAGE_INTEGRATION.md) · [Android 工具和构建](ANDROID_BUILD.md)

修改客户端代码，或在新工作区生成了本机凭据后，在服务运行时执行下面的命令，生成与该服务配套的 `app-local-debug.apk` 和 `.sha256`。工具目录可通过 `-ToolsRoot` 指定，Node 可通过 `-NodeBinary` 指定。

```powershell
& ./scripts/build_local_android.ps1 -NoPub
```

服务的本机凭据保存在 Git 忽略的 `.dart_tool/local-backend/credentials.json`；公开构建配置保存在 `defines.json`，控制信息保存在 `control.json`。保留本机凭据后，重启服务可以继续使用原联调 APK。普通版 `app-debug.apk` 使用独立包名，适合查看服务配置提示。

## 联调范围

服务启动时依序应用工作区的 78 份迁移至 076。家庭每天从 00:05 起生成复习，开始前更新到期题单，首次开始后固定题目、顺序和标准答案。Android 模拟器已核对两名孩子的离线打卡、重开、重连、余额及错题的归属。[复习操作](REVIEW_AUTO_COMPLETION.md) · [双孩子与设备验证](../build/child-isolation-20261127/DELIVERY.md) · [迁移与恢复](../build/demo-20261127/DELIVERY.md)

模型、外部邮件、APNs 和 Realtime 需另外配置。

<details>
<summary>先前版本的联调记录</summary>

迁移 074 会关闭已停用通道的注册，将待送达的家长消息交回队列。该家庭仍有已启用的 iPhone 时，可以继续接收。该版已通过 411 项数据库检查和覆盖 7 个历史节点的 18 项升级检查。[074 全库检查](../build/acceptance-20261126/database-checks.log) · [074 升级记录](../build/acceptance-20261126/database-upgrade.json)

2026-11-06完成[实际App自动同步时限验证](AUTO_SYNC_DEVICE.md)：本机APK的前台断网恢复及离线强制结束/重开后恢复，均在30秒内自动发出同步请求，奖励和账本未重复。新增可选54322回环探针；普通联调仍将设备54321转发到电脑54321。探针、后端与模拟器已在验证结束后关闭。

2026-11-06修复[登录与家庭加载恢复](ENTRY_RECOVERY.md)：临时服务重启导致旧账号不可用时，App显示中文恢复提示；可重试，或退出后收取新服务中的验证码。最终本机APK已在API36实际完成错误页、双倍字号、重试、退出和重新登录。服务每次启动仍是空数据库，不恢复上次临时家庭；最新包见[构建记录](ANDROID_BUILD.md)。

2026-11-06最终本机APK完成[家长调账明细实际界面验证](WALLET_ADJUSTMENT_DETAILS.md)：孩子账本、真实PIN后原始说明、家庭时区、双倍字号及退出家长模式后的限制通过，余额与账本ID不变。当前后端包含迁移001–066（共68份），最新安装包摘要见[构建说明](ANDROID_BUILD.md)。验证后服务与模拟器已关闭；启动性能及 Android 和 iPhone 仍待验收。

2026-11-06完成[离线奖励页实际APK联调](OFFLINE_ECONOMY.md)：API36申请、审批、履约、服务断开/进程重启、三个标签缓存及恢复连接自动刷新通过，账本ID不变。Edge冷启动也改用最多60秒的OPTIONS/204就绪检查并记录耗时；Storage首次超时及第二次Edge超时保留在验证记录中。更新安装包及启动性能限制见[构建说明](ANDROID_BUILD.md)。本轮临时服务与专用模拟器在验证后关闭，重新使用需按下文启动。

2026-11-06补齐[复习记录重开与离线查看](REVIEW_RECORDS.md)，并修复本机Storage启动等待和MinIO初始化竞争。服务仍需看到`LOCAL_BACKEND_READY`才能安装联调；Storage就绪检查上限为60秒，超时会报告最后检查状态并关闭本次服务。最新产物和检查结果见[构建说明](ANDROID_BUILD.md)。

后续同日已完成[实际App离线复习联调](REVIEW_DEVICE_INTEGRATION.md)，并更新两个APK：修复复习输入被后台刷新打断及同步中心展开状态丢失。完整722项Flutter通过；三题离线作答、重启及恢复连接后入账30金币/30XP。以下首次使用流程的719项计数及旧包摘要为此前独立记录，最新产物见[构建说明](ANDROID_BUILD.md)。

2026-11-05：新增可连接电脑本机真实服务的调试包，不需要先创建Supabase云端项目。API36模拟器已经使用原 `main.dart`、实际验证码、家长PIN及加密本机存储，完成登录、建家庭、首次引导、创建任务、孩子开始/完成任务及应用重启。任务获得25金币和20XP，重启后重新同步仍保持相同余额与完成状态。

## 实现及本轮发现

AppConfig只在显式 `LOCAL_BACKEND=true`、development、debug时接受带端口的 `http://127.0.0.1` 源地址；其他环境继续要求HTTPS。本机模式拒绝外部/LAN地址、URL中的账号密码、路径、查询和片段。Gradle拒绝本机模式的profile/release构建。Android只在debug资源中为127.0.0.1配置HTTP例外，依据[Android网络安全配置](https://developer.android.com/privacy-and-security/security-config)，没有关闭其他主机的HTTPS要求。

服务复用真实Auth、PostgREST、Storage、PG15.19及MinIO；原Deno入口提供PDF生成、永久清理和注销。每分钟运行任务、复习、奖励、导出维护及这三个worker的drain；它是本机调度，不是托管Cron。模型、外部邮件、APNs和Realtime服务未配置。

实际操作发现任务配置页的保存按钮进入系统导航区域：修复前按钮底边2348px，系统导航栏从2274px开始，点击中心会触发Home。ScheduleEditor增加SafeArea后，底边变为2222px，保存成功并创建了真实任务。新增测试在360×800逻辑尺寸、48px导航留白和键盘场景下核对按钮可见范围及保存结果；修复前无键盘场景实际失败（780超过752），修复后通过。

覆盖率检查还修复了Windows目录映射问题：命令入口和LCOV文件映射现在解析真实路径，避免从ASCII junction运行时跳过检查、却返回成功。新增真实目录别名与CLI失败退出检查；覆盖率统计在与Flutter测试相同的工作目录下执行。

## 2026-11-05 首次本机联调记录

- 719项Flutter单元/Widget通过，核心覆盖率6312/6976（90.48%，105个源文件）；257个Dart文件格式及完整分析通过。
- 实际Auth的5项集成回归通过，25次Auth、33次业务请求、7封本机邮件。SQL没有变化，382组数据库沿用上一轮结果。
- 本轮增加1条模拟器首次使用/任务流程，包含安装更新、PIN重验、应用强制结束与重启后的同步；使用实际App入口，没有注入任务或余额替身。
- 服务连续两次启动的匿名构建配置摘要相同、运行ID不同；未授权停止请求返回403，公共入口的邮件读取路径返回404。最终APK另行安装，退出旧服务的失效会话后，用新验证码登录进入“创建家庭”。最终包摘要和完整流程所用包的摘要分别保留，见[构建记录](ANDROID_BUILD.md)。
- 模拟器两次debug冷启动记录为7679ms和7456ms；不满足PRD的真机启动性能验收证据，不能以本机联调通过代替性能达标。

结构化记录位于 `build/local_debug_results/`：`ui-flow.json`保存完整任务流程，`backend-lifecycle.json`保存服务重启核对，`final-apk-smoke.json`保存最终安装包登录核对。日志为 `tmp/local-debug-full-tests.log`、`tmp/local-debug-analyze.log`、`tmp/auth-local-debug-regression.log`、`tmp/schedule-safe-area-before.log` 及构建日志。修复前后和完成任务后的截图为 `tmp/local-debug-task-form-bottom.png`、`tmp/local-debug-task-form-fixed.png`、`tmp/local-debug-completed-home.png`、`tmp/local-debug-restored-home.png`。最早的测试滚动夹具未找到按钮，已修正后复现真实边距失败；启动中的UI层级读取也改为拒绝使用旧文件。

本轮仅在API36模拟器验证；Android 和 iPhone、iOS构建/签名、两台真实设备同步、云端部署和连续家庭试用仍未完成。iPhone不能安装APK，需在Mac环境继续构建与验收。

</details>
