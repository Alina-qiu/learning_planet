# 当前需求覆盖与验收状态

核对日期为 2026-11-27。本文汇总当前交付范围及验收进度。[历次开发记录](PROGRESS.md)

**Android 本地联调版已可交付。** iOS 已完成未签名编译及指定模拟器测试。Android 本地闹钟、iPhone APNs 推送及两端性能仍需真机验证，云端部署和连续家庭试用尚待完成。

首页和任务页的错题入口共用首次读取。等待「今日复习」摘要时，孩子可以先打开错题，摘要返回后仍可在原位置点到同一题。切换孩子会清除旧筛选和待执行的搜索。本机试用服务也会按保留期限清理诊断回执、统计与家长配置记录。[本次交付与逐次实测](../build/catalog-acceptance-20261127/DELIVERY.md) · [错题本操作](QUESTION_CATALOG_PAGINATION.md) · [本机试用](LOCAL_DEBUG.md)

本轮改进了已登录家庭冷启动和错题列表。家庭权限、删除记录及在线目录核验完成后，如果目录与加密数据库完全相同且无需清理，首页可以直接使用核验结果。错题本打开时只加载当前标签。持久试用服务可以跨日运行，App 关闭后仍会生成每日复习并处理注销。[首页与列表性能](APP_PERFORMANCE.md) · [错题分页](QUESTION_CATALOG_PAGINATION.md) · [本机试用](LOCAL_DEBUG.md) · [本轮验收记录](../build/trial-acceptance-20261127/DELIVERY.md)

提交 `a34bcbe` 的完整首页在标准 Android API 36 模拟器连续 3 次冷启动中均于 6 秒内出现。Android 10 模拟器共有 4 次尝试，3 次达到目标，1 次系统启动超时。iOS 18.5 模拟器通过了任务流和四种中文 OCR 场景。iPhone 后台系统注入的第一条静默任务提醒在 35 秒内未取得应用回执。家长提醒的注册、续订和发送现已支持可变长度的 APNs 设备令牌。[首页逐次测量](APP_PERFORMANCE.md) · [iOS 任务与 OCR](https://github.com/Alina-qiu/learning_planet/actions/runs/45961743243) · [后台回执](https://github.com/Alina-qiu/learning_planet/actions/runs/45961743413) · [家长提醒](PARENT_REMOTE_PUSH.md)

提交 `9cfc243` 的 Android 联调包支持逐张校对本机草稿、按张同意上传，家长可以从家庭概览直接确认指定孩子的标准答案。测试中，家长补正一道题后，该孩子的待办清零，另一名孩子的两题仍在。Android 10 模拟器连续三次强停重开 Release 版，已登录家庭的完整首页分别在 3.70、5.01、4.48 秒内可操作。Windows 和 Linux 各通过 924 项 Flutter 测试。[安装包](ANDROID_BUILD.md) · [本机验收](../build/mobile-acceptance-20261127/DELIVERY.md) · [确认操作与截图](../build/mobile-acceptance-20261127/overview-device/REPORT.md)

提交 `5d423b0` 修复了 iPhone 模拟器 OCR 测试服务发现。常规 CI 的 11 项作业及双端同步的 3 项作业均通过。iPhone 离线重启并重连后，首次成功取得新快照的请求在 0.514 秒时发出，账本只记了一次奖励。独立的系统推送测试在后台注入后 35 秒内没有观察到 App 接收回调，真机 APNs 仍待验证。[双端同步](https://github.com/Alina-qiu/learning_planet/actions/runs/45944731154) · [常规 CI](https://github.com/Alina-qiu/learning_planet/actions/runs/45944731173) · [系统推送记录](https://github.com/Alina-qiu/learning_planet/actions/runs/45944731177)

现在可以用同一个本机安装包分几天试用同一测试家庭。在项目目录执行 `& ./scripts/local_backend.ps1 -KeepData` 后，关闭服务再用同一命令启动，家庭账号、孩子、账本和私有文件会保留。[本机运行步骤](LOCAL_DEBUG.md) · [两份调试包的用途](ANDROID_BUILD.md) · [双孩子与首页启动实测](../build/child-isolation-20261127/DELIVERY.md)

全新 Android API 36 模拟器安装本机联调 APK 后，已走通收取验证码、首次登录、创建家庭与孩子、进入首页及首次设置家长 PIN。启动服务的窗口会打印能在本机直接使用的收件和停止命令。[首次试用图解](../build/iphone-isolation-20261127/entry/首次试用.md) · [本机安装指引](LOCAL_DEBUG.md)

本机 PostgreSQL 15 已通过 422 项数据库检查。81 份迁移覆盖 10 个有数据的历史节点，24 项升级检查通过。升级至 078 后，家长可在家庭概览看到孩子此前提交的待确认错题数量，点击即可核对。未提交、清理中、已确认的错题均不占待办。[家庭概览](FAMILY_OVERVIEW.md) · [本机运行步骤](LOCAL_DEBUG.md) · [数据库与版本升级](../scripts/test_database_upgrade.mjs)

基线提交 `e178b18` 在 Android 10 模拟器上完成了邮箱验证码登录和一次实际中文印刷图识别，孩子校对并保存后，联网刷新仍显示“待家长确认”。[基线联调版首页](../build/acceptance-20261126/android-local-debug-home.json) · [中文识别与保存](../build/acceptance-20261126/android-release-ocr.json)

需求依据为工作区[PRD V1.1](../学习星球_产品需求文档_PRD.docx)，当前 SHA-256 为 `b2c364196610dfc8038ca00477f2e82f3643f95c29f04b678f14722c352e2173`。第 5.4 节规定依次通过 1、3、7、30 天四次复测后掌握，第 6.5 节规定当日复习开始前更新选题，第 9 节采用 6 秒首页目标。

## 当前开发进度

可在本机联调的核心流程包括邮箱登录与家庭设置、离线任务和计时、金币与 XP、奖励兑换、多图错题逐张校对、自动复习、拼音练习、PDF 组卷和学习报告。服务端已接入可替换的 AI 和推送入口，真实模型与手机通知的效果仍待验证。

### 双孩子共用设备

Android API 36 模拟器中的两个测试孩子各有一项任务、一道错题和不同的余额。第一个孩子断网完成任务，在第二个孩子的首页结束进程并离线重开后，两人的错题仍可分别查看。恢复连接时，第一个孩子的余额从 100 升至 115 金币、XP 从 10 升至 22；第二个孩子仍为 220 金币、40 XP。服务端仅写入一条金币及一条 XP 奖励记录。[本机账本](../build/child-isolation-20261127/server-final.json)

选择另一个孩子后，切换中的页面会收起原孩子的入口。Android 中断的选图由原账号、家庭、孩子及录入模式恢复。家长授权被服务端拒绝后，周报及其依据会同时收起。导出页滑到底后可以在系统任务栏上方点击“生成并保存 ZIP”。[切换孩子](../test/child_switch_isolation_test.dart) · [恢复图片](../test/image_import_test.dart) · [周报权限](../test/ai_weekly_report_test.dart) · [导出](../test/child_export_test.dart)

### 任务与启动

达到最低时长前，孩子连续点“完成”只会看到一条当前错误提示。计时达标并保存时，完成提示会取代旧错误。切换孩子、账号或离开页面会收起该提示；页面内其他操作的撤销消息仍然可用。[首页任务回归](../test/home_task_actions_test.dart) · [反馈及无障碍回归](../test/task_feedback_test.dart)

首页查询金币余额和家庭日期时，加密数据库只返回任务快照的摘要。正常规模的家庭在接受邀请后，可一次读取家庭和孩子；超过 1,000 行时按创建时间和 ID 继续读取。登录凭据迁移和家庭时区规则也可在本次启动中复用。账号切换、访问撤销与注销仍需通过原有检查。[家庭目录](../lib/features/auth_family/data/family_repository.dart) · [缓存与凭据回归](../test/local_security_test.dart) · [分项测量](APP_PERFORMANCE.md)

孩子已看到的任务卡、“开始”按钮和余额会在后台同步等待网络响应时保留。API 29 模拟器上将成功的快照响应延迟 9.745 秒，期间三次读取都能看到两张卡片和余额。点击第一张的“开始”，本机显示“暂停”，此时服务端仍记录两项待开始。恢复传输后服务端确认操作，第二项仍待办，钱包与账本均无变化。[最终 APK 实测](../build/acceptance-20261124/android-home-slow-sync.json) · [首页同步回归](../test/home_sync_refresh_test.dart) · [安装包](ANDROID_BUILD.md)

断网冷启动时，如果已恢复的过期会话刷新失败，首次家庭查询可复用同一次失败结果。恢复连接或手动刷新会重新访问服务端。账号注销、权限拒绝、切换账号仍会阻止读取原家庭。[登录回归](../test/family_entry_refresh_test.dart) · [Android 调试包](ANDROID_BUILD.md)

iPhone 的任务和家长提醒在权限回调和主线程等待结束时复查安静时段。基线提交 `e178b18` 通过 10 项常规检查，包括 iOS SDK 27.2 未签名 Debug 和 Release 编译、三组 iOS 模拟器。该版 Android 和 iPhone 同家庭同步也已验证。[基线 CI](https://github.com/Alina-qiu/learning_planet/actions/runs/45789891932) · [基线双端验收](https://github.com/Alina-qiu/learning_planet/actions/runs/45789891764) · [本分支最新检查](https://github.com/Alina-qiu/learning_planet/pull/1/checks) · [iPhone 提醒规则](TASK_REMOTE_PUSH.md)

账号注销状态检查较慢时，首页的定时轮询会等待当前检查返回。之前每 30 秒新发起的检查可能使初次结果失效，导致离线首页持续转圈。应用回到前台仍会立即核查注销状态，服务端确认已受理注销后，应用立即遮住家庭数据。[入口回归用例](../test/entry_recovery_test.dart)

同一测试家庭在 Android API 36、API 29 分别登录。API 36 断网作答 3 题，API 29 在同步前仍显示原状态。恢复连接后，两端显示同一条已完成的复习任务；3 道题分别记为正确、错误、正确，各有 1 次作答记录，金币和 XP 分别增加 30。零题孩子没有生成任务。下表区分本机服务、模拟器与目标真机的验收范围。

复习任务按家庭时区从 00:05 起生成。迁移 075 允许未开始的当日题单跟随新增、归档和答案修订更新，开始时锁定当次题目。题单清空时，家庭概览、学习报告和自主开始率会剔除该任务。离线作答与服务端的题目版本冲突时，原答题保留供核对，采用更新后的题目后可重新作答。419 项数据库检查和 8 个历史节点的 20 项升级检查已通过。[并发与核账](../scripts/test_review_refresh_cases.mjs) · [升级回归](../scripts/test_database_upgrade.mjs)

注销含有大量图片的账号时，已核验的文件会随批次保存在数据库。执行超时后，新进程可缩小批次并接着处理。孩子清理和账号注销都已用真实本机对象存储验证过期租约、迟到确认和文件归属隔离。[删除联调](PRIVACY_INTEGRATION.md)

冒险大厅支持直接开始、暂停、继续和完成普通任务。孩子可以在任务卡看到有效时长；最低时长、离线待确认和自动复习的逐题判定继续由相应的任务流程处理。

设备校时后，重新打开应用首次联网会核对之前未收到回执的操作。同一账号刷新令牌时，客户端现在保留正在执行的账号状态和家庭概览查询。迁移 071 向新版客户端返回家长 PIN 的服务器时间，手机用包含休眠时间的单调时钟计算剩余授权，退回前台也会检查期限。

应用在数据库写入期间被系统终止后，重开会由 SQLite 回滚未提交的写入，再校验加密库并恢复已提交的数据。已用保留原数据库和回滚日志的 API 36 模拟器覆盖安装验证，进入原家庭后仍有 35 金币和原账本记录。

<details>
<summary>此前版本的构建和回归记录</summary>

上一版在 Windows 通过全部 842 项 Flutter 测试和静态分析，核心行覆盖率 90.62%。本机 PostgreSQL 通过 405 项检查和 14 项有数据升级检查。PostgREST 16.2 处理了 99 次实际 HTTP 请求，覆盖新版 PIN、旧客户端兼容和设备校时后重放原命令。

提交 `1d68c28` 的十项远程检查全部通过，包括 847 项 Flutter 测试、409 项数据库检查、14 项迁移升级、9 项备份恢复、iOS SDK 27.2 未签名 Debug 和 Release 编译，以及三组 iPhone/iPad 模拟器测试。macOS 也已执行 35 项原生提醒策略检查。[构建和测试](https://github.com/Alina-qiu/learning_planet/actions/runs/45074628662) · [后续提交与检查](https://github.com/Alina-qiu/learning_planet/pull/1)

上一版修复了三处用户流程。

- 家长手工录入或编辑错题时，保存失败可在原页重试。数据库用同一次保存的请求标识识别重复提交，服务器已落库而手机未收到回执时也只保存一次。服务端提示 PIN 授权已过期时，编辑页会遮住草稿，家长可当场重新验证并继续编辑。错题编辑区也会避开系统底部与侧边导航栏，窄屏和双倍字号均可滚动到保存按钮。
- 练习卷历史、预览和下载使用数据库时间判断 30 天保留期。手机日期提前或落后均按服务器结果处理。读取失败时可重试。
- 周期任务按家庭日历日校验日期跨度，支持从开始日选择完整周期、将开始日改回，以及输入中文逗号分隔的自定义日期。

旧版提交 `a5dcade` 的本机验证也包含核心行覆盖率 90.79%、96 次实际 PostgREST 请求、14 项历史升级检查，以及 3 项客户端和 4 组服务端 PDF 联调。这版用迁移 069 判断练习卷期限，用迁移 070 恢复错题保存。当前可用的安装包与运行条件见[Android 构建记录](ANDROID_BUILD.md)。

本轮修复[奖励页大字号和窄窗口适配](ECONOMY_ACCESSIBILITY.md)：摘要与待确认请求随页面滚动，避开系统安全区域；新增5项，完整823项Flutter测试通过。用户已确认暂时没有可连接的测试手机，真机验收继续保留，未用窗口模拟结果替代。

本轮扩展[iOS兼容性检查](IOS_COMPATIBILITY.md)：保留iOS18.5/iPhone，增加iOS26.2/iPhone与iPad，分别验证同一原生离线任务流程并保存产物。提交`5bee57f`的[运行43354956838](https://github.com/Alina-qiu/learning_planet/actions/runs/43354956838)中，iOS26.2/iPad原生流程通过，整轮八项通过；iOS18.5首页等待失败，iPhone26.2重新启动超时。iOS27及完整真机兼容性仍未验收，不能将矩阵配置完成当作运行通过。

后续提交`ac530b1`的[运行43359140376](https://github.com/Alina-qiu/learning_planet/actions/runs/43359140376)八项CI通过，iOS26.2/iPhone首次完整通过。iOS18.5业务断言通过但结束辅助截图超时使整项失败；iPad则停在家庭加载页，原20秒等待在49.5秒返回时失败。随后修复辅助截图覆盖驱动结果的问题，并为Debug功能测试采用90秒等待、记录每次等待与最长刷新耗时；Profile/Release仍为20秒。该轮尚无同一提交三目标全通过记录，修复后的结果见下段；合成数据Debug结果不用于PRD性能验收。

此前提交`d27a4a6`的[运行43362271398](https://github.com/Alina-qiu/learning_planet/actions/runs/43362271398)十项CI全部通过，iOS18.5/iPhone、iOS26.2/iPhone及iPad原生离线任务首次同轮全部通过；5项辅助诊断回归也通过。已检查三个目标的原始报告和两倍字体截图，Debug合成数据仍不作为PRD性能验收。

提交`cef66a3`的[运行43365693965](https://github.com/Alina-qiu/learning_planet/actions/runs/43365693965)十项CI全部通过；已完成Xcode27.2的完整Debug/Release编译，两个实际产物均确认SDK为`iphoneos27.2`、Xcode构建号`27B52`，各解析16份隐私清单。完整OCR和生产入口保留；三个既有模拟器再次完整通过，报告及两倍字体截图已复核。这是未签名编译及指定模拟器功能证据，不能替代iOS27运行。

提交`645076f`的[iOS27.2运行尝试](https://github.com/Alina-qiu/learning_planet/actions/runs/43368916879/job/131699841767)在环境准备阶段失败：预装运行时仅arm64，Apple下载服务明确返回指定通用运行时不可用；已有Rosetta探测通过。没有编译或启动该目标，也没有执行业务断言。当前OCR依赖仍不支持Apple Silicon模拟器，iOS27运行验收保留为阻塞项。常规CI继续执行三个可用目标及SDK27完整构建；保留手工运行的诊断脚本和五项选择回归，不对已确认不可用的运行时反复自动下载。详情见[兼容性记录](IOS_COMPATIBILITY.md)。

</details>

## 技术栈与交付方式

| 层 | 当前实现 | 边界 |
|---|---|---|
| 客户端 | Flutter 3.47.4 / Dart 3.13.3、Riverpod | Android可构建；[iOS Debug/Release](IOS_BUILD.md)已通过CI未签名编译及资源检查，尚未签名或真机运行 |
| 本机数据 | Drift、SQLite3MultipleCiphers、安全存储 | 有原生模拟器加密检查；真机备份/锁屏/物理清理待验收 |
| 后端 | Supabase PostgreSQL/Auth/Storage，81 份迁移至 079 | 本机 PostgreSQL 15.19、GoTrue、PostgREST、Storage 和 MinIO 已联调，托管项目待准备 |
| 服务端任务 | Deno Edge Functions、SQL维护任务 | PDF、删除、AI与推送入口已实现；托管Cron、监控告警尚待运行确认 |
| 图片与OCR | image_picker、端侧图像处理、ML Kit中文识别 | 不通过云OCR识别；真实教材、手写、公式和设备权限待验证 |
| PDF与拼音 | 服务端确定性PDF、中文字体、拼音规则库；客户端读取原始字节预览和导出 | 已有本机真实PDF证据；系统打印/分享及两端一致性待验收 |
| 通知 | Android 本地任务闹钟与家长前台提醒；iOS收到后校验的APNs任务/家长消息 | [iPhone优先安静方案](TASK_REMOTE_PUSH.md)已接入；Swift通知策略已通过；真实供应商和目标手机待验证 |
| AI | 可替换服务端网关、结构化输出、审核与预算/隐私控制 | 测试使用可控响应；没有真实模型质量、费用与保留策略验收 |

依赖声明见[pubspec.yaml](../pubspec.yaml)、[package.json](../package.json)，架构细节见[ARCHITECTURE.md](ARCHITECTURE.md)。本机工具安装在`D:\learning-planet-tools`，未修改系统PATH。

本机 `app-local-debug.apk` 通过 ADB 端口转发连接电脑服务，支持 Android 模拟器和通过 USB 连接的手机。启动时使用 `-KeepData` 可以连续使用同一家庭，省略该参数会创建一次性测试环境。普通 `app-debug.apk` 在未配置后端时展示配置提示。[安装包](ANDROID_BUILD.md) · [启动服务与模拟器](LOCAL_DEBUG.md)

## 已确认的产品规则

| 项目 | 当前采用规则 |
|---|---|
| 支持平台 | Android 10 及以上，iOS 当前及前两个主版本，平板保持可用 |
| 后端准备 | 用户暂未准备Supabase项目，先交付本地调试包 |
| 多图导入 | 一次选择多张错题，每张独立校对保存，最多10张 |
| 孩子录入 | 家长确认标准答案后，才进入可获得奖励的复习 |
| 掌握判定 | 完成1/3/7/30天复测周期，不采用连续两次正确即掌握 |
| 复习置信度 | 孩子的作答把握，与OCR识别可信度分别保存 |
| 每日复习题集 | 家庭时间 00:05 生成。首次开始前按当天最新到期情况更新，最多 10 题；首次开始后锁定题目、顺序与判题依据。 |

## 编号功能需求

表内“本机证据”说明已经检查过的范围，不能替代最后一列的验收。

| PRD项 | 已有实现与可定位证据 | 当前剩余范围 |
|---|---|---|
| ACC-01 邮箱登录/跨端家庭 | [验证码](EMAIL_LOGIN.md)、[真实Auth联调](AUTH_INTEGRATION.md)，`lib/features/auth_family` | 外部收信、云端及Android/iOS同账号实机同步 |
| ACC-02 多孩子隔离 | Android API 36 已核对首页、余额、错题及奖励归属。iPhone 的配对作业在在线、离线两种情况下从正式页面切换两名孩子。[Android 实测](../build/child-isolation-20261127/DELIVERY.md) · [iPhone 配对流程](../integration_test/cross_device_sync_test.dart) | 目标手机与家庭试用 |
| ACC-03 离线查看/打卡/同步 | Android 断开本机服务后打卡、切换孩子、结束进程并离线重开。重连后自动同步给原孩子。[离线任务](OFFLINE_TASKS.md) · [双孩子验收](../build/child-isolation-20261127/DELIVERY.md) | 无线网络切换、系统后台调度及目标手机 |
| ACC-04 服务端判奖 | [数据库测试](../scripts/test_database.mjs)、[复习结算](REVIEW_AUTO_COMPLETION.md)，服务器时间/唯一回执 | 云端时钟与真实设备改时场景 |
| ACC-05 导出/注销 | [孩子导出](CHILD_DATA_EXPORT.md)、[真实删除集成](PRIVACY_INTEGRATION.md) | 托管清理Cron、真实承诺期限及外部已导出副本说明的实机验收 |
| TSK-01 重复规则/家庭时区 | [任务系统](TASK_SYSTEM.md)、[家庭时区](FAMILY_TIMEZONE.md)，迁移064 | 两端时区切换、夏令时及跨日长期运行 |
| TSK-02 时间窗/有效计时 | [任务系统](TASK_SYSTEM.md)、[计时纠正](TASK_TIME_CORRECTIONS.md) | 真机后台/重启/时钟行为 |
| TSK-03 三类优先级 | `lib/features/tasks/domain/task_priority.dart`、[完成反馈](TASK_COMPLETION_FEEDBACK.md) | 孩子理解与读屏试用 |
| TSK-04 状态转换/禁止孩子撤销 | `lib/features/tasks/domain/task_state_machine.dart`、[实际任务流程](LOCAL_DEBUG.md) | 双端并发操作实机验收 |
| TSK-05 家长补签或纠正 | 补签及[计时纠正](TASK_TIME_CORRECTIONS.md)有原因、审计和版本检查 | 是否还包含撤回误完成，用户尚未答复；不能把这一扩展视为已实现 |
| TSK-06 智能提醒 | [本地通知](LOCAL_NOTIFICATIONS.md)、[原生授权场景](../build/integration_results/notifications-granted.json) | 用户选择[收到后复查的远程方案](TASK_REMOTE_PUSH.md)，已实现且Swift策略/构建通过，真实供应商与真机仍待验证；可能漏提醒，不能保证系统最终展示时刻 |
| TSK-07 每日自动复习 | 每个孩子每天最多一项，首次开始前更新到期清单，开始后冻结。本机持续运行的服务在家庭当地 00:05:58 自动生成任务，零题兄弟及另一时区的孩子按各自资格处理。[空闲调度与选题](REVIEW_AUTO_COMPLETION.md) · [逐题结算](../build/ac11-device-acceptance/summary.json) | 托管环境家庭时区调度及真机运行待验证 |
| ERR-01 拍照/多图/裁剪 | [OCR管理](OCR_MANAGEMENT.md)、[原生多选报告](../build/integration_results/image-import-native.json)、[中断草稿](OCR_INTERRUPTION.md) | 真机相机权限、系统回收期间选择恢复及真实图片 |
| ERR-02 逐字段校对 | 多图中每张错题可先在本机校对，重新打开可接着修改。提交时逐张征得同意，孩子录入的标准答案由家长确认。[操作说明](OCR_FIELD_CORRECTION.md) · [更换图片后重新校对](OCR_SOURCE_CHANGES.md) | 真实教材的复杂版式与识别质量仍待评测 |
| ERR-03 学科/知识点 | [题目目录](QUESTION_CATALOG_PAGINATION.md)、`lib/features/wrong_questions/presentation/review_question_editor.dart` | 双设备编辑与真实数据规模 |
| ERR-04 错误原因 | 六类人工标签，`test/error_reason_tags_test.dart`、迁移035 | 真机输入与家庭使用 |
| ERR-05 相似题检索/生成 | [相似题](SIMILAR_QUESTIONS.md)，AI标识、隐藏答案、审核采纳 | 真实模型、复杂题意、答案质量和费用评测 |
| ERR-06 掌握/复测/稍后提醒 | [提醒](REVIEW_REMINDERS.md)、[把握程度](REVIEW_ANSWER_CONFIDENCE.md)、[阶段奖励](REVIEW_MILESTONE_REWARDS.md) | 真实1/3/7/30天周期、两设备与后台提醒 |
| ERR-07 混合组卷/排序/开关 | [PDF集成](PDF_INTEGRATION.md)、[组卷适配](WORKSHEET_ACCESSIBILITY.md)，冻结顺序与同请求重试 | 两端实际操作、打印与分享 |
| ERR-08 A4预览导出 | [真实PDF集成](PDF_INTEGRATION.md)、`scripts/fixtures/worksheet_client_test.dart` | iPhone 系统导出、实物打印与真实教材字体质量 |

## 其余明确范围

| PRD章节 | 实现与证据 | 剩余验收/范围说明 |
|---|---|---|
| 3 / 3.1 角色、PIN与二次确认 | [家庭成员与权限](FAMILY_MEMBERS.md)、[PIN设置测试](../test/parent_pin_settings_test.dart)，服务端PIN与敏感操作确认 | 真机安全存储、两端权限失效；生物识别为可选方案，当前使用PIN |
| 5.1 首次使用 | [孩子档案与引导](CHILD_PROFILE_ONBOARDING.md)、[创建恢复](FAMILY_CREATION_RELIABILITY.md)、[本机首用流程](LOCAL_DEBUG.md) | 新家庭真实首用、外部邮件与孩子独立操作 |
| 6.3 长期计划 | [奖励编辑](PLAN_REWARD_EDITOR.md)、[离线计划](OFFLINE_SCHEDULES.md)，请假不计分母、最高终奖档位 | 真实计划周期、云端调度和两端操作 |
| 6.4 经济与账本 | [库存](REWARD_INVENTORY.md)、[兑换恢复](ECONOMY_COMMANDS.md)、[审计明细](WALLET_ADJUSTMENT_DETAILS.md)、[真实并发报告](../build/concurrency_integration/results.json) | 真实家庭长期账本核对与经济平衡 |
| 6.6 拼音练习 | 词条由家长确认。使用新版渲染器时，`lǜ4 shuǐ3` 在题页与答案页均印为 `lǜ shuǐ`，本机已通过真实组卷、下载与逐页核对。[词库](PINYIN_WORD_BANK.md) · [组卷验收](PDF_INTEGRATION.md) | Android 系统打印预览和另存 PDF 已通过；iPhone 系统打印、真实教材与多音字语境仍待验证。 |
| 6.7 PDF生命周期 | [PDF集成](PDF_INTEGRATION.md)、[永久清理](PERMANENT_CLEANUP.md)、[本机文件恢复](BACKUP_RESTORE.md) | 真实30天保留期限、托管存储/调度与目标环境备份恢复 |
| 6.8 静态成长与反馈 | [成长](GROWTH_AND_EVENTS.md)、[离线成长](OFFLINE_GROWTH.md)、[反馈](TASK_COMPLETION_FEEDBACK.md) | 目标手机音效/静音/减少动态效果、孩子可用性；未引入战斗数值或学习地图 |
| 6.9 日/周/月报告 | [学习报告](LEARNING_REPORTS.md)、[AI周报](AI_WEEKLY_REPORTS.md)、`test/monthly_report_test.dart` | 真实数据趋势、模型引用一致性、真实家庭建议反馈 |
| 7.1–7.3 AI契约/审核/隐私 | [AI分析](AI_ANALYSIS.md)、[相似题](SIMILAR_QUESTIONS.md)、[上传提示](WORKSHEET_ACCESSIBILITY.md) | 实际供应商配置、预算和保留策略、教材质量评测；端侧自动模糊未实现，PRD将其列为可选 |
| 8 数据模型/状态机 | 81 份迁移通过 422 项数据库检查，10 个有数据的历史节点通过 24 项升级检查。此前提交 `a25c5d3` 另通过 9 项备份恢复检查。[升级用例](../scripts/test_database_upgrade.mjs) · [此前恢复验收](https://github.com/Alina-qiu/learning_planet/actions/runs/45926459668) · [备份恢复](BACKUP_RESTORE.md) | 托管环境迁移、升级与备份恢复 |
| 10 通知策略 | [任务本地通知](LOCAL_NOTIFICATIONS.md)、[家长通知](PARENT_NOTIFICATIONS.md)、[远程推送](PARENT_REMOTE_PUSH.md) | iOS后台安静边界、真实APNs送达与系统限制 |
| 11 衡量指标 | [业务指标](BUSINESS_METRICS.md)、[自主开始](TASK_START_METRICS.md)、[家庭留存](FAMILY_RETENTION.md)、[配置耗时](PARENT_CONFIGURATION_TIME.md) | 真实家庭数据；四周连续使用、70%独立打卡、每周配置≤10分钟尚无证据 |
| 12 / 15 迭代与原型 | [离线 HTML 原型](demo/index.html)覆盖冒险大厅、今日复习、错题宝库、任务中心、奖励商店和家长控制台。支持用示例家庭完成第 15.1 节的五项操作，运行 `node scripts/package_demo.mjs` 可生成单文件版本。 | 孩子与家长的实际可用性观察、四周家庭试用仍待开展。V2 功能按验证结果决定。 |

## 第9节非功能要求

| 要求 | 当前证据 | 尚未达到的证明范围 |
|---|---|---|
| 冷启动完整首页 ≤6 秒、列表 <1.5 秒、反馈 <500 ms | `a34bcbe` 的 API 36 模拟器 3/3 次、Android 10 模拟器 3/4 次确认完整首页在 6 秒内可见。两个环境在 1.5 秒内确认错题本首题可见的次数分别为 2/3 和 1/3。此前 `a25c5d3` 完成普通任务的本机反馈为 191–232 毫秒。[启动与列表逐次记录](APP_PERFORMANCE.md) · [任务反馈](../build/ocr-local-20261127/release/completion-feedback.json) | Android 与 iPhone 真机、重装后首次启动、各主要列表的目标设备耗时 |
| 系统大字号、单手入口、14sp | [首页与任务入口](TASK_ACCESSIBILITY.md)、[组卷适配](WORKSHEET_ACCESSIBILITY.md)，Widget回归、中文截图及此前模拟器操作 | 未覆盖所有机型、所有页面字号组合及真实读屏 |
| 事务、幂等、冲突 | 四个会话重放 80 条离线命令，通过实际 HTTP 检查重复退款和丢失回执后的结算 | 目标云端负载、长时间运行及双端实机 |
| 恢复网络30秒内开始同步 | API 29 模拟器恢复本机服务连接后，前台 9.34 秒发出首个快照请求。会话过期、离线重开后再次恢复连接，1.48 秒发出首个快照请求，1.56 秒开始补传操作。[同步时间及账本](../build/acceptance-20261124/android-reconnect.json) | 目标手机的无线网络切换、系统后台限制仍待验证 |
| 加密、RLS、密钥隔离 | 加密库、模拟器KeyStore、私有Storage/签名链接、账号隔离与权限回归 | iOS/真机备份与物理清理、目标部署配置审查 |
| 最少收集、按孩子导出/删除、关闭AI | 对应仓库、迁移及真实本机删除流程 | 云端保留期限与供应商政策、真实导出/删除完成时间 |
| 崩溃、耗时、同步/AI失败率 | [诊断](RUNTIME_DIAGNOSTICS.md)、[Android系统退出报告](../build/integration_results/native-exit-android36.json) | Android10原生信号等剩余情况、iOS MetricKit、线上监控/告警 |
| Android10+、当前及前两个iOS主版本、平板 | API29/API36模拟器部分场景，iOS未签名编译；[运行矩阵](IOS_COMPATIBILITY.md)检查18.5/iPhone与26.2/iPhone/iPad | 指定手机、iOS各版本运行和平板完整可用性 |

## AC-01至AC-11验收结论

按第 13 节逐项核对通过条件。下表给出各项已经覆盖的环境；目标手机与部署环境的验证列在第 9 节及下一阶段。

| 编号 | 当前证据 | PRD 场景状态 |
|---|---|---|
| AC-01 Android/iOS同步且只奖励一次 | 提交 `a25c5d3` 中，iPhone 缓存后离线重开，Android 完成任务。iPhone 重连后 6.182 秒发起首个读到新状态的请求。孩子得到 7 金币和 5 XP，两笔流水各一条，兄弟姐妹的任务与钱包保持原值。[双端运行](https://github.com/Alina-qiu/learning_planet/actions/runs/45926459657) | Android 10、iOS 18.5 模拟器和本机数据库已验证。目标手机与托管环境待验收。 |
| AC-02 重复提交只有一条奖励 | [并发报告](../build/concurrency_integration/results.json)记录 80 条命令重放、4 次丢回执及每个孩子的账本行数 | 本机服务重放场景通过 |
| AC-03 改时不重复生成或领奖 | API 36 模拟器产生三天连续奖励，系统日期分别拨快、拨慢 48 小时，冷启动并重新从本机服务读取，核对原任务、奖励与账本 ID | 系统改时场景在 Android 模拟器与本机服务通过 |
| AC-04 离线打卡、上线余额一致 | API 29 实际应用在服务已记账而手机丢失回执时重发同一命令。第二次断网打卡后重开，联网自动补传，两项任务合计 50 金币、40 XP。后续同步的四条账本 ID 及金额均一致。[API 29 记录](../build/acceptance-20261124/android-reconnect.json) · [API 36 记录](../build/auto_sync_device_results/walkthrough.json) | 两个 Android 模拟器版本分别连接本机服务通过 |
| AC-05 拒绝兑换退回冻结金币 | [奖励 HTTP 报告](../build/economy_integration/results.json)及[并发退款](../build/concurrency_integration/results.json)，八次并发退款只入账一次 | 本机服务场景通过 |
| AC-06 调账明细可追溯 | [实际界面报告](../build/wallet_details_results/walkthrough-20261106.json)记录 300 金币调账、操作者、时间和原因，重查时两条账本 ID 相同 | API 36 模拟器连接本机服务的场景通过 |
| AC-07 PDF顺序/答案开关/预览一致 | [实际 PDF 联调](PDF_INTEGRATION.md)核对题目顺序和答案页，客户端比较预览与导出的文件字节 | Android API 36 已完成应用预览、系统打印和另存 PDF。[文件与逐页核对](../build/demo-20261127/android-print/verification.json) |
| AC-08 多孩子隔离 | 两名孩子使用独立任务、余额和错题。Android 重连时停留在第二个孩子的首页，第一个孩子的离线操作仍只为本人结算一次。[界面回归](../test/child_switch_isolation_test.dart) · [设备与服务记录](../build/child-isolation-20261127/DELIVERY.md) | Android 和 iPhone 模拟器均通过。iOS 18.5 在线和断网时从小星切到小月再切回，六次界面核对通过。Android 完成任务后，iPhone 重连取得小星的 7 金币、5 XP，小月保有原来的 23 金币、11 XP。目标真机待验收。[配对作业](https://github.com/Alina-qiu/learning_planet/actions/runs/45886513966) |
| AC-09 安静时段不推送、不扣分 | Android 闹钟过滤、静默与奖励回归已通过。iOS 18.5 在后台直接调用正式应用委托，安静时段、范围不符及过期提醒均被抑制，允许的提醒送达。[远程提醒与原生检查](TASK_REMOTE_PUSH.md) | 同一提交的独立模拟器接收系统注入后，35 秒内仍未观测到应用委托入口。系统后台递送、真实 APNs 与目标手机待验收。[两条路径的作业记录](https://github.com/Alina-qiu/learning_planet/actions/runs/45896548909) |
| AC-10 清楚说明并在承诺期限内注销 | 本机持久服务在家长关闭客户端后 13 分 53 秒完成注销。另以 48 小时前签发的凭据验证 74 个 S3 对象、过期租约、分页续办及其他家庭文件。[真实注销与后台续办](PRIVACY_INTEGRATION.md) | 托管环境的调度和 24 小时清理时限仍待验收 |
| AC-11 三题唯一复习、全部作答自动结算 | API 36 与 API 29 对同一家庭独立登录。生成器重跑、零题孩子、系统拨快和拨慢 48 小时、离线冷启与逐题账本均有[同一家庭的验收记录](../build/ac11-device-acceptance/summary.json) | 两台 Android 模拟器连接本机服务通过。新版覆盖安装后保留三道答案和五项待同步操作，重放后任务及账本 ID 均相同 |

## 本次检查结果及下一阶段

[远程构建](REVIEW_CANDIDATE.md)：提交`4b68180`七项基础CI全部通过，包含iOS Debug/Release、Flutter/Android、两组HTTP、Storage及Linux数据库复验。本机Windows启用SCRAM后的388项数据库与9项备份恢复也通过。后续新增iOS模拟器检查，`c341a29`已编译成功但运行阶段超时；其余七项通过。后续运行结果见草稿PR的Checks；各记录按提交及任务区分，不能把基础七项通过视为新增模拟器或完整验收通过。

本轮修复[首页与任务列表适配](TASK_ACCESSIBILITY.md)：长同步提示可随任务滚动，首页和任务页避开系统左右/底部区域。新增4项、相关82项和完整804项Flutter通过（1分23秒），核心覆盖率90.93%，完整分析31.8秒无问题，274文件格式通过；五张实际中文页面截图已查看。原有千任务按需构建/完成后行移动检查也通过。没有修改SQL、原生或奖励规则，数据库及JVM结果沿用此前387项/34项。

前一轮完成[备份恢复](BACKUP_RESTORE.md)9项检查，实际PG归档及五个S3文件恢复到新环境，106表/216行、角色权限/策略/函数摘要一致，登录、私有文件隔离与重复领奖通过；5项真实Storage集成及7项启动检查通过。报告[恢复结果](../build/backup_restore/results.json)记录源/目标服务退出及合成归档清理；目标云端/生产恢复仍需执行。

此前的数据升级/并发/奖励/同步/原生多图/OCR/退出报告仍保留各自范围和排除项；**历史实际设备报告绑定当时APK，不代表最新APK已重新跑过全部场景**。当前安装包详见[构建记录](ANDROID_BUILD.md)。

较早的机器盘点记录见[状态核对结果](../build/acceptance_audit/current.json)，明确记录目标未完成；它只索引该轮文件与历史运行证据，不包含后续恢复测试和此次界面适配，也不是新的端到端测试报告。README的旧阶段说明已原文归档到[历史状态](README_STATUS_HISTORY.md)。

本机使用 Windows 和 Android 模拟器。用户暂时没有可连接的 Android 测试手机，也未准备开发用 Supabase 项目。iOS 编译和模拟器检查在远程 macOS 上执行；签名安装仍需专用测试条件。

下一阶段需保留完整目标，按以下依赖推进：

1. 配置iOS签名并准备专用测试设备，在已完成CI未签名编译的基础上验证安装与运行；验证收到后校验的iOS通知方案，并执行AC-01/AC-09两端场景。
2. 用户准备开发Supabase项目后，部署迁移、Storage策略、Edge和调度，再验证外部邮箱、APNs、保留期限、备份恢复与监控；密钥通过部署环境配置，不放入客户端或聊天记录。
3. 在 Android 和 iPhone 上测量真实首页/列表/反馈，验证相机/OCR、离线、系统导出、后台和安全存储；替换目前仅本机或模拟器的证据。
4. 接入实际模型后进行教材、答案、引用与费用评测，开展四周家庭试用并核对指标。
