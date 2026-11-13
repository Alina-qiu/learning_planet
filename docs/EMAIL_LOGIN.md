# 邮箱验证码登录

后续验证：已运行[真实GoTrue与本机SMTP](AUTH_INTEGRATION.md)，5项检查覆盖实际8位邮件、重发限流、错误/重复验证码、刷新与PIN会话、退出、跨家庭、恢复和迟到回执。外部邮箱投递、托管SMTP与指定手机仍待完成；以下客户端实现和历史测试记录保留。

2026-11-05：补齐PRD ACC-01的邮箱验证码入口。此前页面只发送登录链接，缺少输入验证码、校验及重发的完整流程。本次修改客户端及本地Auth配置，不新增数据库迁移，也未连接真实邮箱或Supabase项目。

## 使用流程

1. 输入家长邮箱，去除两端空白并转为小写后发送。请求期间禁用重复操作；页面内重新发送至少间隔60秒，更换邮箱不重置这段等待。
2. 输入邮件中的6至10位数字并明确点击“验证并登录”。支持系统一次性验证码自动填充；不自动提交，不保存验证码到本机数据库或偏好设置。
3. 已收到验证码或重新打开应用时，可选择“已有验证码”，直接输入原邮箱和验证码，无需再发一封邮件。
4. 发送结果不明确时仍保留输入入口：邮件可能已经送达。验证码过期/无效、服务端限流与一般网络错误使用固定中文提示，不展示服务端错误正文、邮箱存在性或Token。
5. 验证成功后由原有AuthGate打开家庭页面；只有拿到有效登录会话才算成功。页面离开或账号改变后，迟到结果不建立旧会话。

前台60秒等待是防止误触的交互限制，重启应用会重置；服务端限流仍独立执行。验证码真正有效期及发送配额由Auth服务控制。验证码提交超时可能已在服务端消费，客户端不会因此悄悄登录；重试若提示失效，需要重新获取。

## 认证与会话隔离

`EmailOtpTransport`每次使用临时GoTrue客户端，关闭自动刷新，不接入持久存储，也不使用PKCE存储。发送通过`signInWithOtp`，校验通过`verifyOTP(type: OtpType.email)`；20秒等待上限不代表底层HTTP已取消。临时客户端等待实际请求结束后才销毁，超时后的结果不能写入应用主会话。

`SupabaseAuthRepository`串行处理登录操作；校验返回后复核页面、仓库、会话变化版本、邮箱归属及令牌剩余时间。只将至少还有60秒的完整会话交给主SDK的`recoverSession`，沿用既有安全会话存储和AuthGate。已锁定的gotrue 2.27.2实现对新鲜会话同步保存，不发起第二次网络请求；回归同时核对请求数量及状态事件。过期/缺失/不同邮箱会话直接拒绝，不能走异步刷新后再覆盖新登录。退出、销毁、其他登录或页面失效都会隔离原校验结果。

现有移动端深链配置保留；新邮件模板只包含验证码。目标为Android/iOS，未提供Web认证入口。临时SDK客户端不用于浏览器多标签认证。

## 服务配置

本地`supabase/config.toml`明确设置邮箱确认、8位验证码、600秒有效期及1分钟重发间隔；`magic_link`与`confirmation`两种邮件使用`supabase/templates/email_otp.html`，内容由Auth服务替换`{{ .Token }}`。本机CLI读取配置后，在容器检查阶段报告缺少Docker/Podman；这只能证明未出现配置解析错误，不代表Auth服务或邮件渲染已经运行。

托管Supabase项目不会因为部署SQL自动应用这些设置。准备项目后，需要在Auth邮件模板中配置对应内容，并设置验证码长度、有效期、频率和邮件供应商；移动端Site URL保持`io.learningplanet.app://login-callback`。模板不硬编码有效分钟数，避免服务配置变化后邮件文案错误。公开URL和anon/publishable key仍通过构建配置注入，不使用service_role。

接口与配置依据：[Supabase验证码流程](https://supabase.com/docs/guides/auth/auth-email-passwordless)、[Dart验证接口](https://supabase.com/docs/reference/dart/auth-verifyotp)、[本地邮件模板](https://supabase.com/docs/guides/local-development/customizing-email-templates)、[CLI邮箱配置](https://supabase.com/docs/guides/local-development/cli/config#auth.email.otp_length)。

## 验证与剩余工作

- 新增14项回归：实际SDK的HTTP参数及会话事件、无额外刷新请求、并发阻止、输入校验、固定错误提示、超时后新账号保留、页面/仓库失效、登录再退出竞争、缺失/过期/邮箱不符会话、完整应用进入家庭、重发和360px双倍字号/键盘滚动。
- 首次定向运行的错误分类断言失败：HTTP夹具缺少Auth API版本响应头，SDK将其当旧版响应读取`error_code`；补齐真实响应头后14项通过，失败记录保留在`tmp/email-login-fixture-version-failure.log`。
- 全量524项Flutter通过，核心覆盖率4909/5555（88.37%，87个源文件）；完整分析无问题，207个Dart文件格式通过。SQL和原生未改，沿用290组数据库与25项JVM结果，不将这些算作真实Auth验证。
- 实际中文字体下的360px普通/双倍字号截图已复核：`tmp/email-login-*.png`、`tmp/email-login-code-*.png`。截图不代替手机自动填充、输入法或邮箱投递验收。
- 仍需真实新/老账号收信、重发/失效/限流、原生安全存储重启恢复、华为鸿蒙4.2和iPhone验收。普通调试APK按用户选择未配置后端，只显示服务配置提示，不开放无效的登录入口。
