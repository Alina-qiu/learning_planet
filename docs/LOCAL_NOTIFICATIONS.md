# 本地提醒与原生权限验证

2026-11-06更新：iPhone已按用户选择改为[收到后复查安静时段的远程任务提醒](TASK_REMOTE_PUSH.md)，移除本地定时路径，24项Swift接收策略及iOS构建/模拟器检查已通过，真实APNs和签名手机验证仍待完成。以下本地闹钟实际投递证据属于Android；旧iOS方案的后台限制记录保留为历史，不再描述当前iPhone实现。

对应PRD TSK-06及第10节：任务默认开始前10分钟、开始时、截止前15分钟；相同时点合并、家长可关闭、按家庭时区过滤安静时段。服务端生成候选，本机结合离线终态取消计划；家长系统消息仅包含兑换、同步异常和周报。HMS/APNs另见[远程通知](PARENT_REMOTE_PUSH.md)。

迁移048补充ERR-06的[复习队列稍后提醒](REVIEW_REMINDERS.md)，复用相同时段合并和原生校验。以下428项/271组记录为上一轮原生验证；最新全量结果见[测试记录](TESTING.md)。

## 设置与已读变更

家长关闭提醒、调整静默区间或用户标记已读时，仓库先递增账号/孩子的持久缓存版本并移除旧候选，再撤下当前孩子在本机的待发计划，最后发送写入。写入响应无论成功或失败都会再次更新缓存版本；变更期间及变更前发出的迟到读取不能重新缓存旧计划。网络结果不明确时不使用变更前缓存恢复提醒，须联网读取当前状态。服务端规则未变，不新增迁移。

撤下计划仅针对当前孩子；不切换另一孩子或家长消息的范围，不撤销家长远程注册。原生清理失败时不发送设置写入，下次可以重试清理；清理等待期间账号、隐私范围或家长PIN变化也会阻止继续写入。其他设备仍在下次同步后更新，离线设备不会立即收到关闭指令。

设置弹窗校验HH:mm并保留编辑内容，加载/保存期间停止配置用时采样。网络中断时提示“保存结果尚未确认”，先重新读取服务器设置再允许修改；已保存但本机权限/排程失败时提供仅重试本机提醒的操作。PIN失效或切换孩子后禁用编辑，360px和双倍字号下内容可滚动。已读响应不明确时提示联网刷新核对。

`test/reminder_settings_test.dart`新增9项回归，使用真实Supabase SDK模拟传输、内存Drift及实际客户端通知队列；原生能力由模拟适配器替代，不将这些检查当作真机证据。Android应用级场景另外检查按孩子撤下实际待发计划、拒绝旧范围再次排程及重新加载；结果见下方输出文件及[构建记录](ANDROID_BUILD.md)。

本轮授权profile场景重跑通过，`notifications-granted.json`新增`settings_cancellation_retires_only_current_child_scope=true`，既有实际静默拦截、家长固定文案和生产启动清理同时通过。拒绝/重启和18项JVM沿用前轮证据。完整445项Flutter通过，核心覆盖率4390/5017（87.50%）；完整分析、186个Dart文件格式及补丁检查通过。设置弹窗1倍/2倍字号中文截图已复核。

## 2026-11-05修复

- 生产启动先清理上次进程留下的本地待发/已显示通知，再恢复账号与家庭。清理发生在获取数据库和后端资源之前，失败交由启动页重试。未配置服务的调试包也执行清理；不会触发通知权限弹窗。
- 任务调度前同时读取本机选择和Android/iOS当前系统权限。系统权限关闭或本机开关关闭时清理旧计划，避免恢复权限后旧计划重新生效。
- 显式权限申请被拒绝时持久保存关闭状态并清理通知。仅在系统设置恢复权限不会覆盖这项本机选择，须再次在应用中授权。
- 保留既有范围版本、串行队列、60个未来时点限制、固定通知正文和幂等ID；不修改任务、账本或奖励。家长远程提醒的首次空范围仍不撤销已有用户选择。

## 实际投递时间校验

- 迁移047为候选增加`delivery_policy`，包含版本、家庭时区与安静时段。旧缓存缺少策略时清空待发提醒并提示联网刷新；不影响任务或同步命令。服务端需先部署047。
- Android任务定时提醒使用自有`TaskAlarms`/`TaskAlarmReceiver`，通过非精确AlarmManager唤醒。原生只保存最多60条不透明ID、时间和策略，不保存孩子、题目或任务正文，也不启动Flutter引擎。
- 实际显示前按家庭时区再次检查安静时段，超过原定时刻15分钟即丢弃；记录先持久标为已消费，再次复查时间后显示。重复广播不会重复显示，过期提醒不补发。
- 范围修订号和每条记录的随机令牌使已取消/替换的广播失效。时钟偏移超过30秒停止投递；系统改时清空计划，回到应用后重新同步。重启和应用更新只恢复七天窗口内的未来记录，不补发错过的时点。
- 新计划被原生校验拒绝时也会撤销旧策略，避免已经修改安静时段却继续按旧值投递；客户端下次重试重新获取范围修订号。过期范围请求只报错，不清除更新的范围。
- 清单移除旧插件的定时和启动接收器，防止升级前的计划绕过新校验。家长即时通知仍使用插件。
- `timezone`锁定版本0.11.1使用`Etc/UTC`，客户端兼容PostgreSQL的`UTC`别名。无效时区/安静区间不进入原生排程。
- iOS前台委托增加同样的静默/15分钟检查并保留Flutter回调转发；代码尚未在Xcode编译。后台本地通知由系统显示，这段前台代码不能解决后台延迟跨入安静时段的问题。

## 可重复原生测试

在专用`learning_planet_api36`模拟器（端口5580）运行：

```powershell
pwsh -File scripts/test_android_app.ps1 -Scenario NotificationsGranted -UseChinaMirror
pwsh -File scripts/test_android_app.ps1 -Scenario NotificationsDenied -UseChinaMirror
# 额外验证真实重启：保留两个未来合成记录，不卸载测试安装。
pwsh -File scripts/test_android_app.ps1 -Scenario NotificationsGranted -KeepAlarmsForReboot -UseChinaMirror
pwsh -File scripts/test_android_alarm_reboot.ps1
```

脚本先构建/安装profile测试入口，再用ADB设置该模拟器的`POST_NOTIFICATIONS`授权状态。权限场景拒绝其他设备ID，避免修改连接的用户手机。测试会清空该测试安装的通知；不连接后端、不向其他人发消息。首次安装、权限弹窗的人工作答和真实家庭权限仍需独立验收。

`integration_test/notifications_test.dart`直接使用实际插件、自有接收器和Android系统接口。授权场景检查60条上限、过期排除、重复同步、取消及范围切换；实际触发两个五秒后闹钟，只允许非静默提醒出现在系统通知中，并读取家长固定文案。拒绝场景先构造旧插件待发记录，再验证当前权限检查删除它。最后均调用生产`initializeApp()`，确认新/旧原生待发和已显示通知为空、未配置服务页面可见。测试只使用合成数据，结束恢复测试前的本机开关。

输出为`build/integration_results/notifications-granted.json`和`notifications-denied.json`。重启检查仅支持专用模拟器，读取系统待发闹钟、执行真实重启，核对boot计数递增及两个原定时间均恢复，输出`notifications-reboot.json`。该场景会保留两个合成未来提醒；后续通知测试或普通包的生产启动会清理它们。测试APK使用独立入口，不能作为交付包；测试结束后重新运行`build_android.ps1 -NoPub -UseChinaMirror`生成普通调试APK。

2026-11-05在AOSP API36 x86_64、Emulator37.2.13、WHPX环境验证：普通闹钟实际显示，静默闹钟被消费但未显示；真实重启后两个未来时刻恢复，无需打开应用。授权/拒绝及生产启动清理的结果分别保存在上述JSON。全量428项Flutter通过，核心覆盖率4276/4905（87.18%），完整分析无问题；18项JVM包含6项任务策略测试，271组数据库检查覆盖至047。测试日志中的额外`tearDownAll`不是业务场景。

## 尚未覆盖的行为

- 已验证模拟器真实闹钟及重启恢复，但没有证明华为鸿蒙4.2/iPhone在后台、强退、节电或厂商限制下准时送达。Android设置中的强行停止会影响系统广播，仍需真机验收。
- Android采用非精确闹钟，不申请精确闹钟特殊权限。系统可能大幅延迟，超过15分钟会被丢弃；这是过期提醒保护，不是准时保证。关机期间错过的提醒不补发。
- iOS本机没有Xcode/iPhone，未完成编译和系统调用验证，后台安静边界仍是缺口。系统通知回执也不保证用户实际看见或听见。

已核对Apple官方说明：[后台本地通知由系统直接显示](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html)，`willPresent`不在后台调用；[通知服务扩展用于远程通知](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/ModifyingNotifications.html)，不能用它补上本地通知的后台拦截。此限制未通过改用高打扰级别或静默隐藏功能来规避。

依据：[Android闹钟与重启恢复](https://developer.android.com/develop/background-work/services/alarms)、[Android通知授权与ADB测试](https://developer.android.com/develop/ui/compose/notifications/notification-permission)、[flutter_local_notifications官方说明](https://pub.dev/packages/flutter_local_notifications)。项目继续使用锁定的22.3.1版本，未为这次验证升级依赖。
