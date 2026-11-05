# 实际App恢复连接后的自动同步

更新：2026-11-06。针对PRD第9节“网络恢复后30秒内开始同步”，本轮使用已安装的本机APK执行两条前台场景。此前[多会话并发测试](CONCURRENT_SYNC.md)显式调用Repository同步方法；本轮全程没有点击“立即同步”，也没有由脚本代替孩子开始/完成任务。

## 环境与测量方式

API36专用模拟器`emulator-5580`，生产`main.dart`入口、本机安全存储与加密Drift、真实GoTrue2.196.0/PostgREST16.2/PostgreSQL15.19。应用迁移001–066共68份、Auth官方迁移70份。通过实际邮箱验证码登录，邮件仅投递到本机SMTP的`@example.test`账号。

实际安装文件为`build/app/outputs/flutter-apk/app-local-debug.apk`，安装路径中的APK摘要与交付文件一致：

```text
0f80c1d00f1f323e0f83802944cc25ad9e7e2da502c505f82c3ee86c1e11bc41
```

新增`scripts/local_auto_sync_scenario.mjs`提供回环连接开关：设备的54321端口转发到电脑54322，随后转发至原本机服务54321。关闭时销毁连接，恢复时用探针进程的单调时钟记录同步快照/命令请求抵达的时间。只记录请求类别、状态码和相对时间，不记录请求正文、答案、JWT或验证码。观察脚本通过另一个直连入口读取服务端状态，不经过测量代理，不会被算作App发出的同步请求。

这模拟了前台HTTP连接中断/恢复，不是手机无线网络切换测试。计时从探针重新允许连接开始，到实际App请求抵达探针；因此测量的是可观察的请求时间，不是推测客户端Timer何时执行。

## 两条实际场景

| 场景 | 首次同步快照 | 首次提交离线操作 | 服务端结果被观察到 |
|---|---:|---:|---:|
| 前台完成任务，恢复连接后保持界面不操作 | 14,422ms | 15,031ms | 15,524ms |
| 离线完成任务、强制结束并重开，再恢复连接 | 7,087ms | 8,347ms | 8,698ms |

前两列使用探针内同一单调时钟；最后一列由只读观察脚本在恢复控制调用返回后计时，包含查询/轮询开销，不作为精确的提交耗时。

每个任务25金币/20XP。断网时实际点击“开始”“完成”，界面显示两条待同步操作；服务端任务仍为ready，钱包未提前变化。第一条自动同步后余额为25金币/20XP。

第二条在断网下强制结束进程，PID由2253变为3027；重开后仍有两条待同步操作，钱包只显示已确认的25金币/20XP。恢复连接后两个任务均完成，最终50金币/40XP、冻结0，恰好四条奖励账本。探针记录每个恢复窗口都收到两次成功的`apply_task_command`请求。

第二个窗口恢复后81,911ms还观察到后续自动快照；随后再次读取余额及全部账本ID，保持不变。最终界面显示“已同步”、两项完成和50金币/40XP。三个截图均已查看。

本轮不需要修改自动同步算法：现有实现前台每15秒尝试，恢复前台也会触发；错误后保留队列并自动重试。运行时证据只覆盖上述两条普通任务场景，不外推为所有网络/负载条件下的时限保证。

## 复现

先按[本机联调](LOCAL_DEBUG.md)启动服务并安装本机APK。在使用Node24的终端运行：

```sh
node scripts/local_auto_sync_scenario.mjs setup
node scripts/local_auto_sync_scenario.mjs probe
```

`probe`保持运行；另一个终端将设备端口转发到探针：`adb -s emulator-5580 reverse tcp:54321 tcp:54322`。用setup输出的测试邮箱在App收取并输入验证码，加载两个任务。每个测试会话只执行一次setup及一次probe，重复测量应使用新的测试会话。

1. 执行`node scripts/local_auto_sync_scenario.mjs offline`，在App开始并完成第一个任务，确认待同步提示。`state`命令仅查询服务端，可核对它仍未完成。
2. 保持App前台，执行`node scripts/local_auto_sync_scenario.mjs recover foreground`。随后不点击、不刷新、不切换界面；脚本观察真实请求及服务端结果，超过30秒未收到同步/提交请求即失败。
3. 再执行`offline`，在App开始并完成第二个任务。强制结束App并离线重开，确认两条队列和原已确认余额仍在，然后执行`recover restart`，同样保持界面不操作。
4. 等待下一轮自动快照后执行`node scripts/local_auto_sync_scenario.mjs verify`，核对奖励账本不变。
5. 先执行`node scripts/local_auto_sync_scenario.mjs stop`关闭探针，再移除端口转发、按本机联调文档停止后端。恢复普通联调时将54321转发回电脑54321。

setup只通过公开API创建合成家庭、PIN与两项任务；后续recover/state/verify只读业务数据。探针控制端点有独立本机随机凭据。工具不会直接插入数据库、注入设备缓存、修改余额或完成任务；场景凭据位于Git忽略的`.dart_tool/local-backend/`。

## 记录与边界

- 汇总：`build/auto_sync_device_results/walkthrough.json`。包含运行ID、探针ID、APK摘要、PID、两次时限、账本ID及关闭服务状态；分项请求元数据在同目录`foreground.json`、`restart.json`，后续账本核对在`stable.json`。
- 截图：`tmp/auto-sync-foreground-confirmed.png`、`tmp/auto-sync-restarted-offline.png`、`tmp/auto-sync-restart-confirmed.png`；同期UI层级、恢复日志和安装摘要以`tmp/auto-sync-`为前缀。
- 真实服务累计5次Auth、584次PostgREST、0次Storage请求、2封本机邮件。584包含App周期读取和观察脚本的查询，不代表584次同步提交或负载测试。
- Node语法检查、证据交叉核对通过。登录自动化最初使用了错误的验证码控件名称，未输入或提交，改用实时层级中的“邮箱验证码”后完成登录；没有修改App登录逻辑。
- 普通启动曾在12,177ms报告timeout；断网重开为COLD、10,760ms。这是debug模拟器记录，不能认定启动性能达标。
- 探针和后端都正常退出，54321/54322不再监听，专用模拟器已关闭。没有改动业务Dart/SQL/原生代码、依赖或APK，未重跑此前778项Flutter、387组SQL、34项JVM及覆盖率。

两台实体手机、华为鸿蒙4.2/iPhone、iOS编译、真实无线网络与后台限制、复习/图片队列在指定设备的恢复、云端部署、性能和家庭试用仍待验收，见[开发进度](PROGRESS.md)。
