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

本轮只调整检查配置和文档，客户端及平台实现未变化，上一轮Android调试包继续对应当前应用代码。工作流语法已通过actionlint，实际清单演练确认三个选择及缺失版本拒绝；编译和运行是否通过，以对应提交的[PR Checks](https://github.com/Alina-qiu/learning_planet/pull/1)为准。

## 启动与失败诊断

首次矩阵运行[43188325308](https://github.com/Alina-qiu/learning_planet/actions/runs/43188325308)有三项失败：iPad在系统首次数据迁移期间超过5分钟；iOS26.2/iPhone的Dart VM已监听，但Flutter实时日志订阅遗漏了地址；iOS18.5/iPhone的首页状态等待失败。七项编译、质量和服务端检查通过，不能据此认定矩阵通过。

第二轮[43193731229](https://github.com/Alina-qiu/learning_planet/actions/runs/43193731229)三组系统首次启动均通过；iPad编译成功并启动应用，但证实Flutter的VM地址只出现在系统统一日志，未出现在simctl控制台，因此连接仍失败。iOS18.5编译超过12分钟，编译期间保持模拟器运行会增加资源占用。

工作流先完成最长10分钟的系统首次迁移并保存boot.log，然后关闭模拟器以腾出编译资源，编译后重新启动同一设备。启动应用后按simctl返回的准确进程ID查询已保存的系统日志，再用Flutter的`--use-existing-app`连接VM；读取历史日志不依赖实时订阅时机。所有业务断言、20秒状态等待、渲染器和OCR插件均保留。退出前保存app-final.png，避免失败界面被卸载清除。每阶段仍有上限，整体45分钟；不会无限等待或自动重试断言失败。修复后的运行结果以当前提交Checks为准。

## 仍未完成的要求

- iOS27运行尚未覆盖。现有Intel镜像实际清单不含该版本；[Xcode27镜像（Apple Silicon）](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/)与OCR原生库的模拟器架构还需另行验证。
- 18.5与26.2只是各主版本中的具体运行点，不代表所有补丁版本或所有设备通过。
- iPad检查覆盖合成任务页和本机数据流程，不代表所有页面、分屏、相机、OCR、系统导出或读屏已验收。
- 测试使用Debug和合成家庭，未经过生产登录、实际后端与推送；不能用于冷启动、完成反馈等PRD性能达标判断。
- 签名安装、华为鸿蒙4.2/iPhone真机、真实APNs/HMS和双端同步仍待验收。
