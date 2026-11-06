# 本地真实图片存储验证

后续同日新增[真实删除/注销链路](PRIVACY_INTEGRATION.md)，补齐原Edge入口、实际S3字节删除和Auth硬删除证据，并修复清理worker的HEAD400兼容问题。本页保留5项上传/访问套件的独立记录。

2026-11-05：5项集成检查通过，执行12次Auth、60次PostgREST和31次Storage请求，接收6封本机测试邮件；真实S3后端保存8个非空图片对象，与8行Storage元数据一致。成功日志为 `tmp/storage-integration-latest.log`。

## 链路与范围

实际Flutter SDK及 `SupabaseQuestionMediaRepository` / `SupabaseChildSubmissionRemote` → 回环HTTP代理 → GoTrue 2.196.0、PostgREST 16.2、Supabase Storage 1.72.1 → PostgreSQL 15.19和本机MinIO S3后端。运行70份Auth官方迁移、68份Storage官方迁移及66份应用迁移（至064）。本测试用官方Storage表结构取代原SQL测试中的简化表；用户和会话由真实验证码登录创建。

| 场景 | 实际结果 |
|---|---|
| 孩子提交/家长确认 | 原图、处理图上传并按字节读回；待确认时没有正式错题、复习任务或金币；未授权确认被拒绝；输入家长PIN后只生成一道题，相同请求重放不重复保存，随后可生成复习任务 |
| 私有图片 | 他人账号不能下载、签名或上传到该目录；公开链接和未登录访问失败；签名篡改失败；本人仍可读原图 |
| 上传回执丢失 | 在真实上传完成后丢弃一次响应；原仓库再次上传稳定路径，兼容Storage实际重复对象响应，最终仅两个图片文件；再次保存不重复，覆盖原图被拒绝 |
| 文件限制/不完整提交 | 桶限制拒绝非图片MIME和超过10MiB的文件；缺少图片不能提交错题；未生成图片元数据或正式错题 |
| 家长直接录入 | PIN授权后，原媒体仓库记录识别内容、保存错题并关联原图和处理图，签名读取处理图得到原字节 |

测试图片由本机生成的小型PNG组成。服务级上传上限在此套件设为50MiB，让应用迁移中的10MiB桶限制独立接受验证；实际拒绝10MiB加1字节的上传。没有调用OCR供应商，也没有证明真实教材/手写识别质量。Storage中的MIME限制是接口声明类型校验，不能据此宣称服务端完整解码检查了每张图片。签名使用App现有300秒有效期，测试覆盖签名篡改，但未等待300秒验证自然过期。

## 运行

Storage 1.72.1源码要求Node >=24、npm >=11.12.1；其他已有接口测试仍支持Node >=22。所有服务绑定 `127.0.0.1`，临时数据库、对象目录、JWT和S3密钥每轮独立生成；使用受限的Auth、Storage和PostgREST数据库角色。测试不读取工作区 `.env` 或已链接云项目。SMTP仅收取 `@example.test` 合成地址的本机邮件，无法向外转发。

本机已经准备独立工具，不修改系统PATH：

```powershell
$env:POSTGREST_BIN = 'D:/learning-planet-tools/postgrest-16.2/postgrest.exe'
$env:GOTRUE_BIN = 'D:/learning-planet-tools/supabase-auth-source/auth-2.196.0/auth.exe'
$env:STORAGE_SOURCE = 'D:/learning-planet-tools/supabase-storage-source/storage-1.72.1'
$env:MINIO_BIN = 'D:/learning-planet-tools/minio-2025-09-07/minio.exe'
$env:FLUTTER_BIN = 'D:/learning-planet-tools/flutter/bin/flutter.bat'
& 'C:/Users/qiuya/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' scripts/test_storage.mjs
```

Node24位于PATH且工具变量已配置时，也可运行 `npm run test:storage`。入口复用 `scripts/fixtures/auth_backend.mjs` 的真实登录服务，图片后端在应用迁移之前先运行官方Storage迁移。脚本检查Storage依赖锁摘要和迁移数量；结束后关闭HTTP、SMTP、数据库和对象服务，Windows临时合成数据保留供诊断。

## 工具来源与Windows适配

使用[Storage v1.72.1官方源码](https://github.com/supabase/storage/tree/v1.72.1)和[MinIO固定版本源码](https://github.com/minio/minio/tree/RELEASE.2025-09-07T16-13-09Z)。MinIO社区二进制下载实际返回410，改用Go1.26.10从固定源码执行 `CGO_ENABLED=0 go build -trimpath`。此MinIO实例仅作临时本机集成后端，不打包到App，也不作为生产部署方案。

Storage的 `fs-xattr@0.4.0` 明确排除Windows，初次安装返回 `EBADPLATFORM`。本机安装采用npm11.12.1的 `ci --force --ignore-scripts --no-audit --no-fund`；仅对独立测试工具跳过平台检查/安装脚本，保留上游锁文件与完整性校验。随后用官方 `npm run build` 完成TypeScript检查、esbuild编译和路径处理。

[Windows补丁](../scripts/fixtures/storage-windows.patch)仅把 `fs-xattr` 从模块加载时导入移到文件后端构造函数加载；本测试使用S3后端，不实例化文件后端。没有替换S3上传、下载、签名、鉴权或数据库迁移。逐文件比较已确认Storage源码735个文件仅该文件变化，MinIO源码1365个文件全部与ZIP一致，记录见 `tmp/storage-source-comparison.json`；补丁反向检查通过。Linux CI不应用该补丁，使用正常 `npm ci` 编译原版。

新源码副本在其根目录执行 `git apply --check <补丁绝对路径>`、`git apply <补丁绝对路径>`；当前Windows副本已应用，不要重复应用。独立npm CLI位于 `D:/learning-planet-tools/npm-11.12.1/node_modules/npm/bin/npm-cli.js`，用独立Node运行，并仅在当前构建进程的PATH中加入该Node目录。Go模块下载因网络连接问题使用公开镜像，保留go.sum校验。

| 文件 | SHA256（下载/构建实测） |
|---|---|
| Storage v1.72.1官方源码ZIP | `be2e02f7f85eaf60173cca06e6a8afca89282cf762f0d245586045a4ae9241da` |
| Storage原始依赖锁文件 | `b97a9f0ab3f0f4efbb00f4294cad00fd197885b72d52bb8a18015ca399badae8` |
| MinIO固定版本官方源码ZIP | `91ff05ab9a16274ae07b364eb0f4e27a1bc904d4f45d7386d9910cbe8635875d` |
| 本机MinIO可执行文件 | `e2a2a4e3d1d3783f0b32390f162d8741fffc0aab967693cfccbe09fc639ffd2b` |

CI新增独立 `storage-integration` 作业：Node24/npm11.12.1、Go1.26.10；下载并核对上述源码及Auth/PostgREST发布包摘要，编译后运行同一套测试。这里只完成配置和本机检查，尚未远程执行Linux CI。

## 验证记录与交付边界

首轮因官方服务按当前目录寻找 `migrations/tenant` 而启动失败，已将原始迁移复制到新的临时运行目录；保留 `tmp/storage-migration-path-failure.log`。Windows平台安装失败记录在 `tmp/storage-windows-platform-failure.log`。这两项是本地测试工具适配问题，未更改业务实现。

共享数据库和登录引导调整后，375组数据库、5项真实Auth及7项/88次业务HTTP回归再次通过。完整静态分析通过（34.0秒），255个Dart文件格式通过。新增5项图片检查单独计数；714项Flutter单元/Widget和90.47%核心覆盖率沿用此前记录，本轮没有重跑整套业务测试或重建APK。

本机服务不能替代托管Supabase/网关/HTTPS、真正云对象存储、Edge/Cron清理、外部邮件、相机与大图、离线后台恢复、华为鸿蒙4.2/iPhone及iOS编译验收。普通调试APK仍未配置Supabase，仅显示服务配置提示；临时服务、账号、图片和密钥均不打入APK。
