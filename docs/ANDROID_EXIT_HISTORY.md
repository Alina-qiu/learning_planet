# Android 系统退出记录的实际故障验证

日期：2026-11-06。针对PRD第9节运行诊断，在API36专用模拟器上验证实际Java异常、原生崩溃及重启后的诊断处理。生产代码已有系统退出历史采集，本轮没有修改生产采集器、业务Dart或数据库迁移。

## 本次结果

一条跨进程场景的四个阶段全部通过，运行ID为`48a22b6f-4b74-40c6-bb9b-b54241672fbc`。

| 阶段 | 进程PID | 实际行为与检查 |
|---|---:|---|
| java | 2263 | 绑定合成scope后，主线程抛出未捕获Java异常，进程实际退出 |
| native | 2323 | 查询前一进程的系统原因4，生产通道导入一条androidJavaCrash；随后向自身发送SIGABRT，进程实际退出 |
| collect | 2396 | 系统确认第二次原因5；读取Java/Native两条事件，Java事件ID与前阶段相同，多次读取不新增 |
| verify | 2440 | 强制停止上一进程后重开，系统原因10不产生崩溃事件；两条原记录从磁盘恢复，确认、重复读取、范围切换及解绑重绑均不重报 |

调用经过实际`LearningPlanetApplication`、`NativeDiagnostics`、MethodChannel编码和持久化日志，没有注入退出记录或改写诊断状态。系统历史查询只使用PID、原因、时间和进程名，诊断输出严格只有`event_id/day/operation`。测试不读取退出描述、堆栈、trace流或完整系统日志。

系统常量见[ApplicationExitInfo](https://developer.android.com/reference/android/app/ApplicationExitInfo)。系统历史容量有限，不能据此声称每次崩溃都能采到，见[历史进程退出接口](https://developer.android.com/reference/android/app/ActivityManager#getHistoricalProcessExitReasons(java.lang.String,int,int))。

## 复现

启动现有专用`learning_planet_api36`模拟器，端口5580，等待启动完成，再从仓库根目录执行：

```powershell
pwsh -File scripts/test_android_exit_history.ps1 -UseChinaMirror
```

脚本核对模拟器标识、AVD、API36和启动状态，只安装独立包名`com.learningplanet.learning_planet.exitfixture`。显式Gradle属性`exitHistoryFixture=true`才加入`android/app/src/exitFixture`中的Activity和清单，不能与本机后端/ANR测试构建混用，也不能用于profile/release。

测试不启动Flutter业务、不登录、不连接后端。异常及SIGABRT只终止测试包自身；系统对话框只有在标题明确对应测试包时才关闭。结束时强制停止独立安装。

`-SkipBuild`只复用`build/integration_results/native-exit-fixture.apk`，仍核对测试入口和包名。Flutter默认输出在编译后会暂时成为测试APK，执行后须重建普通包：

```powershell
pwsh -File scripts/build_android.ps1 -NoPub -UseChinaMirror
```

交付检查器拒绝缺失生产初始化、包含测试入口或`ExitHistoryFixtureActivity`的APK。本轮实际验证故障包被拒绝，随后重建普通包；三ABI加密库、字体/着色器、测试类排除及v2签名通过。本机联调包未改，重新通过内容检查，摘要见[构建记录](ANDROID_BUILD.md)。

## 证据与边界

- 总报告：`build/integration_results/native-exit-android36.json`，`completed: true`、`status: complete`、`fixture_stopped: true`。
- 四阶段报告：同目录`native-exit-48a22b6f-4b74-40c6-bb9b-b54241672fbc-{java,native,collect,verify}.json`。
- 故障测试APK摘要：`4191511635cd0c96505f55260ab13b97db270a59038d7c6882137ba5c287a2da`，只用于测试。
- 首次故障构建及运行即通过：`tmp/exit-history-first.log`；普通重建/签名：`tmp/exit-history-ordinary-build.log`和`tmp/exit-history-ordinary-signature.log`。
- 完整34项JVM测试重新执行通过，254个Gradle任务均执行，日志`tmp/exit-history-jvm-final.log`。首轮命令参数未加引号，被PowerShell拆分为错误任务名，失败日志`tmp/exit-history-jvm.log`保留，未计为通过。
- 普通包重装后的未配置服务页面已查看，截图`tmp/exit-history-restored.png`、语义树`tmp/exit-history-restored-ui.xml`。系统报告WARM 8124ms，不证明性能改善或达到冷启动要求。

完整静态分析40.9秒无问题，270个Dart文件格式检查无变化，PowerShell/清单解析和报告字段核对通过。首次分析提示来自此前的一次性CI检查脚本，已将它从`tmp/check_ios_ci.dart`移至独立工具目录`D:/learning-planet-tools/check_ios_ci_20261106.dart`，使用显式包配置重新执行成功；没有改变项目检查规则或新增应用依赖。首轮及最终分析日志分别为`tmp/exit-history-analyze.log`和`tmp/exit-history-analyze-final.log`。

这是1条原生适配器场景，包含2次实际故障、4次进程运行，不能计为4条Flutter测试。模拟器为AOSP Android16/API36 x86_64，专用模拟器已关闭；此故障脚本尚未加入远程模拟器CI。

本轮不证明API30以上ANR退出、Android10的C/C++信号、iOS MetricKit、华为鸿蒙4.2或iPhone实际行为，也未验证云端上传和监控告警。Flutter778项、90.94%核心覆盖率和SQL387项沿用此前结果。其余诊断范围见[运行诊断](RUNTIME_DIAGNOSTICS.md)。
