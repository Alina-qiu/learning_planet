# 首页与任务列表的大字号和安全区域

2026-11-06，对应PRD第9节“核心任务完成入口单手可达”“支持系统字体放大”及同步失败不阻塞本地打卡。需求文件SHA256仍为`4add57b35086b4281ab9651d43203e0dae27e7df2cc61614aefc8796e1324320`，没有扩大到新增业务模块。

## 问题与改动

实际页面在640×320、双倍字号、长同步说明组合下，任务管理页原先固定在列表上方的同步卡片导致底部溢出72px，任务列表没有足够显示空间。首页横屏任务卡片的左边界为16px，而系统侧边安全区域为48px，内容进入了系统区域。修正测试程序后的复现见`tmp/task-layout-reproduction-corrected.log`；360×800竖屏对照通过。

[任务管理页](../lib/features/tasks/presentation/task_management_screen.dart)改用同一个`CustomScrollView`承载同步提示、忙碌状态和任务列表。同步说明可随页面滚动，保留列表按需构建、任务键、优先级排序、下拉刷新、家长权限和原操作回调；未把所有任务一次性展开。读取中和错误状态也放在可滚动区域内。

[首页](../lib/features/home/presentation/home_screen.dart)和任务管理页的内容都加入`SafeArea(top: false)`，由已有AppBar处理顶部，正文避开系统左右及底部区域。没有缩小正文、限制系统字体缩放、修改任务状态机或奖励规则。

## 验证结果

新增[test/task_layout_test.dart](../test/task_layout_test.dart)4项检查，使用360×800与640×320、双倍字号、顶部24px/底部48px或左右48px系统区域：

- 首页末尾任务卡片和按钮位于安全区域内，按钮可点击并进入原任务管理回调。
- 长同步说明不会挤掉任务操作，滚动后完成按钮位于可点击区域内。
- 实际`OfflineTaskRepository`与内存SQLite接收完成操作，恰好保存一条`complete`命令；不发起网络请求，钱包仍是此前确认的100金币。

布局测试用合成任务和同步状态，长说明采用未知错误的现有安全提示；它检验最不利文案高度，不代表本轮发生了真实服务器拒绝。完成命令使用实际离线仓库，页面数据/网络及设备边距为测试环境，不能等同手机无线断网或重启。

相关82项通过（`tmp/task-layout-related.log`），包含旧复习记录导航、家长补签/计时纠正、备注、任务开始来源、计划和完成反馈。完整804项Flutter通过，用时1分23秒；其中既有千任务列表按需构建及“完成后任务行移动”检查也通过。

核心覆盖率6517/7167（90.93%，107文件，门槛80%）通过；完整静态分析31.8秒无问题，274个Dart文件格式检查无变化。日志为`tmp/task-layout-full-tests.log`、`tmp/task-layout-coverage.log`、`tmp/task-layout-analyze.log`及`tmp/task-layout-format.log`。本轮没有重跑SQL或JVM，387项SQL和34项JVM仍为此前结果。

本轮[证据索引](../build/task_layout/results.json)关联源文件、实际通过日志、截图与APK摘要，并明确`goalComplete=false`；它是已完成本机运行的索引，不是新的设备或云端验收报告。

已使用实际页面、应用主题、Noto中文字体及Material图标生成并查看五张横屏图片：`tmp/task-layout-home-1x.png`、`tmp/task-layout-home-2x.png`、`tmp/task-layout-completion-1x.png`、`tmp/task-layout-completion-2x.png`、`tmp/task-layout-sync-header-2x.png`。长卡片可滚动查看，截图中的上下裁切为当前滚动位置；操作按钮已移出同步提示占用的区域，左右系统区域保持留白。截图脚本`tmp/capture_task_layout_test.dart`及通过日志`tmp/task-layout-capture-final.log`仅用于本机视觉检查。

初次测试曾错误地把Tooltip组件的40px高度当作整个点击区域，并在真实SQLite异步操作中混用了测试时钟；这两项属于测试问题。已将SQLite场景放入完整`runAsync`，按实际可点击位置验证。等待中的测试进程明确终止并确认退出；期间另一次测试因SQLite DLL占用未能启动。截图脚本也修正了在惰性列表尚未生成目标时使用`.first`的问题。相关失败日志保留，没有作为应用缺陷或成功证据。

普通及本机Android包已重建并通过内容、v2签名及摘要检查，结果见[构建记录](ANDROID_BUILD.md)。构建用临时后端已正常退出，该空库启动不增加业务联调证据。本轮ADB列表为空，没有设备安装。本机Widget和截图不替代华为鸿蒙4.2/iPhone、真实系统字体/读屏、手持操作或性能验收；云端、iOS后台安静时段及完整交付范围仍以[当前状态](CURRENT_STATUS.md)为准。
