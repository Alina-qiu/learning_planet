# 本地真实 HTTP 集成验证

补充：账号链路另有[真实Auth/SMTP检查](AUTH_INTEGRATION.md)，使用官方Auth迁移与实际服务签发会话。本文7项业务检查继续使用合成会话，两个命令独立运行，避免混淆验证范围。

2026-11-05：已对齐 `supabase/config.toml` 的 PostgreSQL 15。固定 `embedded-postgres@15.19.0-beta.19` 后，实际 PostgreSQL 15.19 上的 375 组数据库检查通过；PostgREST 16.2、16.5 两组各有 7 项集成测试/88 次请求通过，均加载全部 66 份迁移（至 064）。客户端使用 App 的 Supabase Dart SDK 和业务 Repository。没有修改业务 Dart、SQL 或原生代码，本轮无需重建 APK。

## 覆盖的流程

- 建家、中文和 emoji 数据、孩子教材标签、PIN 建立与撤销；同账号另一会话不能继承 PIN，另一家庭不能读取钱包。
- PostgREST 验证过期/伪造 JWT；匿名调用、直接修改家庭时区及私有结算函数均被拒绝。
- 实际任务 Repository 创建并生成任务、开始/暂停/继续/完成；重复完成只结算一次。
- 复习四参数兼容接口与五参数作答把握接口均能由 SDK 正确调用；最后一题自动完成，三题合计 45 金币/45 XP，重复调用不增加奖励。
- 实际 `OfflineTaskRepository`、`CachedReviewRepository` 和文件 SQLite：离线保存开始、答案及完成命令，关闭并重新打开数据库；服务端已提交答案后模拟丢失 HTTP 回执，再同步，最终只获得 15 金币且保留把握值 2。
- 实际家庭时区 Repository 解析 JSON 回执，原版本/原目标重试成功，旧版本覆盖其他目标返回 `40001`，可按新版本改回。

测试过程中不以手工 SQL 代替上述业务请求。数据库初始化只负责角色、合成用户、Auth/Storage 基础 schema 和应用迁移。薄代理仅去除 SDK 固定的 `/rest/v1` 前缀，原样转发请求与响应；若调用 Auth 或 Storage HTTP 路径，整组验证失败。

## 执行

使用 Node.js 22 或以上（本机验证使用独立 Node 24.22.1，CI 使用 22），先安装项目依赖（`npm ci`、`flutter pub get`），并取得 [PostgREST 16.2 官方二进制](https://github.com/PostgREST/postgrest/releases/tag/v16.2)。16.2 对应本机 Supabase CLI 2.117.0 中的镜像版本；另保留 [16.5](https://github.com/PostgREST/postgrest/releases/tag/v16.5) 检查。本机文件在独立工具目录，未修改系统 PATH。

```powershell
$env:POSTGREST_BIN = 'D:/learning-planet-tools/postgrest-16.2/postgrest.exe'
$env:FLUTTER_BIN = 'D:/learning-planet-tools/flutter/bin/flutter.bat'
npm run test:http
```

本机系统 PATH 中的 Node 为 16，执行检查需显式使用已安装的独立运行时：

```powershell
& 'C:/Users/qiuya/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' scripts/test_database.mjs
& 'C:/Users/qiuya/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' scripts/test_postgrest.mjs
```

也支持 PATH 中的 `postgrest` 和 `flutter`。脚本只监听 `127.0.0.1`，随机分配本地端口，不读取 `.env` 或已链接项目；合成 JWT 密钥每轮随机生成。连接角色为 `NOINHERIT`，仅获准切换 anon/authenticated，不授予 service_role；角色设计依据 [PostgREST 官方授权说明](https://docs.postgrest.org/en/stable/references/auth.html)。Windows 的 libpq 来自隔离 PostgreSQL 原生运行库，仅加入子进程 PATH。测试结束关闭 HTTP、PostgREST 和数据库，Windows 临时数据库及测试 SQLite 文件保留用于诊断；其他平台由 embedded-postgres 清理它创建的临时库，不删除工作区数据。

独立 CI 作业 `http-integration` 用 16.2/16.5 矩阵固定 Linux 二进制并校验 SHA256，执行相同命令；CI 配置已加入仓库，本机未触发或验证远程 CI。校验值来自官方 [16.2 附件](https://github.com/PostgREST/postgrest/releases/expanded_assets/v16.2)和 [16.5 附件](https://github.com/PostgREST/postgrest/releases/expanded_assets/v16.5)：

| 文件 | SHA256 |
|---|---|
| 16.2 Windows x86-64 zip | `f27c3fd12bb6f3a2ff6f7b3283d4fe63ef2a74f718c030cdd387f768ceb15ab9` |
| 16.2 Linux static x86-64 tar.xz | `4712595baae0f5d84a527d55a11166d6bf4d9b0f1d102505c5e9d59219787f08` |
| 16.5 Windows x86-64 zip | `17f595b0d8dd37473d0231417dea07c5ac9f791282ff5b017fae51ff29e5de2f` |
| 16.5 Linux static x86-64 tar.xz | `5099e7ada38f9f6846cd87c14c5f158b7c165f1e9959665ad412e61f4dceba95` |

共用数据库引导在迁移前读取 `SHOW server_version` 等价的实际配置值，并与 `supabase/config.toml` 的主版本比较；不匹配即失败，停止临时数据库。`npm run test:db-version` 用真实数据库和不匹配的临时配置证明迁移尚未执行、监听端口已释放，CI 数据库作业先运行这项检查。这样依赖或项目主版本改动后，不会默默在错误版本上继续验证。

## 证据与边界

最新日志为 `tmp/database-postgres15-latest.log`、`tmp/postgrest16.2-postgres15-latest.log`、`tmp/postgrest16.5-postgres15-latest.log` 和 `tmp/database-version-gate-latest.log`。第一次 HTTP 验证曾使用 PostgreSQL 18.4/PostgREST 16.5（`tmp/postgrest-test-latest.log`）；已完成上述版本对齐，历史证据保留。最早 Windows 启动批处理的引号错误记录为 `tmp/postgrest-launch-fixture-failure.log`，修正后通过。PostgreSQL 15 依赖安装完成；系统 npm 曾报告 Node 16 引擎警告，正式测试与锁文件同步已使用独立 Node 24，项目也声明 Node >=22。

同一套 7 项在两个接口版本各运行一次，不能算作 14 个不同场景，也不能并入既有 714 项 Flutter 单元/Widget 全量结果；90.47% 核心覆盖率沿用此前报告。业务代码没有变化，完整静态分析沿用前轮通过结果。本次证明 PostgreSQL 15 主版本及两个 PostgREST 版本下的本地兼容性，不证明托管服务补丁版本、预装扩展、真实 Auth/Storage 或网关配置一致。

会话由测试签发并恢复到 SDK，不包含真实 GoTrue 登录、邮箱收信、刷新令牌、Storage 上传或网关 API key 校验。文件 SQLite 验证持久队列语义，不代表设备安全存储或进程被系统结束的验收。华为鸿蒙 4.2、iPhone、HMS/APNs、iOS 编译及正式 Supabase 项目仍需实际环境验证。普通调试 APK 继续使用生产入口，未配置后端时显示服务配置提示，不包含这个测试后端或合成会话。
