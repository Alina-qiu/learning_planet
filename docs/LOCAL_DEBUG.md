# Android 本机联调

最新本机后端包含至068的70份业务迁移；[本轮两个调试包](ANDROID_BUILD.md)已更新。任务APNs默认不启用，也不由本机服务连接Apple发送；iPhone方案见[任务远程提醒](TASK_REMOTE_PUSH.md)。本轮仅重建、校验安装包并启动临时服务，未新增手机业务验收结果。

2026-11-06完成[实际App自动同步时限验证](AUTO_SYNC_DEVICE.md)：本机APK的前台断网恢复及离线强制结束/重开后恢复，均在30秒内自动发出同步请求，奖励和账本未重复。新增可选54322回环探针；普通联调仍将设备54321转发到电脑54321。探针、后端与模拟器已在验证结束后关闭。

2026-11-06修复[登录与家庭加载恢复](ENTRY_RECOVERY.md)：临时服务重启导致旧账号不可用时，App显示中文恢复提示；可重试，或退出后收取新服务中的验证码。最终本机APK已在API36实际完成错误页、双倍字号、重试、退出和重新登录。服务每次启动仍是空数据库，不恢复上次临时家庭；最新包见[构建记录](ANDROID_BUILD.md)。

2026-11-06最终本机APK完成[家长调账明细实际界面验证](WALLET_ADJUSTMENT_DETAILS.md)：孩子账本、真实PIN后原始说明、家庭时区、双倍字号及退出家长模式后的限制通过，余额与账本ID不变。当前后端包含迁移001–066（共68份），最新安装包摘要见[构建说明](ANDROID_BUILD.md)。验证后服务与模拟器已关闭；启动性能及华为鸿蒙4.2/iPhone仍待验收。

2026-11-06完成[离线奖励页实际APK联调](OFFLINE_ECONOMY.md)：API36申请、审批、履约、服务断开/进程重启、三个标签缓存及恢复连接自动刷新通过，账本ID不变。Edge冷启动也改用最多60秒的OPTIONS/204就绪检查并记录耗时；Storage首次超时及第二次Edge超时保留在验证记录中。更新安装包及启动性能限制见[构建说明](ANDROID_BUILD.md)。本轮临时服务与专用模拟器在验证后关闭，重新使用需按下文启动。

2026-11-06补齐[复习记录重开与离线查看](REVIEW_RECORDS.md)，并修复本机Storage启动等待和MinIO初始化竞争。服务仍需看到`LOCAL_BACKEND_READY`才能安装联调；Storage就绪检查上限为60秒，超时会报告最后检查状态并关闭本次服务。最新产物和检查结果见[构建说明](ANDROID_BUILD.md)。

后续同日已完成[实际App离线复习联调](REVIEW_DEVICE_INTEGRATION.md)，并更新两个APK：修复复习输入被后台刷新打断及同步中心展开状态丢失。完整722项Flutter通过；三题离线作答、重启及恢复连接后入账30金币/30XP。以下首次使用流程的719项计数及旧包摘要为此前独立记录，最新产物见[构建说明](ANDROID_BUILD.md)。

2026-11-05：新增可连接电脑本机真实服务的调试包，不需要先创建Supabase云端项目。API36模拟器已经使用原 `main.dart`、实际验证码、家长PIN及加密本机存储，完成登录、建家庭、首次引导、创建任务、孩子开始/完成任务及应用重启。任务获得25金币和20XP，重启后重新同步仍保持相同余额与完成状态。

这是一套临时开发环境。服务每次启动创建空数据库，旧家庭和任务不在新服务中继续使用；应用自身重启不会清空仍在运行的服务数据。服务重启后应在App退出旧账号，再收取新验证码、创建测试家庭。它不替代家庭日常使用的持久后端，也不是脱离电脑即可运行的离线演示包。

## 启动和安装

在项目目录用PowerShell7运行；本机依赖已放在 `D:\learning-planet-tools`，不修改系统PATH。其他机器先按[Storage工具准备](STORAGE_INTEGRATION.md)安装Node24、PG、PostgREST、GoTrue、Storage及MinIO，Android工具见[构建说明](ANDROID_BUILD.md)。首次使用需先缓存Deno入口依赖：

```powershell
& node_modules/deno/deno.exe check --config supabase/functions/worksheet-render/deno.json supabase/functions/worksheet-render/index.ts supabase/functions/permanent-cleanup/index.ts supabase/functions/account-deletion/index.ts
& scripts/local_backend.ps1
```

终端出现 `LOCAL_BACKEND_READY http://127.0.0.1:54321` 后保持运行。在另一个终端构建：

```powershell
& scripts/build_local_android.ps1 -NoPub
```

输出 `build/app/outputs/flutter-apk/app-local-debug.apk` 和对应 `.sha256`。构建脚本备份并恢复普通 `app-debug.apk`，避免公共构建目录导致两个产物混淆。工具目录可通过 `-ToolsRoot` 指定，Node可通过 `-NodeBinary` 指定。

连接开启USB调试的Android测试设备，或启动模拟器，先查看设备序号，再按实际序号执行：

```powershell
& D:/learning-planet-tools/android-sdk/platform-tools/adb.exe devices -l
# 以下示例针对本机专用模拟器；手机应替换设备序号。
& D:/learning-planet-tools/android-sdk/platform-tools/adb.exe -s emulator-5580 reverse tcp:54321 tcp:54321
& D:/learning-planet-tools/android-sdk/platform-tools/adb.exe -s emulator-5580 install -r build/app/outputs/flutter-apk/app-local-debug.apk
```

打开“学习星球·本机”。包名为 `com.learningplanet.learning_planet.local`，与普通包分开安装、保存本机数据。USB断开或设备重启后，可能需要重新执行端口转发；服务仅监听电脑的127.0.0.1，不开放局域网端口。

## 登录及停止

在App输入 `parent@example.test`，点击“发送验证码”，然后在电脑读取本机SMTP收到的验证码：

```powershell
& scripts/local_backend.ps1 -Command mail -Email parent@example.test
```

将8位验证码输入App，继续创建家庭和孩子。首次进入家长功能时输入拟使用的4至6位PIN，再确认设置。其他测试账号也必须以 `@example.test` 结尾；本机SMTP不向真实邮箱投递。

```powershell
& scripts/local_backend.ps1 -Command status
& scripts/local_backend.ps1 -Command stop
```

停止操作等待服务正常关闭；单次会话最长24小时。服务器的本机签名凭据保存在Git忽略的 `.dart_tool/local-backend/credentials.json`，匿名构建配置在 `defines.json`，管理信息在 `control.json`。这些文件无需手工编辑。保持本机凭据文件不变，重启服务时同一联调APK仍可连接；删除或更换凭据后需重新构建。只有匿名key进入APK，管理和服务端密钥不进入构建配置。

## 实现及本轮发现

AppConfig只在显式 `LOCAL_BACKEND=true`、development、debug时接受带端口的 `http://127.0.0.1` 源地址；其他环境继续要求HTTPS。本机模式拒绝外部/LAN地址、URL中的账号密码、路径、查询和片段。Gradle拒绝本机模式的profile/release构建。Android只在debug资源中为127.0.0.1配置HTTP例外，依据[Android网络安全配置](https://developer.android.com/privacy-and-security/security-config)，没有关闭其他主机的HTTPS要求。

服务复用真实Auth、PostgREST、Storage、PG15.19及MinIO；原Deno入口提供PDF生成、永久清理和注销。每分钟运行任务、复习、奖励、导出维护及这三个worker的drain；它是本机调度，不是托管Cron。模型、外部邮件、HMS/APNs和Realtime服务未配置。

实际操作发现任务配置页的保存按钮进入系统导航区域：修复前按钮底边2348px，系统导航栏从2274px开始，点击中心会触发Home。ScheduleEditor增加SafeArea后，底边变为2222px，保存成功并创建了真实任务。新增测试在360×800逻辑尺寸、48px导航留白和键盘场景下核对按钮可见范围及保存结果；修复前无键盘场景实际失败（780超过752），修复后通过。

覆盖率检查还修复了Windows目录映射问题：命令入口和LCOV文件映射现在解析真实路径，避免从ASCII junction运行时跳过检查、却返回成功。新增真实目录别名与CLI失败退出检查；覆盖率统计在与Flutter测试相同的工作目录下执行。

## 验证记录与边界

- 719项Flutter单元/Widget通过，核心覆盖率6312/6976（90.48%，105个源文件）；257个Dart文件格式及完整分析通过。
- 实际Auth的5项集成回归通过，25次Auth、33次业务请求、7封本机邮件。SQL没有变化，382组数据库沿用上一轮结果。
- 本轮增加1条模拟器首次使用/任务流程，包含安装更新、PIN重验、应用强制结束与重启后的同步；使用实际App入口，没有注入任务或余额替身。
- 服务连续两次启动的匿名构建配置摘要相同、运行ID不同；未授权停止请求返回403，公共入口的邮件读取路径返回404。最终APK另行安装，退出旧服务的失效会话后，用新验证码登录进入“创建家庭”。最终包摘要和完整流程所用包的摘要分别保留，见[构建记录](ANDROID_BUILD.md)。
- 模拟器两次debug冷启动记录为7679ms和7456ms；不满足PRD的真机启动性能验收证据，不能以本机联调通过代替性能达标。

结构化记录位于 `build/local_debug_results/`：`ui-flow.json`保存完整任务流程，`backend-lifecycle.json`保存服务重启核对，`final-apk-smoke.json`保存最终安装包登录核对。日志为 `tmp/local-debug-full-tests.log`、`tmp/local-debug-analyze.log`、`tmp/auth-local-debug-regression.log`、`tmp/schedule-safe-area-before.log` 及构建日志。修复前后和完成任务后的截图为 `tmp/local-debug-task-form-bottom.png`、`tmp/local-debug-task-form-fixed.png`、`tmp/local-debug-completed-home.png`、`tmp/local-debug-restored-home.png`。最早的测试滚动夹具未找到按钮，已修正后复现真实边距失败；启动中的UI层级读取也改为拒绝使用旧文件。

本轮仅在API36模拟器验证；华为鸿蒙4.2、iPhone、iOS构建/签名、两台真实设备同步、云端部署和连续家庭试用仍未完成。iPhone不能安装APK，需在Mac环境继续构建与验收。
