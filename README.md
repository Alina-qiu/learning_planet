# Learning Planet 学习星球

家庭小学生学习成长与游戏化激励 App。首版目标是打通任务、每日自动错题复习、金币与 XP、奖励兑换及家长管理闭环。

## 项目状态

截至 2026-11-27，**Android 本机联调包已可试用**。没有测试手机时，可在电脑的 Android 模拟器里登录、创建家庭、完成任务和复习错题。iOS 已通过未签名 Debug、Release 编译及 iPhone、iPad 模拟器检查。目标手机和云端服务仍待验收。

本机试用请选择 `app-local-debug.apk`，通过 ADB 转发连接电脑的临时服务。普通版 `app-debug.apk` 用于查看服务配置提示。两个包的路径、字节数和 SHA-256 统一记录在本机交付文档中。[本轮安装包和校验](build/review-refresh-20261126/DELIVERY.md) · [启动服务与安装](docs/LOCAL_DEBUG.md)

孩子或家长打开今日复习时，应用会刷新到期题目。孩子首次开始后，题目、顺序和标准答案随本次复习固定。离线开始时如果题目已更新，应用保留原作答供核对，孩子可采用新题单重新作答。孩子自行录入的错题需由家长确认标准答案后才会进入奖励复习。[复习规则与验收](docs/REVIEW_AUTO_COMPLETION.md)

Windows 通过 902 项 Flutter 测试，110 个核心源文件的行覆盖率为 90.89%（7072/7781）。数据库通过 419 项检查和 20 项历史升级检查。PostgREST 16.2 和 16.5 各通过 12 项接口测试，覆盖从错题本直接开始恢复的任务、两端改题、离线作答冲突和奖励核账。[Windows 与接口结果](build/review-refresh-20261126/local-quality.json) · [数据库结果](build/review-refresh-20261126/review-refresh-database.json) · [当前分支 CI](https://github.com/Alina-qiu/learning_planet/pull/1/checks)

- [当前需求覆盖与逐项验收](docs/CURRENT_STATUS.md)：ACC、TSK、ERR、AC-01至AC-11、非功能要求及剩余依赖。
- 常规 CI 覆盖 Flutter、Android 构建、iOS 未签名构建与模拟器、数据库升级和备份恢复。同一家庭的 Android 与 iPhone 同步另设独立验收。[当前分支检查](https://github.com/Alina-qiu/learning_planet/pull/1/checks) · [历史测试记录](docs/TESTING.md)
- [审阅分支与远程验证](docs/REVIEW_CANDIDATE.md)：草稿PR已公开，包含iOS Debug/Release未签名构建、Android构建、数据库/HTTP/Storage及iOS模拟器运行检查；后续提交结果见PR的Checks。
- [本机备份恢复演练](docs/BACKUP_RESTORE.md)：新环境恢复数据库与私有图片/PDF，9项检查通过；目标云端备份仍待验收。
- [开发历史](docs/PROGRESS.md)、[技术架构](docs/ARCHITECTURE.md)与[完整计划](docs/DEVELOPMENT_PLAN.md)。

已登录家庭冷启动后，完整首页需在 6 秒内显示孩子、任务和余额。主要剩余项为云端部署、iOS签名安装、Android 和 iPhone 端到端验证、iOS收到远程提醒后的安静时段检查、真实设备性能、模型评测和四周家庭试用。家长补签和计时纠正已实现，是否扩展为撤回误完成仍待确认。

此前版本还覆盖了[奖励页横屏和大字号](docs/ECONOMY_ACCESSIBILITY.md)、[iPhone 任务提醒](docs/TASK_REMOTE_PUSH.md)、[iOS 诊断与跨进程恢复](docs/RUNTIME_DIAGNOSTICS.md)、[任务列表安全区域](docs/TASK_ACCESSIBILITY.md)、[组卷与上传隐私提示](docs/WORKSHEET_ACCESSIBILITY.md)、[图片导入中断](docs/OCR_INTERRUPTION.md)及[更换图片后重新校对](docs/OCR_SOURCE_CHANGES.md)。[历史记录](docs/README_STATUS_HISTORY.md)

## 技术栈

- Flutter/Dart：Android、iOS客户端，Material界面，Riverpod状态和依赖管理；当前页面使用Navigator导航。
- Supabase：邮箱登录、PostgreSQL事务/RPC/RLS、私有Storage、Cron和Deno Edge Functions。
- Drift/SQLite3MultipleCiphers：按账号隔离的加密缓存、普通任务与复习作答队列、图片草稿及同步回执；flutter_secure_storage保存设备密钥和登录凭据。
- 设备端ML Kit：中文OCR；image_picker/image：图片导入、旋转裁切与增强。
- pinyin_pro_flutter：本地读音候选、轻声、多音字备选及可选“一、不”变调，保存前须家长核对。
- pdf-lib/fontkit：服务端嵌入字体生成确定性PDF；printing/file_picker：客户端预览、打印、分享与保存。
- archive/crypto：CSV及图片索引ZIP打包、文件完整性哈希；导出快照由授权RPC分页提供。
- Kotlin/AlarmManager：Android任务提醒在实际投递前校验家庭时区/安静时段；iPhone任务通过APNs data-only投递，由Swift收到后复查范围、时点和安静策略，再发即时通知。flutter_local_notifications/timezone用于即时通知与时间策略；APNs另提供家长远程消息通道。
- Node脚本及embedded-postgres：隔离数据库回归；Android原生逻辑为Kotlin，iOS为Swift。
- Deno AI网关：最小化题目输入、可替换的模型适配器、严格结构化输出；API密钥仅存服务端。

依赖要求以pubspec.yaml为准：Flutter >=3.38.1、Dart >=3.10.0 <4.0.0；后端测试使用Node >=22。当前采用手写模型与SQL，不需要代码生成；go_router等已声明依赖并不表示业务页面已使用这些实现方式。首次原生构建还需下载sqlite3官方加密库。

## 本机首次初始化

安装满足上述约束的Flutter及Android SDK（iOS构建需要macOS/Xcode），在已有工程中执行：

```powershell
cd D:\文档\Projects\learning_planet
flutter pub get
flutter run
```

现有工程已有平台壳，无需重新运行flutter create。未提供Supabase配置时只会显示未配置提示，不会连接演示后台。

本机已在独立目录安装Android构建依赖，并生成 `build/app/outputs/flutter-apk/app-debug.apk`，签名和包内容检查通过。按当前选择，该包未连接后端；产物校验值、复现命令及配置方式见[Android调试构建](docs/ANDROID_BUILD.md)。

## 验证

```powershell
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test --coverage
node scripts/test_coverage_gate.mjs
node scripts/check_coverage.mjs
npm ci
npm run test:db-version
npm run test:db
npm run test:cleanup
npm run test:account-worker
npm run test:ai
npm run test:pdf-worker
npm run test:pinyin-pdf
npm run check:edge
npm run test:edge
```

当前Windows环境通过英文SDK入口 `D:\learning-planet-tools\flutter` 和工作区入口 `D:\learning-planet-tools\learning_planet` 解决中文路径下的着色器/LSP问题；完整Flutter测试（含资产）和flutter analyze已通过。原项目与SDK未搬动，具体复现方式见[测试说明](docs/TESTING.md)。系统Node若为16，应显式使用Node22以上运行后端测试。

## 目录

- `lib/app`：应用入口、路由和主题
- `lib/core`：配置、同步、通用基础设施
- `lib/features`：按业务功能拆分
- `supabase/migrations`：数据库、行级权限和自动复习任务 RPC
- `docs/DEVELOPMENT_PLAN.md`：完整开发计划
- `docs/ARCHITECTURE.md`：架构和关键约束
- `test`：领域逻辑与界面测试

## 环境变量

不要把密钥写入源码。开发时通过 `--dart-define` 注入：

```powershell
flutter run --dart-define=SUPABASE_URL=https://xxx.supabase.co --dart-define=SUPABASE_ANON_KEY=xxx
```

## Supabase 本地开发

Supabase CLI 作为 npm 开发依赖锁定版本。安装 Docker Desktop 并启动后执行：

```powershell
npm install
npm run db:start
npm run db:reset
npm run db:lint
```
