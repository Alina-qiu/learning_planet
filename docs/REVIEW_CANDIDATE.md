# 本地审阅分支与远程验证准备

更新于2026-11-06。当前完整源码已复制到独立工作树`D:/learning-planet-tools/review-app-20261106`，分支为`codex/app-implementation-20261106`，基于`2a476d69600c6fc4747e25cadd01b8c9345d5e22`。用户授权公开发布后，已推送提交`0aa7b9a`并创建[草稿PR #1](https://github.com/Alina-qiu/learning_planet/pull/1)。原工作区仍保留在`main`，未覆盖原有改动或暂存区；尚未合并或部署。

## 审阅范围

- Flutter任务、自动复习、金币/XP、奖励兑换、错题/OCR、PDF、成长、报告、家庭管理与离线数据实现；采用用户确认的多图独立校对、家长确认答案、1/3/7/30天掌握和孩子作答把握程度规则。
- Android/iOS工程、数据库迁移、Edge Functions、测试与本机运行脚本；逐项覆盖和未完成范围见[当前状态](CURRENT_STATUS.md)。
- CI包含Flutter/Android检查、数据库与HTTP/Auth/Storage集成，以及macOS上的Debug/Release未签名iOS构建与资源检查。未签名构建不生成可直接安装到iPhone的交付包。
- 文档包含合成测试及本机验证的说明。本机`build/`、`coverage/`、`tmp/`、`output/`证据未入库；文档中指向这些路径的链接仅在保留相应产物的原工作区可用，克隆源码后须执行对应验证再生成。

需求原始Word文件、`.env`、本机SDK与服务配置、设备凭据、构建缓存、APK、截图和导出文件均未纳入发布候选。公开发布源码会同时公开已整理的功能设计与技术文档，不能将排除需求原件理解为隐藏了所有产品设计。

## 本机验证

- 初始复制652个源码/文档/资源文件、约15.9MB，逐文件SHA256与原工作区一致。离线依赖恢复后没有修改这些文件。
- 审阅目录独立执行`flutter pub get --offline`与`flutter analyze --no-pub`成功，分析30.7秒无问题；日志位于原工作区`tmp/review-candidate-*.log`。
- Gitleaks 8.30.1目录扫描使用官方校验和验证的工具，扫描器报告1处`private-key`命中并返回1。人工逐行核对后，命中为`supabase/functions/_shared/parent_push_worker.mjs`中验证及移除PEM头尾的解析语法，不含私钥数据。没有改动生产解析器，也没有添加扫描豁免；这不等于自动扫描零告警或完整安全审计。
- 当前业务代码最近完整验证为804项Flutter通过、核心覆盖率90.93%，并已重建两个Android调试包；详细日志与适用范围见[任务适配](TASK_ACCESSIBILITY.md)、[测试记录](TESTING.md)和[构建记录](ANDROID_BUILD.md)。本次仅整理分支与文档，未把历史测试计为新执行。

本机候选清单、扫描报告及最终本地提交标识保存在原工作区`build/review_candidate/`，不随源码发布。

## 远程构建进展

原仓库为公开的[Alina-qiu/learning_planet](https://github.com/Alina-qiu/learning_planet)。旧[成功CI](https://github.com/Alina-qiu/learning_planet/actions/runs/35095053736)只覆盖基线`2a476d6`。当前源码的[首轮CI](https://github.com/Alina-qiu/learning_planet/actions/runs/42138320338)已实际运行：两组HTTP集成和Storage/隐私/PDF/备份恢复通过；启动检查的一项250ms网络断言不稳定，iOS Debug/Release均在生命周期注册方法名处编译失败。

修复将状态/隐私输出断言使用确定的503响应，保留其他真实HTTP重试、请求体超时和进程退出测试，本机7项通过。iOS使用Swift导入后的`add(_:)`名称，保留引擎创建前注册；实际CocoaPods解析出的Debug/Release锁文件一致，已保留`ios/Podfile.lock`。

[第二轮CI](https://github.com/Alina-qiu/learning_planet/actions/runs/42139724907)对应修复提交`6722047`：iOS Debug/Release编译与资源检查、Flutter/Android、两组HTTP和Storage集成均通过；数据库任务继续检出并发测试连接漏传密码。Windows原先使用trust认证，无法检出该问题。现将35处显式连接改为复用当前测试连接参数，Windows临时库改用SCRAM认证，并增加无效密码拒绝检查。本机完整388项数据库及9项实际备份恢复通过，修复后的Linux数据库任务仍需下一轮CI验证。

本机备份复验第一次Storage启动超过60秒，已保存失败记录；随后独立启动探测确认SCRAM下可启动，完整重跑通过。未放宽超时，也未将只启动探测记为完整集成通过。详情见[备份恢复](BACKUP_RESTORE.md)。

[第三轮CI](https://github.com/Alina-qiu/learning_planet/actions/runs/42141570527)对应`4b68180`，七项任务全部通过，包括Linux完整388项数据库检查、两组HTTP、Storage/备份恢复、Flutter/Android以及iOS Debug/Release。当前又加入独立iOS模拟器任务，运行已有原生加密离线任务测试；新增任务仍待远程执行，不能把第三轮结果用于证明它通过。

`37a3549`的[后续CI](https://github.com/Alina-qiu/learning_planet/actions/runs/42143885652)原七项再次通过；新增模拟器任务因MLImage缺少arm64模拟器库而链接失败，测试未启动。改为Intel/Xcode16.4/iOS18.5后，`c341a29`的[复验](https://github.com/Alina-qiu/learning_planet/actions/runs/42145294617)成功编译模拟器应用，但编译后等待直至30分钟任务上限，未取得测试结果；原七项仍通过。现将构建与运行拆开、设置独立时限并补充诊断附件，最新结果见PR的Checks。保留原Apple Silicon Debug/Release构建。

`8a1dc7f`的[诊断复验](https://github.com/Alina-qiu/learning_planet/actions/runs/42149149028)已在iOS18.5模拟器实际启动并执行本机加密任务流程，失败原因定位为旧测试脚本仍查找`ListView`，与已改为`CustomScrollView`的任务页不符。现使用页面既有滚动区域标识，并补充实际滚动及按需构建断言。该轮在滚动前失败，不能算完整通过；最新结果见PR的Checks。

工作流由PR或`main`上的push触发，后续修复继续提交至草稿分支。签名安装、iPhone/鸿蒙4.2实机、云端配置、iOS后台安静边界、真实性能和家庭试用仍须单独完成。
