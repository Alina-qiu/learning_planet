# 本地真实验证码登录验证

后续同日已增加[真实Storage/S3图片集成](STORAGE_INTEGRATION.md)。本页5项登录测试继续独立运行，共用服务启动逻辑抽到 `scripts/fixtures/auth_backend.mjs`；下方“未覆盖Storage”仅指本页登录套件，图片证据单独记录。

2026-11-05：5 项集成检查通过，实际执行 24 次 Auth 请求、33 次 PostgREST 请求，接收 7 封本机 SMTP 邮件。使用 Supabase Auth/GoTrue 2.196.0、PostgreSQL 15.19、PostgREST 16.2，加载 Auth 的 70 份官方迁移和 App 的 66 份迁移（至064）。用户、验证码、刷新令牌及登录会话均由真实 Auth 服务创建，不预置用户或伪造用户 JWT。

## 已验证

- App 的 `SupabaseAuthRepository` 和 `EmailOtpTransport` 发送与验证邮箱验证码；大小写/空格归一化，读取项目实际中文邮件模板，验证码8位，重复发送被限流，错误和已用验证码被拒绝。
- 实际刷新令牌后 `session_id` 保持不变，当前会话的家长 PIN 仍有效；同邮箱另一次登录产生不同会话，不能继承 PIN。
- App 退出后撤销当前 PIN，刷新令牌最终不可用；另一个登录会话仍可使用。旧访问 JWT 的 PIN 写权限被拒绝，不宣称所有旧 JWT 在任何服务中立即失效。
- 两个真实 Auth 用户的家庭、孩子读取及修改隔离；恢复服务端真实签发的会话后，可再次刷新令牌并读取原家庭。
- Auth 已成功验证验证码，但 HTTP 回执被延迟到 App 超时之后，迟到结果不能自动登录主客户端；该验证码在服务端已消费，重试被拒绝。

脚本读取 `supabase/config.toml` 的登录地址、注册/确认设置、验证码长度/有效期、发送间隔及邮件标题，并使用 `supabase/templates/email_otp.html`。保持每地址1分钟间隔与600秒有效期；为允许多名独立测试用户，将本机服务的全局邮件额度提高到1000，未用此配置覆盖真实云端限额。测试没有等待10分钟验证自然过期。

## 本机运行

Node >=22、Flutter依赖已安装，独立工具不修改系统 PATH：

```powershell
$env:GOTRUE_BIN = 'D:/learning-planet-tools/supabase-auth-source/auth-2.196.0/auth.exe'
$env:POSTGREST_BIN = 'D:/learning-planet-tools/postgrest-16.2/postgrest.exe'
$env:FLUTTER_BIN = 'D:/learning-planet-tools/flutter/bin/flutter.bat'
& 'C:/Users/qiuya/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' scripts/test_auth.mjs
```

在 Node >=22 已位于 PATH 的环境中，也可执行 `npm run test:auth`。`test:http` 继续独立运行7项业务接口场景；两者共用本地进程/代理和数据库引导，但前者默认使用合成 Auth schema，本测试通过回调先运行官方 Auth 迁移。Storage 仍只有基础 schema。

HTTP 和 SMTP 均只监听 `127.0.0.1`。SMTP 接收器仅接受 `@example.test` 合成地址，不向外转发；邮件保存在内存，读取接口需要本轮随机密钥，结束时清空。Auth 使用受限 `supabase_auth_admin` 角色管理自己的 schema，PostgREST 使用受限连接角色；服务不读取项目 `.env`、托管密钥或已链接项目。结束后关闭服务和数据库；Windows 临时数据库保留合成测试数据供诊断。

## Windows 工具来源与适配

本机没有可运行的 WSL/Docker，使用 [Auth 2.196.0 官方源码](https://github.com/supabase/auth/tree/v2.196.0)和 [Go 1.26.10](https://go.dev/dl/) 编译。源码最低要求 Go 1.26.5；Go 安装在 `D:/learning-planet-tools/go-1.26.10`，构建缓存和模块缓存也位于独立工具目录。

源码中的 Unix `SO_REUSEPORT` 调用不能在 Windows 编译；[监听补丁](../scripts/fixtures/gotrue-windows.patch)将它改为普通单监听器，删除对应的 Unix 导入。没有修改验证码、会话、API处理、权限或迁移。已逐文件与下载源码 ZIP 比较，仅 `cmd/serve_cmd.go` 不同；补丁反向检查通过。补丁保留 LF 和标准 diff 上下文空白，以便在新源码副本上应用。

对新下载的源码副本，先执行 `git apply --check` 和 `git apply` 应用该补丁，再使用下列构建参数；当前本机副本已经应用，不要重复应用：

```powershell
$env:GOPATH = 'D:/learning-planet-tools/go-work'
$env:GOCACHE = 'D:/learning-planet-tools/go-cache'
$env:GOTOOLCHAIN = 'local'
$env:CGO_ENABLED = '0'
# 在源码目录运行；镜像仅用于公开模块传输，保留 go.sum 校验。
$env:GOPROXY = 'https://goproxy.cn,direct'
& 'D:/learning-planet-tools/go-1.26.10/go/bin/go.exe' build -trimpath -ldflags '-X github.com/supabase/auth/internal/utilities.Version=v2.196.0-windows-local' -o auth.exe .
```

校验记录：

| 文件 | SHA256 |
|---|---|
| 官方源码 `supabase-auth-v2.196.0.zip`（本机下载记录） | `11c77d3b64c5bb88517ba0e207cfab1494dbc21a3f656ea4917dd507261df12c` |
| Go Windows ZIP（官方发布值） | `7ecd2d7260e82c59bcbd7f1077a07cee2dea607295b858df67195a1e4e09629b` |
| 本机 Windows Auth 二进制 | `a2bf1c3eafd2f1347a09575f797dbc3c51105987cf8d9c7ceec3e334b1a8c8ea` |
| 官方 Linux Auth amd64 tar.xz | `0d35d4c06a9ae673d06bc8579aeef6bba6f7551fa7842f9fcdac33ec926e360c` |

CI 的16.2分支下载并校验[官方 Linux 发布包](https://github.com/supabase/auth/releases/expanded_assets/v2.196.0)，执行相同的 `test:auth`；不使用 Windows 补丁。发行包文件布局和摘要已在本机核对，远程 Linux CI 尚未运行。

## 验证记录与剩余范围

成功日志：`tmp/auth-integration-latest.log`。首次模块下载连接超时，改用镜像后完成；Windows监听编译失败日志为 `tmp/auth-windows-listener-failure.log`。首次超时场景错误地把邮件发送也限制为300毫秒，分离准备步骤后通过，原日志为 `tmp/auth-timeout-fixture-failure.log`。临时CI检查脚本的分析提示及两处测试花括号已修正，完整分析通过（28.9秒），254个Dart文件格式通过。

共用引导/HTTP帮助函数调整后，原375组数据库和7项/88次业务HTTP检查再次通过。5项真实Auth检查单独计数，714项Flutter单元/Widget、90.47%核心覆盖率为此前记录；本轮业务代码和普通APK未改变。

尚未覆盖真实邮件投递到外部收件箱、托管SMTP限额、云端网关API key验证/HTTPS、外部SMTP的TLS、Storage、原生凭据持久化、华为鸿蒙4.2/iPhone或iOS编译。普通APK仍未配置Supabase，只显示服务配置提示；上述服务和合成用户不会打入APK。这是本地登录服务的实证，不能视为完整云端或两端手机验收。
