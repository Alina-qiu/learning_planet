# 本地审阅分支与远程验证准备

更新于2026-11-06。当前完整源码已复制到独立工作树`D:/learning-planet-tools/review-app-20261106`，分支为`codex/app-implementation-20261106`，基于`2a476d69600c6fc4747e25cadd01b8c9345d5e22`。原工作区仍保留在`main`，未覆盖原有改动或暂存区；尚未推送、创建PR、合并或部署。

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

## 远程构建条件

原仓库为公开的[Alina-qiu/learning_planet](https://github.com/Alina-qiu/learning_planet)。最近查到的[成功CI](https://github.com/Alina-qiu/learning_planet/actions/runs/35095053736)只覆盖旧基线`2a476d6`；当前实现尚无远程结果。

工作流由PR或`main`上的push触发。拟在获得公开发布授权后推送本地审阅分支并创建草稿PR，再查看当前源码的各项结果并修复失败；不需要先合并到`main`。此路径可以推进Windows本机无法执行的Xcode编译，签名安装、iPhone/鸿蒙4.2实机、云端配置、iOS后台安静边界、真实性能和家庭试用仍须单独完成。
