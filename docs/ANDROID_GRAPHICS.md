# Android10模拟器图形兼容性

2026-11-05，使用同一个普通调试APK（SHA-256 `317f0414e57b3592614a2602ec5f2133097d2946ea8b2fa1d94f1d194e726cb8`），比较专用API29模拟器的渲染环境。结论：当前SwiftShader环境的fragment uniform上限不足；改用本机Intel GPU后，这组着色器链接错误消失，但随后profile任务测试发生模拟器图形缓冲区等待，尚不能采用host为默认解决方案。应用仍使用Impeller OpenGLES，未修改Flutter引擎或应用渲染配置；Android10图形兼容性未完成验收。

## 环境和观测

- Flutter3.47.4，engine `06a2e2a110089dff50fe635cffd2a61e1b24fbcd`；Emulator37.2.13，AOSP API29 default x86_64 revision8；AVD `learning_planet_api29`，端口5582，WHPX，4核/2GB，1080×2340。
- 三组均使用同一AVD，关闭快照，按顺序完整关闭并启动；APK未改动，各采样一次。失败样本保留，不据此计算优化幅度或性能达标。
- 只读EGL探针见`scripts/fixtures/gles_capabilities.c`。它创建1×1离屏表面，尝试ES2/ES3和0/4倍采样，读取实际上下文与uniform上限。离屏结果不能完整代表Flutter窗口上下文；另核对应用日志中的ES2和Impeller OpenGLES选择。

| 请求后端 | 实际宿主渲染器 | 探针fragment uniform vectors上限 | 同一普通包启动 |
|---|---|---:|---|
| `swiftshader` | Google SwiftShader | 261 | 本次timeout/UNKNOWN，30秒内未确认配置页，TTID为空；先前同包已显示配置页并记录6次uniform链接错误 |
| `swangle` | 仍选择SwiftShader | 261 | COLD 9084ms，确认配置页，6次相同uniform链接错误；不能当成独立ANGLE结果 |
| `host` | Intel Arc B390，驱动32.0.101.8356 | 1024 | COLD 7670ms，确认配置页，0次uniform链接错误；仍有2条`EGL Error: Success (12288)`，无未捕获Dart/Android致命异常 |

三组探针只有ES2、无多重采样的配置可用，系统均公告`ro.opengles.version=131072`。宿主后端没有令该镜像获得ES3或MSAA。普通包host日志仍有EGL配置尝试错误，不能称为零图形错误或全部渲染场景通过。

报告在`build/startup_results/`，分别为`startup-debug-20261104T215956154Z.json`、`startup-debug-20261104T220439967Z.json`、`startup-debug-20261104T220621012Z.json`。本机探针和应用日志另存于`build/startup_results/graphics-api29-20261105/`。早期API29/API36超时记录继续保留，见[构建记录](ANDROID_BUILD.md)。所有报告的`qualifies_for_prd_acceptance`为false。

## 定位依据与处理

报错明确指出`GL_MAX_FRAGMENT_UNIFORM_VECTORS (261)`；261是驱动上限。日志展开的渐变shader声明`colors[256]`和`stop_pairs[128]`等uniform数组。SDK附带的引擎源码`impeller/entity/contents/content_context.cc`显示，非SSBO路径会预创建这些渐变管线，所以仅显示文字的启动页也可能在初始化时触发链接失败。这些证据及同APK的后端对照指向当前引擎与低uniform上限环境的兼容问题，尚不能据此断言所有Android10或华为设备受影响。

API36既有SwiftShader记录保留自己的环境标签。启动测量脚本现记录系统公告的GLES版本和SurfaceFlinger的GLES行；崩溃测试报告也读取实际GLES行，移除固定SwiftShader标签。SurfaceFlinger上下文只作环境证据，不等同Flutter后端。

## API29宿主GPU任务测试未完成

同日构建profile任务场景，应用PID3556启动后持续白屏超过两分钟，驱动未收到测试结果。VM服务可列出isolate，但`getIsolate`在8秒内未响应；不是一个通过的任务测试。线程观测中RenderThread等待`QemuPipeStream::commitBufferAndReadFully → rcOpenColorBuffer2 → gralloc_register_buffer`，Flutter raster等待同一gralloc的mutex，主线程停在`FlutterJNI.onSurfaceCreated`。这把本次停顿缩小到模拟器图形缓冲区链，但单次栈不能证明具体宿主驱动缺陷。

仅在专用AOSP模拟器通过`su 0 debuggerd -b 3556`采集栈；未改变应用权限或ADB运行身份。随后主动force-stop结束无进展的测试，驱动exit1。失败日志、白屏截图、栈和`completed=false`观察记录保存在`build/integration_results/task-flow-api29-host-incomplete/`。没有添加通过场景，也未覆盖原API36报告；原报告与截图另备份到`task-flow-api36-original/`。

## API29软件后端任务验证

完整关闭host模拟器后，以原`-gpu swiftshader`启动同一AVD；重新构建同一任务场景，仅把编译的设备标签改为实际软件后端。驱动exit0，1,000条任务、完成先持久提交、远端不回复时余额不提前增加、KeyStore/加密SQLite及关闭重开后同命令ID和任务投影全部通过。1倍/2倍字号截图已复核，2倍字号保留滚动位置，AppBar标题省略。此次是同一个任务场景在第二个API上的复测，累计场景仍为5条，另有1条重启检查。

报告和截图存于`build/integration_results/task-flow-api29-swiftshader/`；当前根目录`task_flow.json`也是这次结果，原API36数据在上述备份目录。profile测试包SHA-256为`9d9d0ccff2d84e1d563b638bc96ad8b97e371ad4452652dbf4e38ee25a4894f2`，不能作为普通用户安装包。

本次仍有6次uniform链接错误和相应多行shader转储，无未捕获Dart/Android致命异常。任务页面显示不等于所有渐变/图形路径正常。绘制平均32.833ms、P90为47.776ms，20帧超过测试工具的绘制预算，性能未达标；这次通过仅覆盖断言所述的功能与本机存储行为。该结果也不证明host白屏与某个GPU开关存在必然因果关系。

测试结束恢复同一普通debug包，内容检查与摘要一致；API29/SwiftShader配置页COLD 9516ms且语义核对通过，6次uniform错误仍在，无未捕获致命异常或阶段计时输出。报告`startup-debug-20261104T221637785Z.json`单独保存，未混入前面3个后端对照。已移除确切路径的临时探针，并停止本轮专用模拟器和独立Gradle守护进程。

需继续在华为鸿蒙4.2和iPhone实测；若指定设备出现同类错误，再依据实际GPU/驱动、引擎日志和复现页面选择引擎版本或设备级处理方案。当前没有全局关闭Impeller、提高最低Android版本或删除页面绘制功能。

## 重复探针

先启动专用模拟器并确认`sys.boot_completed=1`。以下只编译和运行诊断程序，不读取业务数据库或网络；远端仅删除本次程序的确切路径：

```powershell
$sdkRoot = 'D:/learning-planet-tools/android-sdk'
& "$sdkRoot/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe" --target=x86_64-linux-android29 -Wall -Wextra -Werror -fPIE -pie scripts/fixtures/gles_capabilities.c -o tmp/gles-capabilities -lEGL -lGLESv2
& "$sdkRoot/platform-tools/adb.exe" -s emulator-5582 push tmp/gles-capabilities /data/local/tmp/lp-gles-capabilities
try {
    & "$sdkRoot/platform-tools/adb.exe" -s emulator-5582 shell chmod 755 /data/local/tmp/lp-gles-capabilities
    & "$sdkRoot/platform-tools/adb.exe" -s emulator-5582 shell /data/local/tmp/lp-gles-capabilities
} finally {
    & "$sdkRoot/platform-tools/adb.exe" -s emulator-5582 shell rm -f /data/local/tmp/lp-gles-capabilities
}
```

命令的编译目标限定本机x86_64/API29模拟器，不是手机应用库。模拟器后端选项参照[Android官方图形加速说明](https://developer.android.com/studio/run/emulator-acceleration)，Flutter后端参照[Impeller说明](https://docs.flutter.dev/perf/impeller)。

## ANR补充后的普通包启动复查

2026-11-05，普通APK SHA-256 9aca693a717032156849f42361494ee2b6744c5190c2d1b39035b6a5b0ee8f23 在同一API29/WHPX/SwiftShader环境安装。首次启动timeout/UNKNOWN并显示白屏，VM服务getVM可响应，但main isolate查询超时；未据此认定应用逻辑或图形线程的具体根因。停止应用进程后同包重试COLD 6276ms，配置页语义和截图核对通过，原生诊断scope为空。重试仍有6次fragment uniform链接错误及2条EGL Error: Success，未修改应用渲染配置。

报告build/startup_results/ordinary-anr-update-20261105.json，首次证据tmp/android-ordinary-first-launch.log、android-ordinary-first-launch-runtime.log和android-ordinary-first-launch.png；重试证据tmp/android-ordinary-launch-latest.log、android-ordinary-runtime-latest.log、android-ordinary-ui-latest.xml和android-ordinary-latest.png。这是一次失败加一次重试，不是性能优化对照；启动稳定性、图形兼容性及指定手机验收仍未完成。原生ANR场景使用独立原生测试Activity，其通过不证明Flutter渲染已修复。
