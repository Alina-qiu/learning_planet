# 本机数据库与私有文件恢复演练

2026-11-06，新增可重复运行的隔离恢复测试；最新在Windows临时库改用SCRAM密码认证后复验9项通过，用时43.7秒，报告为[build/backup_restore/results.json](../build/backup_restore/results.json)，运行ID `c66fd180-2749-4ad9-a27f-63920aaca7a5`。源服务在目标恢复前退出，目标服务在测试结束后退出；合成备份归档已移除，只保留不含登录令牌或数据库行明文的结果摘要。

此前59.8秒的运行`68bfbf42-b3a5-4ef5-9170-573414963620`另存于`build/review_candidate/backup-restore-before-auth.json`。密码认证复验首次遇到Storage启动60秒超时；独立探测确认7.6秒内完成Storage启动，但未发送业务流量，因此探测的整体流量断言失败，不能计为集成通过。最终保持60秒超时设置完整重跑通过，日志为`tmp/ci-backup-auth-retry.log`；首次失败和探测日志均保留，启动延迟的具体原因尚未确定。

这是本机开发验收工具，不是面向家庭用户的新备份按钮，也没有改变现有本机调试后端“重启为空库”的约定。业务Dart、SQL迁移、原生代码及APK未改；用户尚未准备云端Supabase项目。

## 验证流程

1. 启动独立PostgreSQL15.19、真实GoTrue2.196.0、PostgREST16.2、Storage1.72.1及MinIO。源库应用68份业务迁移、70份Auth迁移和68份Storage迁移。
2. 通过真实邮箱OTP创建两名用户与两个家庭，使用业务RPC创建已完成/待完成任务、调账回执、两道错题和四份私有原图/处理图；用现有渲染器生成中文PDF，通过实际Storage上传并完成组卷。
3. 停止Auth、PostgREST和Storage API写入，网关拒绝新业务请求。此场景没有外部写入者或Cron；数据库保持可读，用于生成`pg_dump --format=custom`归档和`pg_dumpall --roles-only --no-role-passwords`角色文件。另从S3读取五个对象的原始字节、对象键、内容类型等属性，保存独立文件与SHA256清单。
4. 关闭源环境后创建全新的PG数据目录和MinIO桶，分别损坏数据库归档与一个对象文件；两者均在对应恢复写入开始前被校验拒绝。恢复有效文件后，角色文件保留成员关系与设置，测试服务密码通过独立测试配置补回；`pg_restore --exit-on-error --single-transaction`保留所有者与权限，没有使用`--no-owner`或`--no-acl`。
5. 在目标API启动前比较全部业务/Auth/Storage表的行摘要、序列、角色、成员关系、schema/关系权限、默认权限、RLS策略及函数定义。没有重新执行业务迁移来弥补恢复缺失。
6. 启动目标真实服务，用备份前会话读取用户、刷新令牌、验证家长PIN，并注册新的OTP用户；从私有Storage签名下载图片/PDF，核对字节、MIME及PDF页数，检查另一家庭和匿名用户不能签名访问。
7. 重放原任务完成与调账请求，核对账本ID、行内容和45金币/25XP余额不变；再完成恢复前的待完成任务，恰好新增一条金币与一条XP账本。

## 实际结果

| 范围 | 本轮结果 |
|---|---|
| 全表恢复 | 106张表、216行、32张非空表的摘要完全一致 |
| 序列 | 2条序列的值与`is_called`一致；恢复后新注册/新完成可继续写入 |
| 角色与授权 | 7个非系统角色、9条成员关系、3个schema、348个关系、4项默认权限一致 |
| 业务保护 | 43条RLS策略、359个函数的定义/所有者/安全属性/权限一致 |
| 私有对象 | 四张合成PNG与一份真实渲染PDF，五个S3对象的键、大小、SHA256一致 |
| 凭据恢复 | 原会话、刷新令牌、PIN正常；复用本轮测试签名密钥后原图片签名令牌也可读取 |
| 请求重放 | 已完成任务与调账不重复发奖，原账本行和钱包不变 |
| 损坏检测 | 数据库/对象同长度字节损坏均拒绝恢复，不以文件长度代替哈希 |
| 清理 | 源/目标服务均已关闭，本轮临时归档已删除 |

比较ACL时先展开默认权限并排序条目，保留被授权者、授权者及授权选项；权限数组的不同排列不应视为权限改变。此次首次失败为测试程序未带用户身份调用家庭日期函数，第二次失败为未规范化ACL数组顺序。修正测试后通过，没有放宽权限或修改业务规则。日志分别保留在`tmp/backup-restore-first.log`、`tmp/backup-restore-second.log`及最终`tmp/backup-restore-third.log`。

共享环境变更另执行原有5项实际Flutter Storage集成：12次Auth、60次业务、31次Storage请求及6封本机邮件，8个文件和元数据一致；日志`tmp/backup-restore-storage-regression.log`。7项启动工具检查也通过，日志`tmp/backup-restore-startup-regression.log`。此前800项Flutter、387项SQL、34项JVM和90.94%覆盖率仍为历史结果，本轮未重跑这些全量集合。

## 本机复现

入口为[scripts/test_backup_restore.mjs](../scripts/test_backup_restore.mjs)，辅助代码为[数据库归档](../scripts/fixtures/database_backup.mjs)及[Storage环境](../scripts/fixtures/storage_backend.mjs)。只创建合成回环服务，不读取云端连接或本机联调密钥。

在项目根目录运行，依赖已准备好的Node24、四个服务和PostgreSQL15客户端：

```powershell
$env:POSTGREST_BIN = 'D:/learning-planet-tools/postgrest-16.2/postgrest.exe'
$env:GOTRUE_BIN = 'D:/learning-planet-tools/supabase-auth-source/auth-2.196.0/auth.exe'
$env:STORAGE_SOURCE = 'D:/learning-planet-tools/supabase-storage-source/storage-1.72.1'
$env:MINIO_BIN = 'D:/learning-planet-tools/minio-2025-09-07/minio.exe'
$env:PG_CLIENT_BIN = 'D:/learning-planet-tools/postgresql-15.19-5/pgsql/bin'
& 'C:/Users/qiuya/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe' scripts/test_backup_restore.mjs
```

在Node24为当前运行时的环境中，也可使用`npm run test:backup-restore`。测试的对象清单限于单页、少量合成数据，不提供大规模备份CLI。

本机客户端来自PostgreSQL官方Windows下载页所链接的[EDB二进制归档](https://www.enterprisedb.com/download-postgresql-binaries)：`postgresql-15.19-5-windows-x64-binaries.zip`，下载文件SHA256为`49e0690194d9fe2bb4d7d6587fdddaa85a3eaaafe2fd5480e0916fcb25d0143e`（本机计算的完整性记录，不声称为供应商公布校验值）。只解压独立目录，未安装系统数据库服务或修改系统PATH，四个客户端均输出15.19。

[CI定义](../.github/workflows/flutter_ci.yml)在Storage集成任务中加入PostgreSQL15客户端、恢复测试和报告上传，Ubuntu客户端安装方式依据[PostgreSQL官方仓库说明](https://www.postgresql.org/download/linux/ubuntu/)。提交`6722047`的[远程Storage任务](https://github.com/Alina-qiu/learning_planet/actions/runs/42139724907)已通过；此后Windows认证夹具改动仍按新提交继续复验。

收尾检查：六份变更JavaScript模块语法通过，工作流YAML解析及执行顺序/依赖/报告路径检查通过，涉及的六份文档共350个本地链接可定位，补丁空白检查通过。

## 仍需目标环境完成的事项

- 这是停止写入后生成的一组数据库/对象备份，不证明在线并发跨服务快照、PITR、灾备RPO/RTO、跨版本或生产回滚可用；59.8秒是小型本机测试总耗时，不是恢复时间承诺。
- 托管Supabase数据库备份只有Storage元数据，实际对象需要单独保护；不能用本次MinIO恢复证明托管对象已备份。[Supabase官方备份说明](https://supabase.com/docs/guides/platform/backups)
- 单库逻辑归档和集群全局角色分开保存，本测试没有额外表空间、托管扩展或自定义数据库配置；实际部署应按环境核对这些内容。[PostgreSQL pg_dump说明](https://www.postgresql.org/docs/15/app-pgdump.html)
- 本轮仅在内存中复用测试JWT签名密钥、重新设置固定测试角色密码。真实环境还需安全恢复/轮换签名密钥、SMTP、模型、HMS/APNs、Edge配置、调度及监控；不能把备份文件写入应用包或公开日志。
- 真实备份的加密、访问控制、保留/销毁、已删除孩子资料的恢复后再清理、目标环境迁移/回滚及外部文件副本仍待验收。本次不是生产恢复操作手册，不能直接套用到托管角色和真实数据。
- 华为鸿蒙4.2/iPhone、云端双端流程、iOS编译与后台通知、性能和家庭试用仍按[当前需求覆盖](CURRENT_STATUS.md)推进。
