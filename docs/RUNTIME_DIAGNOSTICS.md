# 运行诊断与服务端指标

2026-11-06后续验证：[Android系统退出记录](ANDROID_EXIT_HISTORY.md)已在API36通过实际Java异常、SIGABRT原生崩溃及四次进程运行，确认原因4/5、磁盘恢复、去重、确认和范围隔离；原因10强制停止被排除。生产采集器未修改，34项JVM重新通过。下方原有“Android11以上真实退出原因待验证”中的Java/Native部分现已有模拟器证据；ANR退出、OEM/指定手机、iOS及云端仍未验收。

对应PRD第9节的可观测性要求。迁移037提供固定字段诊断与汇总，迁移046增加Android/iOS原生诊断接入。2026-11-05补充Android10未捕获Java/Kotlin异常及前台系统ANR观察，沿用既有固定类别，不新增迁移；iOS编译/实际回调、真实Supabase、告警和生产监控面板仍待验证。

## 记录范围与统计口径

| 来源 | 记录内容 | 边界 |
|---|---|---|
| Supabase HTTP | auth/database/storage/edge 四类请求的结果与耗时区间 | 从发送到响应流完成，含消费等待；不细分接口地址，不代表纯服务端执行时间 |
| 任务同步 | 每轮同步的结果和耗时 | 一个轮次可能处理多个命令；冲突不等于数据丢失 |
| 复习同步 | 每个远端复习命令的结果和耗时 | 服务端仍负责判题、排期与奖励 |
| 图片同步 | 每次草稿上传及确认的结果和耗时 | 授权、网络、冲突和服务端失败分别统计 |
| Dart 运行错误 | Flutter 框架、主 isolate 未捕获异步异常、启动失败的固定分类 | 不保留异常消息或堆栈；未登录时仅输出固定系统日志 |
| Android进程退出 | 系统确认的Java崩溃、原生崩溃、导致进程退出的ANR | API30及以上；仅当前应用主进程，重新打开后读取；强退、低内存回收和未知退出不计为崩溃 |
| Android10未捕获异常 | 进入默认未捕获异常处理器的Java/Kotlin异常，固定为androidJavaCrash | API30以下补充路径；不捕获C/C++信号、ANR、强退或低内存回收，不能代替API30的系统退出记录 |
| Android10前台ANR | 当前主进程被系统标为NOT_RESPONDING，固定为androidAnr | API30以下；按首次观察的UTC日期记录，不要求进程退出，不采集持续时长；系统未报告或未观察到可能漏记 |
| iOS MetricKit | 崩溃/卡顿诊断条目，按报告区间结束日计入 | 系统异步提供，不保证即时或完整；不是独立崩溃次数、卡顿总次数或崩溃率 |
| 服务端 AI | running 转 completed/failed 时，在同一事务累计用途、结果与耗时区间 | 从请求创建到确认终态；迁移前不回填 |

AI 失败率为 `failed / (completed + failed)`，按用途分别汇总。completed 包括执行完成但拒答或被安全规则拦截的结果，因此该指标不是答案正确率或内容可用率。取消、丢弃、过期及尚未确认终态的请求不在分母中，不能用它推断全部模型调用的失败率。

耗时为七个区间：小于100ms、100–499ms、500–1499ms、1500–2999ms、3000–9999ms、10000–29999ms、至少30000ms；Dart运行错误和原生诊断的bucket固定为0，表示未采集耗时，不能解释为小于100ms。计数与分桶不能给出精确平均值或分位数。

## 固定数据与隐私边界

客户端事件严格只有七个字段：随机 `event_id`、UTC `day`、`kind`、`operation`、`outcome`、固定 `error` 分类及 `bucket`。客户端恢复缓存和服务端接收都会校验类型、枚举与字段集合；多余字段、原始文本、非法日期和未来日期被拒绝或丢弃。

事件不携带题目、答案、身份、孩子/家庭ID、请求URL、查询参数、HTTP头、异常消息、堆栈或模型输出。错误分类按对象类型判断，不调用异常的 `toString()`。默认 Flutter 错误输出被固定分类替代，以免输出包含私有内容的异常详情。

服务端私有回执使用登录账号ID做授权、去重、限流及注销清理，最长保留由9天清理阈值控制；这部分仍是账号关联数据。每日汇总没有账号、孩子、家庭或请求ID，保留最近90个UTC日期。两张表均启用RLS且不开放直接读取；客户端只能调用受限的写入RPC，汇总查询仅授予 service_role。账号注销受理时立即删除其回执，旧会话不能再次写入；匿名汇总保留。

## 本机队列与上传

- 复用账号隔离的加密 OfflineStore，诊断队列与业务命令分开。写入失败不影响任务、复习或奖励结算。
- 待写入操作和已保存事件均有250条上限；保留当天及之前7个UTC日期，容量不足时丢弃部分诊断。它是尽力收集的技术指标，不是业务审计账本。
- 前台每30秒尝试上传，每批最多50条，单次等待回执10秒；失败后按30/60/120/240/300秒退避。进入后台停止发起新上传，已在途请求可能完成；恢复前台尝试继续。
- 上传批次冻结，回执必须完整匹配事件ID。失败、超时或回执丢失保留原ID重试；服务端同一账号与ID的完全相同载荷只累计一次，载荷变化则拒绝整批。
- 每账号滚动24小时最多接收10000条新事件，达到上限仍可重放已有回执。服务端并发去重与限流在事务中执行。
- 切换账号、退出或隐私清理后，旧操作和迟到回执不能写入新账号范围。重启会恢复本机队列；缓存中的非法记录不会被上传。
- 诊断写入RPC自身不再产生HTTP诊断，避免递归。未配置后端的调试包不会上传诊断；未登录也不持久化账号事件。

## 后续部署与运维

1. 在目标环境按顺序应用迁移001–046；046只扩展固定原生类别验证，不增加客户端读取权限。
2. 运行 `supabase/operations/enable_runtime_diagnostics.sql` 注册每日清理；脚本重复运行不产生重复作业。时间为03:17，部署时核对目标 pg_cron 的时区设置及实际执行记录。
3. 服务端运维可执行 `select public.runtime_health_report(7);` 查询最近7个UTC日期；参数允许1–90。结果提供分类计数、耗时区间上界及分用途AI确认终态失败率。
4. 核对真实 Auth/RLS、回执重试、账号注销及清理任务，再配置监控和告警。保留期依赖清理任务正常运行，不能只注册而不核对执行。

这里没有给客户端增加 service_role 密钥。本轮按用户选择仅生成未连接后端的本地APK，以上云端步骤尚未执行。

## 原生收集、范围与重放

原生端只接触随机scope、日期、固定类别、事件UUID和本机去重/时间边界；账号到scope的映射保存在加密OfflineStore中。没有用户/孩子/家庭ID、Token或题目。Android不读取退出描述、TraceInputStream或系统日志；iOS不读取异常元数据、callStackTree或完整JSONRepresentation。

首次绑定从当前时间开始，不回填无法归属的旧记录。同账号正常重启保留范围；退出、账号变化、账号注销、无后端配置或观察到时钟回拨会清除/重设原生范围。Flutter在导入前后检查账号、请求版本及隐私代次；iOS报告起点早于当前范围起点时丢弃整段，避免将跨账号的报告归给新账号。账号注销后的本机删除标记阻止重建scope，并在下一次采集时清除原生绑定。

Android11及以上使用[ApplicationExitInfo](https://developer.android.com/reference/android/app/ApplicationExitInfo)和[历史进程退出记录](https://developer.android.com/reference/android/app/ActivityManager#getHistoricalProcessExitReasons(java.lang.String,int,int))，串行工作线程每次最多读取50条本应用记录，只接受绑定时间内的明确崩溃/ANR退出。系统保留范围之外、首个绑定之前、未退出的ANR及其他进程不在本统计范围内。

Android10没有该API，改由`LearningPlanetApplication`在应用初始化时为API30以下安装[默认未捕获异常处理器](https://developer.android.com/reference/java/lang/Thread.UncaughtExceptionHandler)，只在存在原处理器时包装。记录后始终将原Thread和Throwable对象交回原处理器，保留系统崩溃/终止流程；不启动界面、不重启进程、不发送网络请求、不读取或打印异常正文/堆栈。记录抛出异常（包括分配失败）也继续交回原处理器；并发崩溃只尝试记录一次，其余立即转发。系统本身的崩溃日志行为保持不变。

补充路径在`noBackupFilesDir/legacy_java_crash_v1`保存单条、最多256字节的固定格式标记：格式版本、不透明scope、原范围起点/观察时间、崩溃时间和本进程PID。使用[AtomicFile](https://developer.android.com/reference/android/util/AtomicFile)原子替换并排除备份；没有异常对象、线程名、账号、题目或URL。崩溃路径读取内存中的范围快照，文件正被处理时直接放弃记录，避免等待工作线程或SharedPreferences锁。范围持久化期间暂停归属，写入成功后才恢复。

重新打开并恢复同一scope/范围起点后才导入；换账号、退出、时钟回拨、过期、未来时间或损坏内容被丢弃。先将固定事件和去重标记持久保存，再删除崩溃文件；导入或删除失败可重试同一ID。API30以上继续仅使用系统退出来源并清理旧版本标记，避免升级后双计。该小文件最多保留最后一次未导入的异常，连续启动崩溃可能覆盖前一次；未绑定账号、处理器安装前、线程自有处理器或后续替换默认处理器的异常不保证采到。Android10的C/C++信号仍是缺口，前台ANR补充路径见下文，不能将这条Java/Kotlin补充路径称为完整原生崩溃覆盖。

iOS通过[MetricKit诊断回调](https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber/didreceive(_:)-9yd4u)只提取报告时间范围及两类诊断条目数量，不落盘原始载荷。为兼容工程iOS15.5基线采用subscriber API；Apple已将其标为Deprecated，新接口迁移需结合实际Xcode/系统版本验证。日志文件使用原子写入、完整文件保护并排除备份，锁屏不可读时保留文件、等待重试。

原生待传记录最多250条，保留当天及之前7个UTC日期；Android去重标记最多1000条，iOS最多1250条。容量限制、范围变化或系统漏报都会少计。事件ID由scope和固定来源信息确定；每批最多50条，经严格字段/类型/日期校验并提交到加密队列后才向原生确认。确认丢失或上传后再次收到同一条时继续用原ID，服务端按账号及ID精确去重。scope不会上传到服务端。

采集与业务操作分离，失败不阻塞任务结算；未配置后端的包只清除绑定、不上传。前台30秒上传轮次先尝试导入，恢复前台及认证状态变化也会核对范围。普通退出保留原账号已进入加密队列的诊断；永久注销擦除队列与映射。这仍是有界、尽力收集的健康指标，不是完整审计或逐次崩溃证明。

## 验证与尚未覆盖的部分

Android10前台ANR使用[ActivityManager.getProcessesInErrorState](https://developer.android.com/reference/android/app/ActivityManager#getProcessesInErrorState())，只读取本应用主进程的PID、进程名与condition；不访问错误正文、堆栈或tag。前台且已绑定不透明账号scope、未连接Java调试器时，串行工作线程每两秒查询一次。后台不查询系统，不增加前台服务或唤醒锁；这不是按心跳超时猜测卡顿。

新scope、重新进入前台（含两次轮询之间的短暂切换）、时钟回拨及调试边界后，先观察正常状态才能接收新的ANR。一次连续异常保留同一时间/PID身份，重复查询、读取和确认不会重复加入队列；查询失败不会把同一次异常重新计数。范围解绑、持久化失败或尚未观察健康状态时不归属新事件。只复用既有androidAnr类别、原子日志和确认协议，不需要新的数据库迁移。

这条路径记录的是系统状态被观察到的日期，而不是精确发生时间、持续时间或退出时间。后台/无绑定/调试、进程先被结束、系统接口拒绝、工作线程被暂停或持久化失败均可能漏记；恢复读取可重新绑定，但不能恢复未落盘的观察。Android10的C/C++信号仍未覆盖。API30以上继续使用系统退出历史，华为鸿蒙4.2上的实际行为另需验收。

`test/runtime_diagnostics_test.dart` 的13项测试覆盖固定字段、真实 Supabase 客户端HTTP传输、流错误/取消/暂停恢复、重复/缺失回执、退避、并发新增事件、账号与隐私边界、磁盘关闭重开、损坏缓存、容量/过期、业务同步接入及运行错误/生命周期处理。

迁移046阶段，`test/native_diagnostics_test.dart`新增12项，覆盖五类原生事件、提交后确认、同ID重放、存储失败、账号切换/注销、隐私代次、恢复、字段/日期拒收、容量及MethodChannel参数。该阶段Android新增6项JVM策略测试覆盖分类、重放、范围/回拨、时间/PID、容量/UTC保留及JSON乱序恢复后待传记录的去重标记，与当时既有推送策略共12项通过；当前累计结果见下方Android10补充验证。

`scripts/test_runtime_diagnostics_cases.mjs`现有11组，覆盖原子校验、重放去重、并发、权限、限流、AI、注销及保留，并新增原生类别、私密字段拒收和删除检查。全量414项Flutter、269组数据库检查通过，完整flutter analyze无问题；核心覆盖率4217/4858（86.81%），77个源文件，详见[测试说明](TESTING.md)。

Android11以上真实退出原因、iOS编译/签名/MetricKit回调、Android10的C/C++信号及ANR真机采集、其他isolate、设备时钟/锁屏、启动/列表/交互性能、网络恢复时限、线上监控与告警仍待验收或补齐。没有保存错误堆栈及精确故障位置，也没有全会话分母，不能给出崩溃率或把模拟器覆盖扩大到真实手机。

### Android10补充路径的验证方式

`LegacyJavaCrashPolicyTest`新增7项JVM检查，覆盖固定标记格式、严格数字范围、损坏/额外字段拒收、账号/退出/时间边界、持久重放、原处理器对象保留、记录分配失败和并发不等待。加上既有推送、退出原因和任务提醒策略，完整25项JVM已重新执行通过。

设备测试入口为`integration_test/native_crash_test.dart`，脚本只接受专用`learning_planet_api29` AVD、`emulator-5582`且核对API29/模拟器身份：

```powershell
pwsh -File scripts/test_android_legacy_crash.ps1 -UseChinaMirror
```

脚本分三阶段验证同一安装的持久状态：先绑定合成scope；通过Android的`am crash`触发实际Java异常，等待原系统处理器结束进程；重新打开确认固定字段、同ID重放及确认后不重复；再触发第二次崩溃，切换合成scope确认不跨账号导入。重复崩溃可能弹出系统对话框，脚本只点击已核实属于“学习星球”的系统“关闭应用”按钮，让原系统流程继续终止进程，不用强行停止伪造崩溃记录。

测试不连接后端，随机运行编号防止旧报告被当成当前成功证据；阶段报告为`build/integration_results/native-crash-phase-0/1/2.json`，全流程成功才写`native-crash-android29.json`。这是1条跨进程场景，含2次实际崩溃，不把三阶段或`tearDownAll`累加为业务场景。测试包不能交付用户，结束后须重新构建普通调试APK。

2026-11-05全流程已在AOSP API29 x86_64、WHPX/SwiftShader通过，报告运行编号`2f29cef9-6fac-4e5c-a58f-4275c059401a`：两个实际退出进程为4137/4230，系统关闭对话框处理1次，三个阶段全部完成。首轮因等待系统关闭对话框而中断的日志保留为`tmp/android-native-crash-dialog-wait.log`，未将其记为完整通过。

同次模拟器日志发现Impeller/GLES着色器链接报告`Fragment shader active uniforms exceed GL_MAX_FRAGMENT_UNIFORM_VECTORS (261)`；诊断数据断言通过不等于图形兼容性通过。该错误尚未定位到真实手机或应用绘制内容，保留原渲染配置继续调查，不以关闭功能让结果看似达标。Android10的完整界面、性能及华为鸿蒙4.2/iPhone验收仍未完成。

### Android10前台ANR的真实故障验证

新增LegacyAnrPolicyTest的9项，完整34项JVM通过。运行专用API29 AVD后执行：

```powershell
pwsh -File scripts/test_android_legacy_anr.ps1 -UseChinaMirror
```

脚本核对模拟器序列号、AVD、API29及启动状态，仅安装独立的com.learningplanet.learning_planet.anrfixture。显式legacyAnrFixture构建属性才会加入src/anrFixture源码和清单，使用真实LearningPlanetApplication及原生处理器，以合成scope建立日志；不启动Flutter业务或连接后端。测试Activity阻塞自己的主线程并向自己的窗口注入输入，另一个线程读取系统NOT_RESPONDING，生产观察器自行记录；恢复后只核对三项固定字段。随后强行停止该测试安装并重启，核对相同事件ID、重复读取、确认及范围隔离。普通APK检查拒绝测试Dart入口和故障触发类。

2026-11-05在AOSP API29 x86_64、WHPX/SwiftShader通过，运行编号e98bf8e9-52a0-41ca-88e2-d497907a9f6c，两个进程3784/3953，系统确认1次ANR、两阶段完成。报告build/integration_results/native-anr-android29.json及同编号capture/verify.json仅为合成测试数据。此前注册Instrumentation的两次尝试没有完成全流程，失败日志保留且不计通过；最终脚本不注册测试runner。

这是1条原生适配器跨进程场景，不是Flutter界面、图形性能、华为鸿蒙4.2或iPhone验收；既有6条Android应用场景及重启证据另计。当前无真实Supabase，普通包未登录时也不会绑定账号诊断范围。测试包结束后必须重建普通调试APK，不能交付故障测试安装。

## iOS诊断日志的原生策略检查

2026-11-06，将原有MetricKit回调中的日志状态转换提取到`ios/Runner/NativeDiagnosticJournal.swift`。应用仍使用相同的JSON结构、事件ID算法、串行队列、文件保护与排除备份设置；MethodChannel及服务端协议不变。回调只提取报告区间和两类条目数量，未加入原始诊断文本或堆栈采集。

`scripts/fixtures/native_diagnostic_journal.swift`直接编译这份生产策略，覆盖未绑定、按UTC归日、重复投递和确认、旧账号迟到确认、账号切换、退出后同账号重登、跨账号报告区间、时钟回拨、过期/未来报告、容量与待传去重标记、损坏JSON/标识/日期/类别。另将合成日志写入独立临时文件，启动全新进程读取、重放并确认，检验序列化后的事件身份与去重行为。临时文件只包含合成范围和固定类别，完成后清理。

检查接入macOS的`ios-simulator`任务，运行时直接编译上述两个Swift文件；执行结果见当前PR提交的`Check native diagnostic journal`步骤。它验证生产日志策略及普通文件跨进程恢复，不能证明MetricKit真实回调、iPhone锁屏文件保护、备份排除、故障送达或云端统计。此前Dart桥接、Android故障和iOS编译证据各保留原验证范围。
