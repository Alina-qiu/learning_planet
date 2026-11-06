# Android 实际 App 离线复习联调

2026-11-06后续补充[复习记录重开](REVIEW_RECORDS.md)：首页和任务列表可以重新查看已结束的复习，实际APK验证在线完成后、断网重启后的缓存读取及账本保持。以下为2026-11-05输入刷新修复的独立历史证据，最新产物见[构建记录](ANDROID_BUILD.md)。

2026-11-05：使用原 `main.dart` 的本机调试APK，在API36模拟器完成三题离线作答、三档把握、自动完成、进程重启、恢复连接及重复同步。真实服务判为两对一错，钱包从0变为30金币/30XP；三次服务端读取的两条账本ID一致。

## 本轮修复

1. 复习页订阅后台同步状态时，原 `ref.watch` 会触发依赖重载。页面因此切回加载界面，正在作答的TextField被移除，键盘焦点丢失。改为监听同步事件并刷新同一任务，保留既有表单；仓库替换仍是依赖重载，不复用原任务界面。回归测试在修复前实际找不到TextField，修复后验证焦点、输入文字和把握选择保留，另有仓库替换检查。
2. 同步中心读取本机状态后会重建展开项，原ValueKey不能恢复展开状态。改用包含账号、孩子及任务的PageStorageKey保存展开布尔值；数据读取期间的隐藏规则不变。修复前“查看复习记录”在刷新后消失，修复后保持展开；账号切换仍隐藏原记录。删除旧测试中手工重新展开的绕行步骤。

## 实际流程与证据

使用真实GoTrue邮箱验证码、PostgREST和全部67份应用迁移。`scripts/local_review_scenario.mjs`仅通过公开接口创建合成账号、家庭/PIN、三道标准答案为4的错题及当天任务，后续命令只读取状态；没有直接改数据库、注入客户端会话、替换Repository或在脚本中提交答案。图片录入/家长审核的独立验证见[Storage集成](STORAGE_INTEGRATION.md)。

| 步骤 | 实际结果 |
|---|---|
| 联网打开三题任务后移除设备端口转发 | 后端保持运行，App无法访问127.0.0.1:54321；服务端任务仍为ready、答案未判定、账本为空 |
| 在App离线开始并提交4、5、4 | 分别选择不太确定、有点把握、很有把握；最后一题保存后自动记录完成；共5项待同步操作，未提前发奖 |
| 强制结束App、离线重启及安装更新 | 首页显示5项待同步和0金币/0XP；从同步中心查看三题，答案和把握全部恢复 |
| 恢复端口转发并同步 | 三题判定true/false/true，把握1/2/3；任务completed；30金币、0冻结、30XP |
| 再次同步、再次结束并启动App | 首页钱包仍为30/30；当天仅一条任务；三次服务端读取均为相同的一条coin账本和一条xp账本 |

三题输入使用包含第一项修复的APK，摘要为 `e25a3b08059410d5bd6e121bca8096975426ab572fcf4df26e7f3d8be0b73dca`。随后安装包含同步中心修复的最终APK，摘要为 `6239b03ea6d37f4201beeadc9d23b00a5442b36e7e9a130c42f7a36e171ce785`，验证记录恢复、刷新后保持展开、服务端结算与再次重启。没有在最终包上重新创建另一套答案来重复计算场景数量；本轮计为1条实际App场景。

结构化记录在 `build/local_review_results/`：`ui-flow.json`记录设备/包摘要及边界，`before-sync-*.json`和`after-sync-*.json`记录真实接口结果。图片为 `tmp/local-review-pending.png`、`tmp/local-review-restarted-offline.png`、`tmp/local-review-restored-answers.png`、`tmp/local-review-confirmed.png`、`tmp/local-review-wallet-confirmed.png`。另保留过渡加载画面，不将其作为余额确认图。

## 重现

按[本机联调说明](LOCAL_DEBUG.md)启动服务、安装本机APK并进行端口转发。以下命令在项目目录用Node24执行：

```powershell
$nodeBinary = 'C:/Users/qiuya/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe'
& $nodeBinary scripts/local_review_scenario.mjs setup
```

使用输出的合成邮箱登录App。建夹具时已经发过一次验证码，App重新发送须遵守每地址60秒间隔；新验证码通过 `scripts/local_backend.ps1 -Command mail -Email <输出邮箱>` 读取。打开当天复习任务，移除测试设备的 `tcp:54321` 转发，在App按题目序号依次提交4/5/4和三档把握，然后强制结束并重新打开App。

```powershell
& $nodeBinary scripts/local_review_scenario.mjs before-sync
# 在设备上检查三题恢复后，重新转发端口并点击立即同步。
& $nodeBinary scripts/local_review_scenario.mjs after-sync
```

`before-sync`要求服务端仍未开始、未判题、零余额及空账本；`after-sync`要求两对一错、三档把握、任务完成、30/30余额和恰好两条账本。后台每分钟维护也不能重复生成当天任务。会话凭据只保存在Git忽略的 `.dart_tool/local-backend/review-scenario.json`；报告不含token。服务重启后旧夹具失效，脚本检查运行ID并拒绝复用。

## 验证与剩余边界

- 新增3项回归，完整722项Flutter通过，核心覆盖率6311/6976（90.47%，105个源文件）；258个Dart文件格式和完整分析通过。
- 两个APK已重建并检查内容与v2签名，摘要见[Android构建](ANDROID_BUILD.md)。SQL和原生代码未改，本轮未重复执行382组SQL、34项JVM及独立Auth/Storage套件。
- 早期输入脚本未等待焦点、清空失败，导致合成邮箱输入不正确；工具现核对焦点与实际文字。首轮夹具误用pending状态断言，已改为项目实际ready状态，未放宽业务断言。
- debug模拟器有启动timeout样本；两次有效冷启动为10171ms和9475ms，不能作为真机性能达标证据。详细日志为 `tmp/local-review-offline-restart.log`、`tmp/local-review-final-startup.log` 和 `tmp/local-review-online-restart.log`。
- 本轮断网方式是移除ADB端口转发，未替代飞行模式、弱网、真实网络切换或系统后台恢复。华为鸿蒙4.2/iPhone、iOS构建、双设备、真实相机/OCR、跨1/3/7/30天复测、云端服务和家庭试用仍待验收。

回归失败与修复后日志：`tmp/review-sync-refresh-before.log`、`tmp/review-sync-refresh-after.log`、`tmp/review-sync-center-before.log`、`tmp/review-sync-center-after.log`；最终完整测试和分析分别为 `tmp/local-review-full-tests-final.log`、`tmp/local-review-analyze-final.log`。
