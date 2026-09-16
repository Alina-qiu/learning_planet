# Learning Planet 学习星球

家庭小学生学习成长与游戏化激励 App。首版目标是打通任务、每日自动错题复习、金币与 XP、奖励兑换及家长管理闭环。

## 项目状态

开发计划“阶段 0：工程准备”的代码工作已完成：Flutter Android/iOS 平台壳、领域模型、三环境配置、每日错题复习任务生成逻辑、Supabase 数据库迁移、测试样例和跨平台 CI 均已建立。平台构建是否达到出口条件以 GitHub Actions 的 Android 和 iOS 构建结果为准。

## 本机首次初始化

当前创建环境未安装 Flutter SDK。安装 Flutter 3.24 或更高稳定版后执行：

```powershell
cd D:\文档\Projects\learning_planet
git add .
git commit -m "chore: establish Flutter project baseline"
.\scripts\bootstrap.ps1
flutter run
```

引导脚本会拒绝未提交或不干净的工作区。`flutter create .` 主要用于补齐 Android/iOS 平台壳和工具配置；执行后必须检查 `git diff`，如生成器改动了现有业务文件，应保留本项目版本并仅接收平台文件。

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
