# iOS版本与平板运行检查

PRD第9章要求支持当前及前两个iOS主版本，并保持平板可用。截至2026-11-12，Apple已发布[iOS27.2.1](https://developer.apple.com/news/releases/?id=11092026b)。当前及前两个实际发行主版本为27、26、18，不能把最低部署版本15.5或一次iOS18.5构建当作全部兼容性证据。

## 持续运行矩阵

CI在同一份源码上执行以下独立任务，每项均使用真实Keychain、加密SQLite和同一个千任务离线流程：

| 目标 | Xcode | Runner | 产物名称后缀 |
|---|---|---|---|
| iPhone / iOS18.5 | 16.4 | macos-15-intel | ios18-iphone |
| iPhone / iOS26.2 | 26.2 | macos-15-intel | ios26-iphone |
| iPad / iOS26.2 | 26.2 | macos-15-intel | ios26-ipad |

新增目标依据既有CI运行43183293457导出的实际设备清单，以及[GitHub镜像说明](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)。镜像可能变化，因此运行时必须找到指定系统和设备类型；缺失时检查失败，不自动用其他系统替代。各项分别上传`ios-simulator-task-flow-<后缀>`，包括所选设备/系统、Xcode版本、任务报告、两倍字体截图及诊断日志，避免产物互相覆盖。

检查涵盖本地命令先落盘、奖励等待服务端、加密库重开恢复、千任务滚动和两倍字体。各项运行相同测试，不能因为新增系统而跳过失败条件。Intel环境沿用已验证的MLImage链接方案，不通过去掉OCR插件生成特殊兼容包。

本轮只调整检查配置、测试驱动和文档，客户端及平台实现未变化，上一轮Android调试包继续对应当前应用代码。工作流语法已通过actionlint，实际清单演练确认三个选择及缺失版本拒绝；编译和运行是否通过，以对应提交的[PR Checks](https://github.com/Alina-qiu/learning_planet/pull/1)为准。

## 当前SDK构建检查

Debug/Release完整应用构建固定使用GitHub的`xcode-27`主机及Xcode27.2，依据[镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)。不再依赖`macos-latest`的默认Xcode（此前实际为26.6）。保留全部OCR插件、最低部署配置和生产入口；这一步验证当前工具链能否编译现有应用，不能替代iOS27运行。

资源检查从实际Runner.app的Info.plist读取SDK和Xcode元数据，CI要求`DTSDKName=iphoneos27.2`，不接受旧SDK或缺失信息。另将安装的模拟器SDK及运行时元数据保存为`simulator-capabilities.json`，用于判断后续原生运行的架构条件；列出运行时不等于应用已在其上运行。actionlint配置只登记官方已发布、尚未被本机1.7.12内置识别的`xcode-27`标签，没有关闭其他工作流规则。

本机合成目录检查确认SDK匹配、旧SDK拒绝、缺失SDK拒绝及旧资源检查入口均符合预期；它不是Xcode构建证据。当前工具链的实际编译结果以新提交CI为准，iOS27运行、签名及真机验收仍未完成。

## 启动与失败诊断

首次矩阵运行[43188325308](https://github.com/Alina-qiu/learning_planet/actions/runs/43188325308)有三项失败：iPad在系统首次数据迁移期间超过5分钟；iOS26.2/iPhone的Dart VM已监听，但Flutter实时日志订阅遗漏了地址；iOS18.5/iPhone的首页状态等待失败。七项编译、质量和服务端检查通过，不能据此认定矩阵通过。

第二轮[43193731229](https://github.com/Alina-qiu/learning_planet/actions/runs/43193731229)三组系统首次启动均通过；iPad编译成功并启动应用，但证实Flutter的VM地址只出现在系统统一日志，未出现在simctl控制台，因此连接仍失败。iOS18.5编译超过12分钟，编译期间保持模拟器运行会增加资源占用。

第三轮[43197958009](https://github.com/Alina-qiu/learning_planet/actions/runs/43197958009)两个iOS26.2目标均编译成功，启动后的系统日志读取超过单次20秒限制；在取得失败日志后停止旧运行，保留七项基础检查通过记录。后续将日志直接写入文件，保留超时前的输出并在总计120秒内继续查找本次PID的VM地址；读取超时不代表应用断言通过。

第四轮[43354956838](https://github.com/Alina-qiu/learning_planet/actions/runs/43354956838)的iOS26.2/iPad完整通过：真实Keychain、加密库重开、千任务滚动和双倍字号均有报告及截图；其Debug合成数据耗时不作为PRD性能验收。iOS18.5已成功发现VM并执行测试，随后首页钱包状态等待失败。失败诊断增加清理前的页面文字、阶段名称和截图，保留原20秒业务等待。驱动改为与Flutter工具内部相同的Dart入口及VM_SERVICE_URL环境变量，避免已有应用路径额外进行设备扫描及无应用过滤的系统日志订阅。iPhone26.2重新启动超过3分钟，单独将该启动阶段上限调至5分钟；这不调整业务断言或性能标准。

第五轮[43359140376](https://github.com/Alina-qiu/learning_planet/actions/runs/43359140376)共八项CI通过：iOS26.2/iPhone完整通过；iOS18.5业务测试也全部通过，但额外的结束截图超时覆盖了驱动成功退出码，整项被标为失败。后续修复仅将辅助系统截图的超时/系统错误记录为诊断，不改变Dart驱动退出码或异常；测试中的必要截图仍由驱动检查。新增5项脚本回归覆盖成功、断言失败和驱动超时，防止辅助诊断误报成功或失败。

该轮iPad在`home-wallet`阶段失败，报告等待49,541ms，清理前截图为家庭加载页，页面树显示`FamilyGate(dirty)`，尚未进入钱包。等待返回时已超过原20秒功能上限，尚不能把耗时归因到生产业务代码。Debug功能等待调整为90秒，Profile/Release维持20秒，每阶段保存实际耗时、刷新次数及最长单次刷新耗时；所有业务条件保持。该上限不代表PRD性能门槛，原始观察值继续记录，`qualifies_for_prd_acceptance=false`。

第六轮提交`d27a4a6`的[运行43362271398](https://github.com/Alina-qiu/learning_planet/actions/runs/43362271398)十项CI全部通过，三个指定模拟器首次同轮完整通过。各自报告确认本机先保存、服务端钱包不提前增加、千任务滚动及加密库重开恢复，两倍字号截图已检查。首页钱包状态等待分别为iOS18.5/iPhone的25.010秒、iOS26.2/iPhone的63.959秒、iPad的18.894秒；最长单次刷新47.899秒。原始Debug观察值保留，不能解释为生产冷启动耗时、性能改善或PRD达标。

工作流先完成最长10分钟的系统首次迁移并保存boot.log，然后关闭模拟器以腾出编译资源，编译后重新启动同一设备。启动应用后按simctl返回的准确进程ID查询已保存的系统日志，再将VM_SERVICE_URL传给原有Dart集成测试驱动；读取历史日志不依赖实时订阅时机。保留渲染器和OCR插件，退出前尝试保存辅助app-final.png。每阶段仍有上限，整体45分钟；不会无限等待或自动重试断言失败。修复后的运行结果以当前提交Checks为准。

## 仍未完成的要求

- iOS27运行尚未覆盖。现有Intel镜像实际清单不含该版本；[Xcode27镜像（Apple Silicon）](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/)与OCR原生库的模拟器架构还需另行验证。
- 18.5与26.2只是各主版本中的具体运行点，不代表所有补丁版本或所有设备通过。
- iPad检查覆盖合成任务页和本机数据流程，不代表所有页面、分屏、相机、OCR、系统导出或读屏已验收。
- 测试使用Debug和合成家庭，未经过生产登录、实际后端与推送；不能用于冷启动、完成反馈等PRD性能达标判断。
- 签名安装、华为鸿蒙4.2/iPhone真机、真实APNs/HMS和双端同步仍待验收。
