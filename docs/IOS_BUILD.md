# iPhone 工程与构建验证

更新于2026-11-06。通过[草稿PR #1](https://github.com/Alina-qiu/learning_planet/pull/1)运行实际macOS构建，提交`6722047`的[Debug和Release任务](https://github.com/Alina-qiu/learning_planet/actions/runs/42139724907)均通过Xcode编译及打包资源检查。首轮发现的Swift生命周期注册方法名已修正为`add(parentPush)`。**产物未签名，尚未完成安装和iPhone运行验证**；业务Dart/SQL与Android本机包未变。

## 工程配置

- Flutter与CI固定3.47.4；Dart版本随该Flutter发行版。iOS最低部署版本15.5，与现有ML Kit插件要求一致；PRD的当前及前两个iOS主版本仍需分别验收。
- Runner Bundle ID为`com.learningplanet.learningPlanet`，邮箱回调scheme为`io.learningplanet.app`。尚未填写开发团队或配置分发签名。
- `Podfile`包含Flutter插件和`GoogleMLKit/TextRecognitionChinese ~> 9.0.0`。Debug/Release显式引用对应`Pods-Runner`配置，再引用`Generated.xcconfig`；Profile沿用Release配置。Flutter在有Xcode的主机也会自动补这些引用，本次固定到源码方便直接打开工作区，并非已复现的Flutter构建故障修复。
- AppDelegate、SceneDelegate、ParentPush及NativeDiagnostics均在Runner Sources中。原生通道在隐式Flutter引擎初始化时注册。
- 相机/相册使用说明、远程通知后台模式和`aps-environment`已在工程中；Debug使用development，Release/Profile使用production。实际签名的APNs环境还须与描述文件、服务端配置匹配，见[远程通知](PARENT_REMOTE_PUSH.md)。

## 应用隐私清单

`ios/Runner/PrivacyInfo.xcprivacy`已加入Runner的Resources。根据[Apple隐私清单位置说明](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)，iOS产物应包含`Runner.app/PrivacyInfo.xcprivacy`。新增资源检查器直接读取这个产物路径，比较解析后的内容与源码一致；把文件放进仓库而未打包会失败。

应用自身API用途按[Apple官方理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)声明：

| 类别 / 理由 | 现有用途 |
|---|---|
| UserDefaults / CA92.1 | ParentPush仅在本应用域保存通知版本、不透明范围与去重记录 |
| SystemBootTime / 35F9.1 | 本机计时、通知租约经过时间及重启失效判断；启动时间和时钟锚点不通过通道返回或上传 |
| FileTimestamp / C617.1 | 读取应用容器内文件大小/元数据，保护数据库及诊断文件、校验和清理临时导出文件 |

清单依据当前已实现的联网功能声明以下12类数据，而非用未配置后端的普通调试包推导“无数据收集”。开启推送、上传或AI的可选路径也包含在内。各类均声明与用户关联、不用于跟踪，基本用途为AppFunctionality；其他用户内容另声明ProductPersonalization，用于可选的相似题/学习建议。分类采用[Apple官方数据项](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)。

| Apple类别（省略NSPrivacyCollectedDataType前缀） | 代码中的数据 |
|---|---|
| Name | 用户填写的家庭/孩子名称、昵称；不要求真实姓名 |
| EmailAddress | 登录和家庭邀请邮箱 |
| UserID | Auth账号、家庭成员与孩子记录标识 |
| DeviceID | 可选家长推送的设备注册ID及APNs token |
| PhotosorVideos | 用户同意上传的错题图片；当前没有录像功能 |
| OtherUserContent | 题干、答案、批注、任务说明、家长调整原因与AI学习输入 |
| GameplayContent | 游戏化成长、金币/XP、角色/徽章/伙伴及兑换记录 |
| ProductInteraction | 任务完成、计时、复习作答、把握程度与奖励操作记录 |
| CrashData | 固定类别的Dart/原生崩溃计数，不是原始堆栈 |
| PerformanceData | 接口耗时分桶、卡顿计数等运行指标 |
| OtherDiagnosticData | 同步/接口失败类别及AI终态等诊断计数 |
| OtherDataTypes | 年级、教材标签和家庭设置等其余档案信息 |

诊断即使不含题目正文，也经认证上传并受账号范围约束，因此声明为关联用户。仅本机保存的数据库密钥、通知时钟锚点没有被列为上传字段。清单没有加入广告或跨应用跟踪用途，也没有修改采集行为。

SDK各自的清单仍由对应SDK提供。本文件是应用源码的数据流声明；发布前须用实际归档生成合并隐私报告，并与最终云服务、模型供应商、隐私政策及App Store Connect填写内容核对，不能由这份源码清单推断商店审核已通过。

## 在Mac验证编译和资源

需要与Flutter3.47.4兼容的Xcode及其iOS SDK、CocoaPods和Python3。先使用`flutter doctor -v`确认工具链；没有Supabase配置也可以编译普通调试入口。

在项目根目录执行：

```sh
flutter pub get
plutil -lint ios/Runner/Info.plist ios/Runner/Runner.entitlements ios/Runner/PrivacyInfo.xcprivacy ios/Runner.xcodeproj/project.pbxproj
flutter build ios --debug --no-codesign
python3 scripts/verify_ios_bundle.py build/ios/iphoneos/Runner.app
flutter build ios --release --no-codesign
python3 scripts/verify_ios_bundle.py build/ios/iphoneos/Runner.app
```

检查器验证应用清单被打包且与源码一致、Bundle ID、最低系统版本、相机/相册说明、后台通知模式、Flutter二进制/资源存在且非空，并解析所有已打包的隐私plist。它不运行二进制，不验证所有SDK声明语义、签名或设备行为。

CI的`ios-build`分别运行Debug与Release，保留构建日志、资源检查JSON和实际解析的Podfile.lock，构建失败也上传日志。[首轮CI 42138320338](https://github.com/Alina-qiu/learning_planet/actions/runs/42138320338)对应`0aa7b9a`，实际Xcode编译报`Cannot find 'addApplicationLifeCycleDelegate' in scope`。Flutter将该Objective-C选择子导入为Swift的`add(_:)`，参照[Flutter官方Swift示例](https://docs.flutter.dev/add-to-app/ios/add-flutter-screen)修正调用，保持原注册时机。

第二轮`42139724907`两个iOS任务均成功。实际产物报告确认Bundle ID为`com.learningplanet.learningPlanet`、最低版本15.5，并解析16份打包的隐私清单；应用清单含3类API和12类数据声明。报告只验证打包资源，不证明签名、启动、声明内容的全部合规语义或设备行为。报告与构建日志已保存到本机`build/review_candidate/run-42139724907-ios-validation-{debug,release}/`。该轮工作流整体仍因独立的数据库测试连接漏传密码失败，不能称整轮CI已全绿。

Debug/Release产物中的`Podfile.lock`逐字节一致，SHA256为`9d576f3677efd68eee4703997030ba511df611f4827f32965b171ccbd5651fe8`，Podfile校验值与已提交源码一致。已审查并保留此实际解析结果；它锁定CocoaPods依赖，不替代Flutter自动管理的Swift Package Manager依赖。原始日志和锁文件保存在本机`build/review_candidate/`及CI附件中。[历史CI 35095053736](https://github.com/Alina-qiu/learning_planet/actions/runs/35095053736)仍只覆盖旧提交`2a476d6`。

实际安装需在Mac打开`ios/Runner.xcworkspace`，选择自己的开发团队和设备，完成签名与相应能力配置。未签名`.app`不能直接交付iPhone安装；普通未配置服务的包只能检查启动配置提示，在线业务仍需可访问的后端。[Android本机联调](LOCAL_DEBUG.md)中的USB端口转发步骤不适用于iPhone。

## iOS模拟器运行验证

新增CI任务`ios-simulator`，从当前macOS镜像实际可用的iOS运行时中选择iPhone，启动后按[Flutter集成测试方式](https://docs.flutter.dev/testing/integration-tests)执行：

```sh
flutter drive --no-pub --debug --driver=test_driver/task_flow_driver.dart --target=integration_test/task_flow_test.dart --dart-define=TEST_DEVICE_LABEL=github-ios-simulator -d SIMULATOR_UDID
```

测试使用1000条合成任务、真实Keychain和加密SQLite，检查网络响应挂起时本机完成反馈、金币保持待服务端确认、重开后命令和状态恢复，以及两倍字体滚动截图。它直接装载合成家庭页面，不经过生产冷启动或登录，不连接真实后端；Debug模拟器耗时不能作为PRD性能验收。CI上传`ios-simulator-task-flow`附件，包括实际设备/运行时、日志、`task_flow.json`和两张PNG。运行结束关闭所选模拟器。

该任务是本轮新增，尚待远程执行。上一轮`4b68180`的[七项CI](https://github.com/Alina-qiu/learning_planet/actions/runs/42141570527)全部通过，其中iOS仍只证明未签名编译与资源完整性。

## 历史本机准备验证及剩余事项

- 6份工程plist/entitlements/隐私清单可解析；3类API理由和12类数据名称/用途与2026-11-06读取的Apple官方结构化文档一致。
- 资源引用、对象ID及CocoaPods引用顺序静态检查通过。第一次检查把`TargetAttributes`的嵌套键误算作对象定义，缩小检查范围后通过；没有因此修改原生目标。
- 资源检查器8个合成目录场景通过：正常布局返回0；缺少清单、清单不一致、缺少资产、空Flutter文件、低于15.5、错误Bundle ID、损坏SDK清单均返回1。合成文件不是iOS可执行产物。
- 报告：`build/ios_preparation/source-checks.json`明确记录`ios_built: false`；日志为`tmp/ios-preparation-checks.log`、`tmp/ios-ci-source-check.log`。工作流YAML解析通过。
- 本轮不修改Swift运行逻辑、Dart、SQL或Android资源，既有778项Flutter、387组SQL、34项JVM及90.94%覆盖率为历史结果，没有重复计为本轮执行。

Xcode未签名编译已经通过；接下来仍需签名与iPhone上的相机/中文OCR、多图中断恢复、Keychain/加密库/锁屏、退出清理、推送与静默时段、MetricKit回调、离线同步、打印分享和性能验收。Android鸿蒙4.2、云端部署与真实家庭试用同样仍未完成，完整进度见[开发进度](PROGRESS.md)。
