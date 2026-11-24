# 当前需求覆盖与验收状态

核对日期为 2026-11-24。本文汇总当前交付范围及验收进度。[历次开发记录](PROGRESS.md)

**Android 本地联调版已可交付。** iOS 已完成未签名编译及指定模拟器测试。华为鸿蒙 4.2 和 iPhone 的安装、真实推送、生产性能、云端部署及连续家庭使用仍待验证。

需求依据为工作区[PRD V1.1](../学习星球_产品需求文档_PRD.docx)，SHA256 `4add57b35086b4281ab9651d43203e0dae27e7df2cc61614aefc8796e1324320`；本轮重新核对文件摘要，前一轮已重提正文并确认与读取内容一致。

## 当前开发进度

可在本机联调的核心流程包括邮箱登录与家庭设置、离线任务和计时、金币与 XP、奖励兑换、多图错题逐张校对、自动复习、拼音练习、PDF 组卷和学习报告。服务端已接入可替换的 AI 和推送入口，真实模型与手机通知的效果仍待验证。

Windows 完整 Flutter 测试 855 项通过，109 个核心源文件的行覆盖率为 90.74%（6846/7545）。断网冷启动时，如果已恢复的过期会话刷新失败，首次家庭查询可复用同一次失败结果，避免再次等待。恢复连接或手动刷新会重新访问服务端。账号注销、权限拒绝、切换账号仍会阻止读取原家庭。[登录回归](../test/family_entry_refresh_test.dart) · [Android 调试包](ANDROID_BUILD.md)

iPhone 的任务和家长提醒在权限回调和主线程等待结束时复核时间，如果可能跨入安静时段则抑制提醒。上一提交 `05eaa1b` 的 10 项常规远程检查全部通过，包括 SDK 27.2 未签名编译和三组 iOS 模拟器运行。独立双端验收中，iPhone 已缓存待办和零余额，随后 Android 在登录阶段超时。Windows 的 Android API 29 已独立完成这次写入，入账 7 金币、5 XP。Android 写入后 iPhone 恢复联网并显示相同余额仍待同轮验证。[常规 CI](https://github.com/Alina-qiu/learning_planet/actions/runs/45079584750) · [双端运行](https://github.com/Alina-qiu/learning_planet/actions/runs/45079584741) · [iPhone 提醒规则](TASK_REMOTE_PUSH.md)

账号注销状态检查较慢时，首页的定时轮询会等待当前检查返回。之前每 30 秒新发起的检查可能使初次结果失效，导致离线首页持续转圈。应用回到前台仍会立即核查注销状态，服务端确认已受理注销后，应用立即遮住家庭数据。[入口回归用例](../test/entry_recovery_test.dart)

同一测试家庭在 Android API 36、API 29 分别登录。API 36 断网作答 3 题，API 29 在同步前仍显示原状态。恢复连接后，两端显示同一条已完成的复习任务；3 道题分别记为正确、错误、正确，各有 1 次作答记录，金币和 XP 分别增加 30。零题孩子没有生成任务。下表区分本机服务、模拟器与目标真机的验收范围。

复习任务现在按家庭时区从 00:05 开始生成。即使孩子在 00:04:59 打开首页，也不会提前固定当天的题集。如果家长正同时归档最后一道到期题，生成器会等变更提交后再选题，避免空任务占用当天名额。迁移 073 只清理可确认由旧生成器留下、没有作答或操作记录的空任务。本机 411 项数据库检查、6 个历史节点的 16 项升级检查、9 项备份恢复均已通过。PostgREST 16.2 和 16.5 分别通过 8 项测试，各处理 99 次实际请求。[生成与并发回归](../scripts/test_review_auto_completion_cases.mjs) · [升级回归](../scripts/test_database_upgrade.mjs)

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
| 后端 | Supabase PostgreSQL/Auth/Storage，75 份业务迁移至 073 | 本机 PG 15.19、GoTrue、PostgREST、Storage、MinIO 已有联调，用户云端项目待准备 |
| 服务端任务 | Deno Edge Functions、SQL维护任务 | PDF、删除、AI与推送入口已实现；托管Cron、监控告警尚待运行确认 |
| 图片与OCR | image_picker、端侧图像处理、ML Kit中文识别 | 不通过云OCR识别；真实教材、手写、公式和设备权限待验证 |
| PDF与拼音 | 服务端确定性PDF、中文字体、拼音规则库；客户端读取原始字节预览和导出 | 已有本机真实PDF证据；系统打印/分享及两端一致性待验收 |
| 通知 | Android自有任务闹钟、HMS；iOS收到后校验的APNs任务/家长消息 | [iPhone优先安静方案](TASK_REMOTE_PUSH.md)已接入；Swift通知策略已通过；真实供应商和目标手机待验证 |
| AI | 可替换服务端网关、结构化输出、审核与预算/隐私控制 | 测试使用可控响应；没有真实模型质量、费用与保留策略验收 |

依赖声明见[pubspec.yaml](../pubspec.yaml)、[package.json](../package.json)，架构细节见[ARCHITECTURE.md](ARCHITECTURE.md)。本机工具安装在`D:\learning-planet-tools`，未修改系统PATH。

普通 `app-debug.apk` 可验证无后端配置的启动页。本机 `app-local-debug.apk` 可登录电脑上的临时测试服务并操作家庭业务，需要 USB 端口转发。该服务每次启动使用空的测试数据库。安装包和运行步骤见[构建记录](ANDROID_BUILD.md)及[本机联调](LOCAL_DEBUG.md)。

## 已确认的产品规则

| 项目 | 当前采用规则 |
|---|---|
| 目标设备 | 华为鸿蒙4.2与iPhone |
| 后端准备 | 用户暂未准备Supabase项目，先交付本地调试包 |
| 多图导入 | 一次选择多张错题，每张独立校对保存，最多10张 |
| 孩子录入 | 家长确认标准答案后，才进入可获得奖励的复习 |
| 掌握判定 | 完成1/3/7/30天复测周期，不采用连续两次正确即掌握 |
| 复习置信度 | 孩子的作答把握，与OCR识别可信度分别保存 |

## 编号功能需求

表内“本机证据”说明已经检查过的范围，不能替代最后一列的验收。

| PRD项 | 已有实现与可定位证据 | 当前剩余范围 |
|---|---|---|
| ACC-01 邮箱登录/跨端家庭 | [验证码](EMAIL_LOGIN.md)、[真实Auth联调](AUTH_INTEGRATION.md)，`lib/features/auth_family` | 外部收信、云端及Android/iOS同账号实机同步 |
| ACC-02 多孩子隔离 | [家庭概览](FAMILY_OVERVIEW.md)、[并发报告](../build/concurrency_integration/results.json)，账号/孩子范围测试 | 两端实际切换及家庭试用 |
| ACC-03 离线查看/打卡/同步 | [离线任务](OFFLINE_TASKS.md)、[实际App自动同步](../build/auto_sync_device_results/walkthrough.json)，任务/成长/奖励/计划缓存 | 真正无线断网、后台恢复与两端设备；不承诺所有页面离线写入 |
| ACC-04 服务端判奖 | [数据库测试](../scripts/test_database.mjs)、[复习结算](REVIEW_AUTO_COMPLETION.md)，服务器时间/唯一回执 | 云端时钟与真实设备改时场景 |
| ACC-05 导出/注销 | [孩子导出](CHILD_DATA_EXPORT.md)、[真实删除集成](PRIVACY_INTEGRATION.md) | 托管清理Cron、真实承诺期限及外部已导出副本说明的实机验收 |
| TSK-01 重复规则/家庭时区 | [任务系统](TASK_SYSTEM.md)、[家庭时区](FAMILY_TIMEZONE.md)，迁移064 | 两端时区切换、夏令时及跨日长期运行 |
| TSK-02 时间窗/有效计时 | [任务系统](TASK_SYSTEM.md)、[计时纠正](TASK_TIME_CORRECTIONS.md) | 真机后台/重启/时钟行为 |
| TSK-03 三类优先级 | `lib/features/tasks/domain/task_priority.dart`、[完成反馈](TASK_COMPLETION_FEEDBACK.md) | 孩子理解与读屏试用 |
| TSK-04 状态转换/禁止孩子撤销 | `lib/features/tasks/domain/task_state_machine.dart`、[实际任务流程](LOCAL_DEBUG.md) | 双端并发操作实机验收 |
| TSK-05 家长补签或纠正 | 补签及[计时纠正](TASK_TIME_CORRECTIONS.md)有原因、审计和版本检查 | 是否还包含撤回误完成，用户尚未答复；不能把这一扩展视为已实现 |
| TSK-06 智能提醒 | [本地通知](LOCAL_NOTIFICATIONS.md)、[原生授权场景](../build/integration_results/notifications-granted.json) | 用户选择[收到后复查的远程方案](TASK_REMOTE_PUSH.md)，已实现且Swift策略/构建通过，真实供应商与真机仍待验证；可能漏提醒，不能保证系统最终展示时刻 |
| TSK-07 每日自动复习 | [自动完成](REVIEW_AUTO_COMPLETION.md)、[两台 Android 模拟器逐题结算](../build/ac11-device-acceptance/summary.json)。每个孩子每天最多生成一项自动复习任务 | 当前在生成时固定题集。开始前是否补入新到期题仍待确认。托管环境家庭时区 00:05 调度及目标手机待验证 |
| ERR-01 拍照/多图/裁剪 | [OCR管理](OCR_MANAGEMENT.md)、[原生多选报告](../build/integration_results/image-import-native.json)、[中断草稿](OCR_INTERRUPTION.md) | 真机相机权限、系统回收期间选择恢复及真实图片 |
| ERR-02 逐字段校对 | [字段校对](OCR_FIELD_CORRECTION.md)、[源图片变更](OCR_SOURCE_CHANGES.md) | 真实教材复杂版式与识别质量，不能以合成图片代替 |
| ERR-03 学科/知识点 | [题目目录](QUESTION_CATALOG_PAGINATION.md)、`lib/features/wrong_questions/presentation/review_question_editor.dart` | 双设备编辑与真实数据规模 |
| ERR-04 错误原因 | 六类人工标签，`test/error_reason_tags_test.dart`、迁移035 | 真机输入与家庭使用 |
| ERR-05 相似题检索/生成 | [相似题](SIMILAR_QUESTIONS.md)，AI标识、隐藏答案、审核采纳 | 真实模型、复杂题意、答案质量和费用评测 |
| ERR-06 掌握/复测/稍后提醒 | [提醒](REVIEW_REMINDERS.md)、[把握程度](REVIEW_ANSWER_CONFIDENCE.md)、[阶段奖励](REVIEW_MILESTONE_REWARDS.md) | 真实1/3/7/30天周期、两设备与后台提醒 |
| ERR-07 混合组卷/排序/开关 | [PDF集成](PDF_INTEGRATION.md)、[组卷适配](WORKSHEET_ACCESSIBILITY.md)，冻结顺序与同请求重试 | 两端实际操作、打印与分享 |
| ERR-08 A4预览导出 | [真实PDF集成](PDF_INTEGRATION.md)、`scripts/fixtures/worksheet_client_test.dart` | iPhone/华为系统导出与真实教材字体质量 |

## 其余明确范围

| PRD章节 | 实现与证据 | 剩余验收/范围说明 |
|---|---|---|
| 3 / 3.1 角色、PIN与二次确认 | [家庭成员与权限](FAMILY_MEMBERS.md)、[PIN设置测试](../test/parent_pin_settings_test.dart)，服务端PIN与敏感操作确认 | 真机安全存储、两端权限失效；生物识别为可选方案，当前使用PIN |
| 5.1 首次使用 | [孩子档案与引导](CHILD_PROFILE_ONBOARDING.md)、[创建恢复](FAMILY_CREATION_RELIABILITY.md)、[本机首用流程](LOCAL_DEBUG.md) | 新家庭真实首用、外部邮件与孩子独立操作 |
| 6.3 长期计划 | [奖励编辑](PLAN_REWARD_EDITOR.md)、[离线计划](OFFLINE_SCHEDULES.md)，请假不计分母、最高终奖档位 | 真实计划周期、云端调度和两端操作 |
| 6.4 经济与账本 | [库存](REWARD_INVENTORY.md)、[兑换恢复](ECONOMY_COMMANDS.md)、[审计明细](WALLET_ADJUSTMENT_DETAILS.md)、[真实并发报告](../build/concurrency_integration/results.json) | 真实家庭长期账本核对与经济平衡 |
| 6.6 拼音练习 | [词库](PINYIN_WORD_BANK.md)、`test/pinyin_import_test.dart`、`scripts/test_pinyin_worksheet.mjs` | 真实教材、多音字语境、两端打印；人工确认不能省略 |
| 6.7 PDF生命周期 | [PDF集成](PDF_INTEGRATION.md)、[永久清理](PERMANENT_CLEANUP.md)、[本机文件恢复](BACKUP_RESTORE.md) | 真实30天保留期限、托管存储/调度与目标环境备份恢复 |
| 6.8 静态成长与反馈 | [成长](GROWTH_AND_EVENTS.md)、[离线成长](OFFLINE_GROWTH.md)、[反馈](TASK_COMPLETION_FEEDBACK.md) | 目标手机音效/静音/减少动态效果、孩子可用性；未引入战斗数值或学习地图 |
| 6.9 日/周/月报告 | [学习报告](LEARNING_REPORTS.md)、[AI周报](AI_WEEKLY_REPORTS.md)、`test/monthly_report_test.dart` | 真实数据趋势、模型引用一致性、真实家庭建议反馈 |
| 7.1–7.3 AI契约/审核/隐私 | [AI分析](AI_ANALYSIS.md)、[相似题](SIMILAR_QUESTIONS.md)、[上传提示](WORKSHEET_ACCESSIBILITY.md) | 实际供应商配置、预算和保留策略、教材质量评测；端侧自动模糊未实现，PRD将其列为可选 |
| 8 数据模型/状态机 | 75 份[迁移](../supabase/migrations)、[有数据升级报告](../build/database_upgrade/results.json)、[真实本机Auth/Storage恢复](BACKUP_RESTORE.md) | 云端迁移、真实Auth/Storage版本升级、目标环境备份恢复及回滚 |
| 10 通知策略 | [任务本地通知](LOCAL_NOTIFICATIONS.md)、[家长通知](PARENT_NOTIFICATIONS.md)、[远程推送](PARENT_REMOTE_PUSH.md) | iOS后台安静边界、真实HMS/APNs送达与系统限制 |
| 11 衡量指标 | [业务指标](BUSINESS_METRICS.md)、[自主开始](TASK_START_METRICS.md)、[家庭留存](FAMILY_RETENTION.md)、[配置耗时](PARENT_CONFIGURATION_TIME.md) | 真实家庭数据；四周连续使用、70%独立打卡、每周配置≤10分钟尚无证据 |
| 12 / 15 迭代与原型 | MVP及多项V1.1/V1.2能力已有实现；当前验收基于真实App与服务测试 | V2学习伙伴、家庭协作、成熟动画按PRD验证后决定，不用加入新模块替代当前验收 |

## 第9节非功能要求

| 要求 | 当前证据 | 尚未达到的证明范围 |
|---|---|---|
| 冷启动<3秒、列表<1.5秒、反馈<500ms | API 29 在线 Profile 构建的 5 次系统首帧中位为 1.65 秒，另 3 次首次观察到大厅、孩子和钱包同时可见为 3.63 至 5.42 秒。[在线测量](../build/acceptance-20261123/online-profile-startup.json) · [列表与反馈](APP_PERFORMANCE.md) | API 36 调试版在会话过期且服务不可达时，保留同一账号覆盖安装。旧包和新包各冷启 3 次，从发起启动到首次观察到大厅、孩子和钱包的中位数由 31.38 秒降至 20.14 秒。仍未达到 3 秒目标，目标手机也待测。[新旧包逐次测量](../build/acceptance-20261124/offline-startup-comparison.json) |
| 系统大字号、单手入口、14sp | [首页与任务入口](TASK_ACCESSIBILITY.md)、[组卷适配](WORKSHEET_ACCESSIBILITY.md)，Widget回归、中文截图及此前模拟器操作 | 未覆盖所有机型、所有页面字号组合及真实读屏 |
| 事务、幂等、冲突 | 四个会话重放 80 条离线命令，通过实际 HTTP 检查重复退款和丢失回执后的结算 | 目标云端负载、长时间运行及双端实机 |
| 恢复网络30秒内开始同步 | 实际APK前台及重开后分别14.422秒/7.087秒发起同步 | 本机回环连接断开不代表无线网络、后台或两端实机 |
| 加密、RLS、密钥隔离 | 加密库、模拟器KeyStore、私有Storage/签名链接、账号隔离与权限回归 | iOS/真机备份与物理清理、目标部署配置审查 |
| 最少收集、按孩子导出/删除、关闭AI | 对应仓库、迁移及真实本机删除流程 | 云端保留期限与供应商政策、真实导出/删除完成时间 |
| 崩溃、耗时、同步/AI失败率 | [诊断](RUNTIME_DIAGNOSTICS.md)、[Android系统退出报告](../build/integration_results/native-exit-android36.json) | Android10原生信号等剩余情况、iOS MetricKit、线上监控/告警 |
| Android10+、当前及前两个iOS主版本、平板 | API29/API36模拟器部分场景，iOS未签名编译；[运行矩阵](IOS_COMPATIBILITY.md)检查18.5/iPhone与26.2/iPhone/iPad | 指定手机、iOS各版本运行和平板完整可用性 |

## AC-01至AC-11验收结论

按第 13 节逐项核对通过条件。下表给出各项已经覆盖的环境；目标手机与部署环境的验证列在第 9 节及下一阶段。

| 编号 | 当前证据 | PRD 场景状态 |
|---|---|---|
| AC-01 Android/iOS同步且只奖励一次 | 两个独立 HTTP 会话已通过同库断线恢复和逐笔结算。Android API 29 的原生写入在本机得到 7 金币和 5 XP，两个回执对应两条账本行。[本机 Android](../build/acceptance-20261123/android-native-checks.json) | iPhone 已完成首次登录和待办缓存。提交 `05eaa1b` 的远程 Android 登录超时，同一数据库下 iPhone 断线重连后的原生界面仍待验证。[双端验收](https://github.com/Alina-qiu/learning_planet/actions/runs/45079584741) |
| AC-02 重复提交只有一条奖励 | [并发报告](../build/concurrency_integration/results.json)记录 80 条命令重放、4 次丢回执及每个孩子的账本行数 | 本机服务重放场景通过 |
| AC-03 改时不重复生成或领奖 | API 36 模拟器产生三天连续奖励，系统日期分别拨快、拨慢 48 小时，冷启动并重新从本机服务读取，核对原任务、奖励与账本 ID | 系统改时场景在 Android 模拟器与本机服务通过 |
| AC-04 离线打卡、上线余额一致 | [自动同步](../build/auto_sync_device_results/walkthrough.json)记录待同步操作、联网确认后 50 金币 / 40 XP 和稳定的四条账本 ID | API 36 模拟器连接本机服务的场景通过 |
| AC-05 拒绝兑换退回冻结金币 | [奖励 HTTP 报告](../build/economy_integration/results.json)及[并发退款](../build/concurrency_integration/results.json)，八次并发退款只入账一次 | 本机服务场景通过 |
| AC-06 调账明细可追溯 | [实际界面报告](../build/wallet_details_results/walkthrough-20261106.json)记录 300 金币调账、操作者、时间和原因，重查时两条账本 ID 相同 | API 36 模拟器连接本机服务的场景通过 |
| AC-07 PDF顺序/答案开关/预览一致 | [实际 PDF 联调](PDF_INTEGRATION.md)核对题目顺序和答案页，客户端比较预览与导出的文件字节 | 本机渲染与客户端读取场景通过 |
| AC-08 多孩子隔离 | [界面切换回归](../test/child_switch_isolation_test.dart)在一次切换中核对任务、钱包和错题，控制旧孩子的响应先后返回；[并发报告](../build/concurrency_integration/results.json)核对真实服务 | 界面层与服务层的本地场景通过 |
| AC-09 安静时段不推送、不扣分 | Android实际闹钟过滤、静默与奖励回归 | **未完成验收**：已按用户选择改为收到后校验，Swift策略与构建已通过，仍待真实供应商/目标手机 |
| AC-10 清楚说明并在承诺期限内注销 | [真实删除联调](PRIVACY_INTEGRATION.md)核对 74 个 S3 对象、两个过期租约、分页续办和其他成员的文件摘要 | 本机注销与中断恢复通过。目标环境的调度和 24 小时清理时限仍待验收 |
| AC-11 三题唯一复习、全部作答自动结算 | API 36 与 API 29 对同一家庭独立登录。生成器重跑、零题孩子、系统拨快和拨慢 48 小时、离线冷启与逐题账本均有[同一家庭的验收记录](../build/ac11-device-acceptance/summary.json) | 两台 Android 模拟器连接本机服务通过。新版覆盖安装后保留三道答案和五项待同步操作，重放后任务及账本 ID 均相同 |

## 本次检查结果及下一阶段

[远程构建](REVIEW_CANDIDATE.md)：提交`4b68180`七项基础CI全部通过，包含iOS Debug/Release、Flutter/Android、两组HTTP、Storage及Linux数据库复验。本机Windows启用SCRAM后的388项数据库与9项备份恢复也通过。后续新增iOS模拟器检查，`c341a29`已编译成功但运行阶段超时；其余七项通过。后续运行结果见草稿PR的Checks；各记录按提交及任务区分，不能把基础七项通过视为新增模拟器或完整验收通过。

本轮修复[首页与任务列表适配](TASK_ACCESSIBILITY.md)：长同步提示可随任务滚动，首页和任务页避开系统左右/底部区域。新增4项、相关82项和完整804项Flutter通过（1分23秒），核心覆盖率90.93%，完整分析31.8秒无问题，274文件格式通过；五张实际中文页面截图已查看。原有千任务按需构建/完成后行移动检查也通过。没有修改SQL、原生或奖励规则，数据库及JVM结果沿用此前387项/34项。

前一轮完成[备份恢复](BACKUP_RESTORE.md)9项检查，实际PG归档及五个S3文件恢复到新环境，106表/216行、角色权限/策略/函数摘要一致，登录、私有文件隔离与重复领奖通过；5项真实Storage集成及7项启动检查通过。报告[恢复结果](../build/backup_restore/results.json)记录源/目标服务退出及合成归档清理；目标云端/生产恢复仍需执行。

此前的数据升级/并发/奖励/同步/原生多图/OCR/退出报告仍保留各自范围和排除项；**历史实际设备报告绑定当时APK，不代表最新APK已重新跑过全部场景**。当前安装包详见[构建记录](ANDROID_BUILD.md)。

较早的机器盘点记录见[状态核对结果](../build/acceptance_audit/current.json)，明确记录目标未完成；它只索引该轮文件与历史运行证据，不包含后续恢复测试和此次界面适配，也不是新的端到端测试报告。README的旧阶段说明已原文归档到[历史状态](README_STATUS_HISTORY.md)。

本机使用 Windows 和 Android 模拟器。用户暂时没有可连接的华为测试手机，也未准备开发用 Supabase 项目。iOS 编译和模拟器检查在远程 macOS 上执行；签名安装仍需专用测试条件。

下一阶段需保留完整目标，按以下依赖推进：

1. 配置iOS签名并准备专用测试设备，在已完成CI未签名编译的基础上验证安装与运行；验证收到后校验的iOS通知方案，并执行AC-01/AC-09两端场景。
2. 用户准备开发Supabase项目后，部署迁移、Storage策略、Edge和调度，再验证外部邮箱、HMS/APNs、保留期限、备份恢复与监控；密钥通过部署环境配置，不放入客户端或聊天记录。
3. 在华为鸿蒙4.2/iPhone上测量真实首页/列表/反馈，验证相机/OCR、离线、系统导出、后台和安全存储；替换目前仅本机或模拟器的证据。
4. 接入实际模型后进行教材、答案、引用与费用评测，开展四周家庭试用并核对指标。
