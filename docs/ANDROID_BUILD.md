# Android 调试构建

## 2026-11-06 首页与任务列表适配（当前产物）

修复长同步说明在横屏双倍字号下挤占任务列表，以及首页内容进入系统侧边区域。同步提示与任务共用可滚动区域，首页/任务页避开系统边缘。新增4项、相关82项、完整804项Flutter通过，核心覆盖率90.93%，完整分析31.8秒及274文件格式通过；五张中文截图已复核，见[实现与验证范围](TASK_ACCESSIBILITY.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215984283字节；`163995a4c40967d82a17302122f55ffd36fe73d22f1725eab14b30b83b30da31` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215984435字节；`43eed45029ffbdbbb72633373fde59d5c437b35a83bbbbb9c70bda1e003a0544` |

普通构建29.7秒、本机构建32.4秒。两个APK均通过生产入口、三ABI加密SQLite、字体/着色器、测试入口/故障类排除及v2签名检查；本机构建后已恢复普通包，两个文件与各自`.sha256`一致。日志`tmp/task-layout-ordinary-build.log`、`tmp/task-layout-local-build.log`、`tmp/task-layout-debug-signature.log`和`tmp/task-layout-local-debug-signature.log`。

用于生成本机配置的临时后端已正常退出；没有进行新的后端业务联调。本轮ADB设备列表为空，没有安装手机或模拟器；普通包尚未配置云端，仅供启动验证，本机包依赖[电脑服务及端口转发](LOCAL_DEBUG.md)。云端、iOS、华为鸿蒙4.2/iPhone、真实读屏与性能仍待验收。下方为历史产物，摘要不对应当前文件。

## 2026-11-06 组卷字号与图片隐私提示

修复组卷选项在双倍字号下溢出，以及PDF预览侵入系统区域；调整历史记录和操作按钮，显示中文状态与明确的本机时间。图片入口及上传同意旁补充个人信息检查和原图保存提示。新增6项、相关64项、完整800项Flutter通过，核心覆盖率90.94%，完整分析40.0秒及273文件格式通过；五张中文截图已复核，见[实现与验证范围](WORKSHEET_ACCESSIBILITY.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215986267字节；`6949de01fe575867e5ca3d6a1fb0cd76d73757adcbf1bd771bca5badffa7a836` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215986339字节；`0e2b311971a20974db6ade17b864ebaf4940730c68990d6885b9e47e1b776bff` |

普通构建30.1秒、本机构建28.7秒；生产入口、三ABI加密SQLite、字体/着色器、测试入口/故障类排除、v2签名检查均通过。本机构建后普通包已恢复，两个产物与各自`.sha256`一致。日志`tmp/worksheet-layout-ordinary-build.log`、`tmp/worksheet-layout-local-build.log`、`tmp/worksheet-layout-debug-signature.log`和`tmp/worksheet-layout-local-debug-signature.log`。

构建所用临时后端已正常退出，54321端口关闭；未将此次空库启动计作新的业务联调。

本轮没有重新安装手机或模拟器，PDF及导出页面的新增验证使用测试仓库/系统导出替身，不作为真实打印或分享证据。普通包尚未配置云端，仅供启动验证；本机包依赖[电脑服务和端口转发](LOCAL_DEBUG.md)。SQL、原生和PDF生成器未改；云端、iOS、华为鸿蒙4.2/iPhone及完整性能仍待验收。下方为历史产物，摘要不对应当前文件。

## 2026-11-06 图片导入中断与账号隔离

单张相册/拍照先保存原图，再处理；失败或提前退出可从本机草稿重试，账号/资料范围变化后拒绝迟到结果和排队编辑。新增10项、相关52项、完整794项Flutter通过，核心覆盖率90.94%，272文件格式及完整分析通过，详见[中断恢复与验证边界](OCR_INTERRUPTION.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215983255字节；`05d1ce9f929ec7013ffe0c7c4bba309b9087f6c3540e700297c4ca1ae5e9230c` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215983507字节；`968085872ceb0b64ecb2da91a3bb7a7113f764fc63c542256f4ff57afdd46af4` |

普通构建29.0秒、本机构建29.3秒；两个APK均通过生产入口、三ABI加密SQLite、字体/着色器、测试入口/故障类排除和v2签名检查。本机构建后已恢复普通包，并核对两个文件及各自`.sha256`一致。日志为`tmp/ocr-interruption-ordinary-build.log`、`tmp/ocr-interruption-local-build.log`及对应`*-signature.log`。

构建所用临时后端已正常退出，54321端口关闭；该空库仅用于本机构建配置，没有增加新的业务联调证据。

普通包尚未配置云端，仅用于启动验证；本机包须按[联调说明](LOCAL_DEBUG.md)启动电脑服务并转发端口。本轮未重新安装手机或模拟器，文件数据库重开测试不等同于设备进程重启。SQL与原生实现未改；华为鸿蒙4.2、iPhone、iOS构建、真实相册/拍照识别及完整性能仍待验收。下方记录为历史产物，摘要不对应当前文件。

## 2026-11-06 图片变更后的重新校对

修复重新裁剪、旋转、增强或OCR后沿用旧题干/答案与确认标记的问题，新增变更提示，取消及识别失败保留原校对。新增6项回归，完整784项Flutter、90.94%核心覆盖率通过，普通/双倍字号提示已复核，详见[重新校对](OCR_SOURCE_CHANGES.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 250014096字节；`a0cefe26b57f6b6e3898f386dbc5f4e8c33fd47f3cbed3e3023639fee69fd4d7` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215981811字节；`deac64097805ba82fb635ce6b7abd37e545ed60d612f8cf5feaf893693f0d318` |

普通构建28.8秒、本机构建30.9秒；两个APK的生产入口、三ABI加密SQLite、字体/着色器、测试入口/故障类排除和v2签名通过。日志`tmp/ocr-source-ordinary-build.log`、`tmp/ocr-source-local-build.log`、`tmp/ocr-source-debug-signature.log`及`tmp/ocr-source-local-debug-signature.log`。本机构建结束后普通APK已恢复，摘要与表中一致。

本轮未改SQL或原生实现，未重新安装手机/模拟器；UI验证使用实际Widget与本机草稿仓库，OCR返回值为测试数据。普通包未配置云端，本机包需[电脑服务与端口转发](LOCAL_DEBUG.md)。华为鸿蒙4.2/iPhone、iOS、真实拍照识别及完整性能仍待验收。下方为历史产物，其摘要不对应当前文件。

## 2026-11-06 系统退出记录验证后重建

完成[独立原生故障测试](ANDROID_EXIT_HISTORY.md)后，普通APK按生产入口重新构建，确保不包含故障测试Activity。新增显式测试构建选择和交付排除规则，生产采集器及业务逻辑未改；本机联调包保持“登录与家庭加载恢复”版本。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215978511字节；`99aa1273e8b7981a642d94e93c8ab0c447f151dc6336bc56a12207868b7972a2` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215977499字节；`0f80c1d00f1f323e0f83802944cc25ad9e7e2da502c505f82c3ee86c1e11bc41` |

普通构建29.4秒，三ABI加密库、完整资源、生产初始化和测试类排除检查通过，v2签名有效。本机包内容重新检查通过且摘要不变。日志`tmp/exit-history-ordinary-build.log`、`tmp/exit-history-ordinary-signature.log`。独立故障APK被交付检查拒绝，未作为用户安装包。

普通包安装到API36后正常显示未连接服务页面，截图已查看；WARM 8124ms不能作为性能达标依据。普通包仍未配置云端，本机包需[电脑服务](LOCAL_DEBUG.md)。华为鸿蒙4.2/iPhone、iOS编译签名、云端与完整性能仍待验收；下方普通包历史摘要不对应当前文件。

## 2026-11-06 登录与家庭加载恢复

修复入口直接显示数据库异常、登录状态出错缺少恢复操作的问题。三个入口提供中文说明、重试与原有安全退出流程；请求中禁止重复重试，双倍字号保留安全边距。新增10项检查，相关55项及完整778项Flutter通过，核心覆盖率90.94%，最终分析42.5秒无问题，268文件格式通过。详见[登录与家庭加载恢复](ENTRY_RECOVERY.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215977355字节；`e46990de105b8c8181bd75bbdeff731a57ee947c4f55d69fa45a04caa3d05de1` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215977499字节；`0f80c1d00f1f323e0f83802944cc25ad9e7e2da502c505f82c3ee86c1e11bc41` |

普通构建30.5秒，本机构建29.5秒；原入口、三ABI加密库、字体/着色器、测试类排除及v2签名检查通过，同目录提供摘要。日志为 `tmp/entry-recovery-ordinary-build.log`、`tmp/entry-recovery-local-build.log`、`tmp/entry-recovery-debug-signature.log` 和 `tmp/entry-recovery-local-debug-signature.log`。迁移仍为001–066（68份），SQL/原生实现未改。

最终本机包已安装到API36并核对安装摘要，实际完成家庭失败提示、普通/双倍字号、持续失败重试、安全退出、真实本机验证码重新登录及首页恢复；新测试家庭余额和两条账本ID不变。报告 `build/entry_recovery_results/walkthrough-20261106.json`。旧包冷启动11142ms、最终包暖启动7786ms，不可作为性能改善对照。临时服务和专用模拟器已关闭。普通包本轮未安装且未配置云端，本机包需要[电脑服务与端口转发](LOCAL_DEBUG.md)；华为鸿蒙4.2/iPhone、iOS编译、云端及完整性能待验收。下方为历史产物。

## 2026-11-06 家长调账明细

补齐原始操作者/时间/原因的PIN保护只读入口；账本来源中文化，奖励/兑换/流水和缓存时间按家庭时区显示。新增迁移066，完整768项Flutter、387组数据库、5项真实奖励HTTP集成通过，核心覆盖率90.94%，分析和266文件格式通过。详见[调账明细](WALLET_ADJUSTMENT_DETAILS.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215974795字节；`134bf1c6dea1f43b751e7c097bc8186dc378d690b0afb045594f4aaf70b92088` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215974891字节；`588620937d21d4ce9a3385dcb5f455b83ff4b34da476cf2ea11804cbc97b36e4` |

最终普通构建32.5秒，本机构建31.8秒；两个产物的原入口、三ABI加密SQLite、字体/着色器、测试类排除及v2签名检查通过，同目录提供摘要。日志为 `tmp/ledger-details-ordinary-build-final.log`、`tmp/ledger-details-local-build-final.log` 及对应 `*-signature-final.log`。后端需迁移001–066（共68份）；本轮实际本机服务已按序应用。普通包未配置云端，本机包需要[电脑服务和端口转发](LOCAL_DEBUG.md)。下方历史摘要不对应当前文件。

最终本机APK安装后的文件摘要已与交付文件比对一致。API36实际界面完成孩子账本、家长PIN、调账原始说明、普通/双倍系统字号及退出家长模式后的入口限制；设备GMT下按家庭Asia/Shanghai显示时间。前后余额300金币/冻结0/XP0和两条账本ID不变。真实OTP登录使用同轮初版，最终包保留会话后执行上述全部检查，详见[验证范围及截图](WALLET_ADJUSTMENT_DETAILS.md)和 `build/wallet_details_results/walkthrough-20261106.json`。字体已恢复，临时服务和专用模拟器已关闭。首次启动10092ms报告timeout，最终包暖启动9426ms，不作性能达标结论；普通包本轮未安装，云端、iOS及指定手机仍待验收。

## 2026-11-06 离线奖励页

新增奖励目录、兑换记录、待确认金币和账本首批离线只读缓存，显示上次读取时间，禁止离线写操作；写入/丢失回执清理旧记录，恢复连接刷新。完整755项Flutter、90.93%核心覆盖率、分析和262文件格式通过；4项真实Auth/数据库集成及7项本机启动检查通过。详见[离线奖励页](OFFLINE_ECONOMY.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 249978529字节；`909669b737e90d98b1514c5c3f1289570d943ddc6e7b37201a7e1ee9dea83d13` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215971523字节；`ae218bdb54ec2ca63fd447e8164b175cf6b030c8c3b878469222d49c36be1362` |

普通构建75.4秒，本机构建41.0秒。两个产物均通过内容、原入口、三ABI加密SQLite、字体/着色器、测试类排除和v2签名检查；本机构建结束后已核对普通包恢复摘要。同目录提供各自SHA256。日志为 `tmp/offline-economy-ordinary-build.log`、`tmp/offline-economy-local-build.log` 和对应 `*-signature.log`。

普通包未配置Supabase云端，本机包需要电脑上的临时服务和USB端口转发，见[本机使用说明](LOCAL_DEBUG.md)。华为鸿蒙4.2、iPhone、iOS构建签名、云端和性能验收尚未完成。下方历史摘要不对应当前产物。

本机最终包已安装到API36，实际UI完成申请/审批/履约、服务断开后的进程重启和三个标签缓存查看，恢复连接自动更新价格120→140；原兑现价格120、余额180/冻结0以及4条账本ID不变。报告 `build/local_economy_results/walkthrough-20261106.json`，详见[场景与边界](OFFLINE_ECONOMY.md)。首次/断网启动仍有timeout，之后页面可用；普通包本轮未安装，不作性能或真机达标结论。

## 2026-11-06 已结束复习记录

首页和任务管理可重新查看结束的复习，缓存答案/孩子把握/判定支持离线读取，未作答题只读；修复复习页末尾说明被导航栏遮挡。完整734项Flutter、核心覆盖率90.47%、分析36.8秒及259文件格式通过，6项启动工具和5项真实Storage集成回归通过。详见[复习记录](REVIEW_RECORDS.md)。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215953287字节；`07f90867f07985dededadfe672c3a92dceb5ed510522bcdfdf4fdd59df1e50df` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215953531字节；`39d02293dcd2cc931f5d077225e6b6688497dfc905d0130fed8a40e970dd19f0` |

两个产物的内容、原入口、三ABI加密库、字体/着色器、测试类排除和v2签名检查通过，同目录有各自SHA256。最终本机包已安装到API36并复核记录和导航栏边距；完整三题输入及初次离线流程使用同轮仅缺少底部边距的`9579ecdf…`包，不重复计作另一条答题流程。普通包本轮未安装，尚无Supabase云端配置；本机包需要运行电脑服务并转发端口，见[使用说明](LOCAL_DEBUG.md)。

连续构建发现并修复PowerShell恢复未设置环境变量时生成空字符串的问题，空`FLUTTER_STORAGE_BASE_URL`会使第二次构建错误使用相对Maven路径。现在显式移除原本不存在的进程变量；同一进程本机/普通两次构建成功，变量恢复值检查通过。最终本机构建10.6秒（增量，首次边距构建33.2秒）、普通32.5秒。失败日志保留，不改变系统PATH或用户配置。

构建日志：`tmp/review-record-local-build-restored-env.log`、`tmp/review-record-ordinary-build-restored-env.log`；签名日志：`tmp/review-record-local-signature-final.log`、`tmp/review-record-ordinary-signature-final.log`。下方保留历史产物，摘要不对应当前文件。华为鸿蒙4.2/iPhone、iOS编译签名、云端及性能仍待验收。

## 2026-11-05 离线复习联调修复

修复后台同步移除正在输入的复习表单，以及同步中心刷新后收起任务记录。原入口API36模拟器完成离线三题、把握、自动完成、进程重启、恢复连接与重复同步；两对一错结算30金币/30XP，账本ID保持一致。详见[实际App复习联调](REVIEW_DEVICE_INTEGRATION.md)。最终722项Flutter、核心覆盖率90.47%、分析38.6秒及258文件格式通过；SQL和原生代码未改。

| 产物 | 包名 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet` | 215952167字节；`e5152fe4b4fe8559234845e34ccef5415b1f0144d359aca1c940c8bdcad61d25` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local` | 215952371字节；`6239b03ea6d37f4201beeadc9d23b00a5442b36e7e9a130c42f7a36e171ce785` |

普通构建32.0秒，本机构建29.8秒；两个产物内容校验、v2签名及同目录SHA256通过。普通包本轮未安装，仍需配置Supabase。最终本机包已安装并验证离线记录恢复、同步中心展开保持、真实服务结算和在线重启；答题阶段使用此前同轮e25a3b08…包，完整摘要与范围见联调记录。启动仍有timeout样本，未达到性能验收结论。

构建日志为 `tmp/local-review-ordinary-build-final.log`、`tmp/local-review-build-final.log`；签名日志为 `tmp/local-review-app-debug-signature-final.log`、`tmp/local-review-app-local-debug-signature-final.log`。下面保留此前构建历史，历史摘要不对应当前文件。

## 2026-11-05 本机联调与导航边距更新

新增[本机联调使用说明](LOCAL_DEBUG.md)，无需云端项目即可用电脑上的真实服务进行Android开发。修复任务配置页保存按钮被系统导航栏覆盖，实际API36安装包已完成首次登录、建家庭/PIN、引导、创建任务、孩子完成及应用重启同步。全量719项Flutter、5项实际Auth回归、静态分析和257个Dart文件格式通过，核心覆盖率90.48%；382组SQL及34项JVM沿用此前验证。

| 产物 | 包名与用途 | 大小 / SHA256 |
|---|---|---|
| `build/app/outputs/flutter-apk/app-debug.apk` | `com.learningplanet.learning_planet`，普通入口，未配置Supabase，显示服务配置提示 | 215951375字节；`9a42d776eb98c3fa915f31449711fc6b7c621e170bb61105ea3b8c8a1d204348` |
| `build/app/outputs/flutter-apk/app-local-debug.apk` | `com.learningplanet.learning_planet.local`，学习星球·本机，通过USB端口转发使用本机服务 | 215960203字节；`ebeea5fd5f9b5b0bf91306d3dbdeea771cfc101fd4469ee97a0364742a0eee6b` |

两个产物均检查三ABI加密库、字体/着色器、原App入口及测试类排除，v2签名通过，同目录提供各自的 `.sha256`。普通构建60.7秒，本机最终构建49.8秒；本机构建脚本备份并恢复普通产物，恢复后的摘要已复核。编译后的网络配置只对debug的127.0.0.1允许HTTP；显式本机配置的profile和release构建都已实际拒绝。迁移当前为001–065（共67份），正式环境需要按序部署及配置Auth模板。

本轮完整UI流程使用本机包摘要 `b1655cea3acaad1c4bb109e1f36b2cf97739330715537e482ff3767338892bda`，随后仅更新为稳定的本机匿名构建配置，生成表中最终包；最终包另行安装验证登录。联调工具运行时才可使用在线业务，服务重启后为新的空数据库；同一匿名配置可复用，不代表旧家庭数据被保留。真实华为鸿蒙4.2/iPhone、iOS构建与生产性能仍待验收。

以下保留此前构建记录，历史摘要不代表当前产物。

## 家庭时区版本历史

2026-11-05最新重建：包含[家庭时区设置](FAMILY_TIMEZONE.md)，管理员修改、生成串行/去重、审计及本机缓存/提醒更新已接通。完整714项Flutter、375组数据库、静态分析及252个Dart文件格式通过，核心覆盖率90.47%。后端需迁移001–064；此前作答把握、计划奖励表单、自动完成、阶段奖励、家长确认、多图校对、离线同步和Android10诊断保留。目标为华为鸿蒙4.2和iPhone；iPhone仍需macOS构建、签名及真机验收。

## 已验证产物（2026-11-05）

- 位置：`build/app/outputs/flutter-apk/app-debug.apk`，249936050字节（约238.4 MiB）。普通生产入口，故障触发源码与测试入口未打入包；完整后端功能需按序部署迁移001–064，并配置Auth验证码及邮件模板。
- 包名：`com.learningplanet.learning_planet`；应用名：学习星球；版本：0.1.0+1。
- API：最低24，目标/编译36；ABI：arm64-v8a、armeabi-v7a、x86_64。
- APK SHA-256：`8a228019a77890871f776af5f4564fdbb8c1ffbc14ea694f3418395b51099676`；同目录提供 `.sha256` 文件。
- `apksigner verify --verbose --print-certs` 通过，使用 Android Debug 证书和 v2 签名。AAPT2 核对启动入口、权限和备份配置；ZIP 检查确认 Dart 调试内核、三个 ABI 的 `libsqlite3mc.so` 和两个着色器均已打包；前次构建还核对了相同原生库的 arm64 加密接口符号。
- 合并清单包含联网、网络状态、通知、开机提醒、震动及应用内部/HMS广播权限；`allowBackup=false`，配置云备份和设备迁移排除规则。`TaskAlarmReceiver`、`TaskAlarmBootReceiver`和`ParentPushService`不导出，旧插件定时接收器已移除；HMS自动初始化关闭，App ID留空。实际厂商系统行为仍需设备验证。
- 用户明确选择先完成本地调试包：本包未配置Supabase，启动入口仍为“调试版本尚未连接服务”，不能登录或执行在线业务。本轮完成构建、内容、签名与清单检查，新增页面由实际Widget测试和中文截图验证；本轮未重新安装模拟器，没有华为或iPhone真机结果。

本轮构建耗时27.3秒；714项Flutter、375组数据库、核心覆盖率6300/6964（90.47%，105个文件）、完整分析、252个Dart文件格式及补丁检查通过。原生实现未改，34项JVM、6条Android应用场景/额外重启及1条ANR跨进程场景沿用历史记录。最终APK资源、三种ABI加密库、生产初始化和入口、备份限制、v2签名均核对；脚本排除测试Dart入口及LegacyAnrFixtureActivity等故障触发类。构建/签名/清单日志为tmp/android-build-latest.log、tmp/android-apk-signature-latest.log、tmp/android-apk-badging-latest.log与tmp/android-apk-manifest-latest.log。

上一轮ANR版本的普通包摘要为`9aca693a717032156849f42361494ee2b6744c5190c2d1b39035b6a5b0ee8f23`。API29首次白屏/超时，停止进程后同包重试COLD 6276ms，配置页语义与截图通过，诊断scope已清除；仍有6次uniform链接及2条EGL错误。报告为build/startup_results/ordinary-anr-update-20261105.json，两次结果保留；不是当前新包的安装结果，也不表示性能、图形兼容性或真机验收达标。

上一版普通包分别在API29和API36模拟器安装后启动，两次`am start -W`均报告timeout/UNKNOWN，未得到有效TTID；随后语义树均确认配置页，API29截图也已复核。报告分别为`startup-debug-20261104T215013037Z.json`和`startup-debug-20261104T215215220Z.json`，位于`build/startup_results/`。两次进程均无阶段计时或未捕获Dart/Android致命异常；API36无`E/flutter`，API29记录6次Impeller/GLES着色器uniform上限错误，图形兼容性仍需定位。API29截图为`tmp/debug-api29-configuration.png`。

这些是上一版的启动核对，不作为性能达标；前轮10828ms、9837ms及其他超时原始记录继续保留。profile采样及方法/引擎跟踪见[性能记录](APP_PERFORMANCE.md)。真实首页冷启动、Android10完整图形行为和指定手机验收仍未完成。

同日对照上一版普通APK：API29的SwiftShader uniform上限为261，宿主Intel GPU为1024；`-gpu host`后uniform链接错误消失，配置页COLD 7670ms，但仍有2条EGL配置错误。随后host的profile任务测试停在模拟器缓冲区等待，未通过，因此未把host设为默认方案。当时APK摘要为`317f0414e57b3592614a2602ec5f2133097d2946ea8b2fa1d94f1d194e726cb8`。失败样本、实际后端与探针见[图形兼容性记录](ANDROID_GRAPHICS.md)；这不代表真机兼容性或性能达标。

SwiftShader下API29任务/加密存储场景通过后，重新核对并安装上一版普通APK；配置页COLD 9516ms，报告为`startup-debug-20261104T221637785Z.json`。无阶段计时或未捕获致命异常，仍有6次uniform链接错误。此次仅重新安装同一普通包，没有把profile测试入口当作交付产物。

多图导入后的上一版普通包在API29 SwiftShader模拟器安装并恢复生产入口，配置页已核对，COLD 10146ms；报告`build/startup_results/startup-debug-20261104T225740341Z.json`对应`878cad2c…`摘要。进程日志无未捕获Dart/Android致命异常或阶段计时输出，仍有6次uniform链接错误及2条EGL错误。此配置页启动记录不代表完整首页性能或目标手机验收。

上一版PIN设置修复包（`85e712c8…`）已在API29 SwiftShader模拟器安装并显示配置提示页，报告为`build/startup_results/startup-debug-20261104T232336214Z.json`。本次`am start -W`为timeout/UNKNOWN，无有效TTID，随后语义树确认配置页；对应`-log-summary.json`记录6次uniform链接错误、2条EGL错误、0次未捕获致命异常及0条启动计时。保留这次超时；当前APK的启动性能和图形兼容性仍未完成验收。

## 本机构建依赖

已获用户授权接受 Android SDK 许可，并将构建依赖安装在 `D:\learning-planet-tools`；未修改用户或系统 PATH。

| 依赖 | 版本 / 位置 |
|---|---|
| Flutter / Dart | 3.47.4 / 3.13.3，`D:\软件\Flutter` |
| Flutter 构建入口 | `D:\learning-planet-tools\flutter`，指向上述 SDK 的 NTFS Junction |
| Temurin JDK | 17.0.21+9，`D:\learning-planet-tools\jdk\jdk-17.0.21+9` |
| Android SDK | `D:\learning-planet-tools\android-sdk` |
| Command-line Tools | 23.0；该版本的 sdkmanager 转发到 Android CLI |
| Android API / Build Tools | 36 / 36.0.0 |
| 插件编译使用的额外 API | 34（revision 3）、35（revision 2），由首次 Gradle 构建安装 |
| NDK | 28.2.13676358 |
| 可选应用级测试 | Emulator37.2.13、AOSP API36 default x86_64；WHPX/SwiftShader，AVD位于工具目录的`avd/learning_planet_api36.avd` |
| Android10诊断测试 | AOSP API29 default x86_64 revision8；AVD为`learning_planet_api29`、端口5582；系统镜像和AVD均位于独立工具目录 |
| Gradle / Android Gradle Plugin | 9.3.1 / 9.1.0 |

下载地址及校验值保存在 `scripts/android_toolchain.json`。JDK ZIP 已核对官方 SHA-256，命令行工具 ZIP 已核对官方仓库 SHA-1；Gradle ZIP 已核对官方 SHA-256，并在 wrapper 中启用同一校验值。

包安装使用新工具的斜杠路径，例如 `platforms/android-36`、`build-tools/36.0.0`、`ndk/28.2.13676358`。23.0 的 sdkmanager 不再需要单独执行 `--licenses`；安装目录已生成 `licenses/android-sdk-license`。安装前仍应阅读并接受 [Android SDK 许可](https://developer.android.com/studio/terms)。

## 运行构建

使用 PowerShell 7：

```powershell
pwsh -File .\scripts\build_android.ps1 -NoPub -UseChinaMirror
```

脚本只对当前进程设置JAVA_HOME、Android SDK、PATH和独立Gradle缓存，执行完恢复原环境。首次依赖尚未解析时省略`-NoPub`。默认使用工具目录下的`flutter`英文路径入口；存在且指向本工作区的`learning_planet` Junction时统一经该路径构建。可用`-FlutterSdk`和`-ToolsRoot`指定安装位置。编译后自动运行`scripts/verify_android_apk.ps1`检查必需资源与加密库，成功才写入SHA-256文件。

本机直连 Google Storage 下载 Flutter arm64 调试引擎很慢，可加 `-UseChinaMirror` 使用 [Flutter 官方文档列出的 CFUG 镜像](https://docs.flutter.dev/community/china)。该选项仅为当前构建设置 `FLUTTER_STORAGE_BASE_URL`，不会永久改变系统环境或修改 Pub 依赖来源；`-VerboseBuild` 可保存详细构建日志。

本次镜像下载后的 arm64 引擎 JAR 与 Google 原站完整下载的 SHA-256 相同（`b27c5a17f929c224654f815e4b27cf9cf291b3d0575cd1227bc7bce9544da4c1`）；armv7/x86_64 文件的长度和 MD5 均与原站响应头一致。MD5用于传输完整性核对；APK另提供SHA-256和签名验证。

如需连接已经配置完成的后端：

```powershell
pwsh -File .\scripts\build_android.ps1 -NoPub -DartDefinesFile D:\private\learning-planet-development.json
```

定义文件提供 `APP_ENV`、`SUPABASE_URL` 和客户端公开的 `SUPABASE_ANON_KEY`；不要放入 service_role、模型或其他服务端密钥。未提供后端配置的包会显示配置提示，不能完成登录或在线业务。

准备远程推送联调时，另提供`PARENT_REMOTE_PUSH=true`、公开的`HUAWEI_APP_ID`与`HUAWEI_PROJECT_ID`；须先完成AppGallery Connect包名/签名和服务端配置。当前交付包没有这些配置，不请求Token。不放入HMS app secret或APNs私钥，配置范围见远程通知文档。

默认产物为 `build/app/outputs/flutter-apk/app-debug.apk`。这是本机调试签名的安装包；正式发布签名、商店分发及云端部署均未完成。

## 中文路径兼容

Flutter 写入的 `android/local.properties` 是 UTF-8。项目 settings 使用 UTF-8 Reader 并向 Flutter 插件加载器传递同一 SDK 路径，避免 Java Properties 的 Latin-1 默认解码破坏中文路径；Gradle JVM 也显式使用 UTF-8。`android.overridePathCheck=true` 允许当前中文工作区继续构建，不能替代后续编译验证。

实际编译还发现 Flutter 的原生着色器编译器不能从中文 SDK 路径加载 `runtime_effect.glsl`。已创建 `D:\learning-planet-tools\flutter` Junction 指向原 SDK，并通过该英文路径调用 Flutter；没有搬动项目或 SDK，也没有修改 SDK 文件。两个 Material 着色器已通过编译。

另有`D:\learning-planet-tools\learning_planet` Junction指向原工作区，供完整`flutter analyze`、Android构建和JVM测试使用。它解决中文工作区的LSP消息解析及Gradle测试worker类路径问题；覆盖率测试仍从原项目路径运行，避免LCOV相对路径差异。

本轮发现交替使用中文原路径和英文Junction构建时，Flutter的`trackSharedBuildDirectory`按路径字符串清理旧输出，可能删除新生成的同一物理文件。编译仍显示成功，但APK缺少资源与加密库。统一路径后连续重建恢复产物；未删除生成缓存（自动审批拒绝该清理操作）。以后若完整性检查报缺文件，应保持相同路径重新构建，并以检查通过为准，不能交付只有Gradle成功提示的APK。CI也加入包内容检查。

本机 Pub Cache 在 C 盘、项目在 D 盘，Kotlin 增量缓存会出现 `this and base files have different roots`。Windows 构建脚本通过 Flutter 的 `--android-project-arg=kotlin.incremental=false` 显式传递 Gradle `-P` 参数，关闭本次构建的 Kotlin 增量编译；CI 的 Linux/macOS 构建不受影响。已单独验证文件选择插件的 Kotlin 编译通过。

调试 APK 构建结果和剩余真机验证见[开发进度](PROGRESS.md)。构建成功不代表 OCR、通知、打印、系统备份或双设备同步已经过真机验证。
