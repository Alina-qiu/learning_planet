# 本地真实删除与注销验证

2026-11-05：7组集成检查通过，实际执行16次Auth、63次PostgREST和51次Storage请求，接收2封本机合成邮件。10个真实S3图片对象中，目标孩子和注销用户的6个对象被删除；其他成员的4个对象及SHA256保持不变。日志：`tmp/privacy-integration-latest.log`。

## 修复的问题

真实Storage1.72.1删除对象后，HEAD返回HTTP400，无法携带“文件不存在”的JSON正文；元数据GET同样返回HTTP400，但正文为 `statusCode: "404"`、`code: "NoSuchKey"`、`message: "Object not found"`。固定的storage-js2.99.1将HEAD结果转换为 `data:false` 和状态400错误。原清理worker仅接受404，因此真实文件已删除，任务仍会落入 `STORAGE_VERIFY_FAILED`，并阻止后续账号注销。

现由[共享清理worker](../supabase/functions/_shared/cleanup_worker.mjs)对这种含糊的HEAD400再调用 `info()`：只接受明确的对象不存在错误。SDK优先保留数字statusCode，因此兼容“404 + Object not found”和新式NoSuchKey；元数据结果必须为null，HTTP错误状态必须为400/404。通用400、桶不存在、403、5xx、网络异常、仍存在的对象和空成功响应均不作为删除完成证明。原HEAD404路径和SQL最终核查继续保留。

该差异在真实本机服务复现，记录于 `tmp/privacy-storage-head-400-failure.log`。上游[Storage错误说明](https://supabase.com/docs/guides/storage/debugging/error-codes)明确区分NoSuchKey、NoSuchBucket与InvalidRequest；本次还核查了下载的1.72.1错误处理源码及本机缓存的2.99.1 SDK，未修改供应商的业务代码来让测试通过。

## 已验证的服务流程

| 场景 | 证据 |
|---|---|
| 用户、家庭与图片 | 两个OTP真实用户，经公开邀请/接受接口加入共享家庭；通过实际RPC及Storage上传10个图片对象 |
| 按孩子删除等待期 | 同一请求重放不重复删除；他人不能领取，普通用户不能触发drain；10分钟窗口到期前任务queued，S3字节不变 |
| 按孩子永久清理 | 原始Edge入口使用固定SDK删除原图/处理图、验证不存在并完成SQL事务；旧签名链接不可读，兄弟姐妹和其他家庭图片保留，客户端伪造manifest无效 |
| 文件失败与账号依赖 | 注销为剩余孩子创建清理任务；阻断真实删除请求时，子任务失败，账号任务保持WAITING_FILE_JOBS，Auth用户和实际文件仍在；恢复后可重试 |
| Auth成功但回执丢失 | 文件清理成功后，真实Auth Admin硬删除已提交，测试代理丢弃一次成功回执；任务保留AUTH_DELETE_FAILED供重试，数据库确认用户已不存在 |
| 恢复与完成 | 后续重试识别真实Auth“用户不存在”响应，并经SQL独立核查完成、清空manifest；旧访问会话和刷新令牌被拒绝，再次drain无任务 |
| 共享家庭边界 | 注销用户在共享家庭上传的图片移除，家长编辑后的错题与其他成员图片保留；其他成员仍能登录，旧图片UUID不能重新创建 |

API发起与检查脚本是Node，服务端使用真实GoTrue2.196.0、PostgREST16.2、Storage1.72.1、PG15.19和MinIO，加载70份Auth、68份Storage及66份App迁移。Deno2.9.6加载原 `permanent-cleanup` / `account-deletion` 入口和Supabase JS2.99.1；测试引导仅绑定回环端口并提供waitUntil保活，不是Supabase Edge Runtime容器。

测试调用可信drain模拟调度，不实际安装Cron。为了验证等待门槛与失败恢复，仅把本轮合成任务的next_attempt_at调整到过去；没有缩短生产配置，也没有等待24小时。因此本结果不证明线上清理时限、调度可靠性或云备份已删除。

## 运行与自动化

先按[本机Storage工具说明](STORAGE_INTEGRATION.md)准备Node24、GoTrue、PostgREST、Storage和MinIO。使用同样四个服务环境变量，无需Flutter客户端参与本套件：

```powershell
$env:POSTGREST_BIN = 'D:/learning-planet-tools/postgrest-16.2/postgrest.exe'
$env:GOTRUE_BIN = 'D:/learning-planet-tools/supabase-auth-source/auth-2.196.0/auth.exe'
$env:STORAGE_SOURCE = 'D:/learning-planet-tools/supabase-storage-source/storage-1.72.1'
$env:MINIO_BIN = 'D:/learning-planet-tools/minio-2025-09-07/minio.exe'
# 首次运行先缓存固定SDK并检查原始入口。
& node_modules/deno/deno.exe check --config supabase/functions/worksheet-render/deno.json supabase/functions/permanent-cleanup/index.ts supabase/functions/account-deletion/index.ts
& 'C:/Users/qiuya/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' scripts/test_privacy_integration.mjs
```

Node24位于PATH时可使用 `npm run test:privacy`。复用真实Auth/Storage隔离环境，只在本套件为临时PostgREST连接授权service_role；随机服务凭证仅传给本机Deno服务，不传给Flutter或写入APK。API、SMTP和S3仅绑定127.0.0.1，临时账号使用example.test；测试结束关闭服务。

CI的storage-integration作业在原5项图片测试后缓存/检查Edge依赖，再运行此套件。源码/工具版本及摘要沿用Storage记录。CI配置已完成本机解析检查，远程Linux作业尚未运行。

共享worker新增13个针对元数据确认和拒绝条件的检查，合计24项通过；原10项注销worker、两个固定SDK/Deno本地HTTP替身检查、两入口类型检查和375组数据库回归通过。共用引导调整后的原5项真实图片上传/访问测试也再次通过（31次Storage请求、8个对象）。这些与7组真实服务场景分别计数。714项Flutter单元/Widget、90.47%核心覆盖率及普通APK沿用此前记录；本轮业务修改仅在服务端worker，未重建APK。

测试开发中的空档案参数、void RPC的204、注销预览scope层级及未先处理依赖清理任务问题已修正；相应失败日志位于 `tmp/privacy-fixture-*-failure.log`，不将它们归因于应用缺陷。真正的服务兼容性缺陷是前述HEAD400验证。

本套件未覆盖真实云端网关/HTTPS、线上Cron及24小时期限、云备份、多设备离线缓存、系统临时文件、华为鸿蒙4.2/iPhone与iOS构建。PDF实际生成、过期及源题关联文件清理已由后续[PDF集成](PDF_INTEGRATION.md)补充；普通APK仍未配置Supabase。
