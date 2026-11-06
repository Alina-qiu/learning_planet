# 本地真实 PDF 生成与清理验证

2026-11-05：实际 Flutter Repository 的3项检查和4组服务流程通过。GoTrue、PostgREST、原Deno入口、Storage与MinIO共同运行，执行13次Auth、88次业务、20次Storage请求，接收2封本机合成邮件。日志为 `tmp/worksheet-integration-latest.log`。本结果覆盖本机服务，不代表云端或真机验收完成。

## 修复的组卷失败

生成器已经输出 `a4-v2`，但迁移015的数据库默认值仍为 `a4-v1`；可信完成接口严格比较版本，因此实际PDF上传后被拒绝，任务最终显示 `PDF_GENERATION_FAILED`。原SQL测试和worker替身也写死v1，未发现这一差异。真实服务失败日志保存在 `tmp/worksheet-first-service-failure.log`。

[迁移065](../supabase/migrations/202611050065_worksheet_renderer_version.sql)将新任务默认版本设为v2，并在领取新租约时升级旧queued/failed任务及租约已过期的running任务。已生成的文件和仍有效的旧租约保留原版本；原工作进程可使用v1完成，后续重试仍使用原组卷ID、题目快照、路径和保留期限。完成接口继续检查版本、租约及文件元数据。新增7组数据库检查，并让既有测试读取实际生成器的版本常量，避免再次漂移。

部署时需要同时安排迁移065与当前worksheet-render入口；版本不匹配期间仍会拒绝完成，失败任务可在部署完成后重试。本轮没有部署到任何云端项目。

## 验证范围

| 场景 | 实际证据 |
|---|---|
| 排序与快照 | 先冻结“绿叶→数学→银行”，再修改原数学题；生成文件仍是原顺序、原题干和答案20 |
| 中文与拼音 | 竖版练习及答案共2页，横版拼音默写1页；含lǜ yè、yín háng，反向默写不泄露汉字答案 |
| 预览与导出 | 实际App仓库重复下载得到相同字节，PDF头、大小、SHA256与服务端一致；Deno文件与同快照的Node渲染结果逐字节一致 |
| 上传失败与重试 | 代理阻断上传，任务失败且无S3残留；按原ID重试成功，尝试次数2，总组卷数仍为2 |
| 成功回执丢失 | 数据库完成事务提交后，代理将一次成功回复改为503；worker重读已完成状态，文件保留且不重复生成 |
| 私有访问 | 另一个真实账号不能读取历史、下载文件或发起生成；普通家长不能调用可信drain |
| 保留期 | 将本轮合成文件的expires_at提前，验证鉴权下载拒绝；可信drain移除实际S3文件，旧签名链接失效，另一文件保持可读 |
| 源题删除 | 删除数学题后关联组卷进入deleting，禁止重新生成；清理后PDF、Storage元数据及题目/答案快照全部移除，旧签名链接失效 |

使用PG15.19、PostgREST16.2、GoTrue2.196.0、Storage1.72.1、MinIO和Deno2.9.6；加载70份Auth、68份Storage及67份应用迁移。服务准备沿用[Storage集成说明](STORAGE_INTEGRATION.md)。原Edge入口通过回环引导运行，使用固定Supabase JS2.99.1及真实服务接口；未运行Supabase Edge Runtime容器。

服务端临时密钥仅交给本机Node/Deno，Flutter收到普通用户会话和anon key。所有服务绑定127.0.0.1，测试账号使用example.test，不连接托管项目或外部邮箱。测试结束服务关闭，S3对象和Storage元数据均为0；本机输出保留两份合成样张供检查。

## 样张与排版检查

- `output/pdf/local-service-mixed.pdf`：6607306字节，A4竖版2页，题目页及独立参考答案页。
- `output/pdf/local-service-pinyin.pdf`：6607276字节，A4横版1页，拼音默写及每题两行田字格。
- `output/pdf/local-service-pdf-validation.json`：当前生成文件的页数、大小、SHA256及渲染版本；每次运行使用新快照，摘要不固定。

Poppler将全部3页渲染到 `tmp/pdfs/real-service/`，逐页目视检查通过：无缺字、声调丢失、遮挡或越界，题目与格线同页。pypdf核对真实文件中的中文、声调、答案开关和题目顺序；pdfplumber核对所有文字位于至少12mm页边距内，结果保存为 `text-validation.json`。本机控制台第一次打印中文使用非UTF8编码，改为Python UTF8后检查通过；文件本身无乱码。

## 运行与剩余验收

按Storage说明设置 `POSTGREST_BIN`、`GOTRUE_BIN`、`STORAGE_SOURCE`、`MINIO_BIN`，安装Flutter后可设置 `FLUTTER_BIN`。Node24在PATH时执行：

```sh
npm run check:edge
npm run test:pdf-integration
```

主脚本为 `scripts/test_worksheet_integration.mjs`，客户端夹具为 `scripts/fixtures/worksheet_client_test.dart`。CI的storage-integration作业已加入该命令及两份PDF/摘要文件的产物保存；已完成本机YAML解析，远程Linux作业尚未运行。

本轮382组数据库、8项PDF worker、两入口Deno类型检查、完整Flutter分析（33.7秒）、256个Dart文件格式及补丁检查通过。714项Flutter单元/Widget及90.47%核心覆盖率沿用此前记录，不将3项服务集成计入或冒充重新执行全量测试。业务变更在SQL，普通APK未重建，仍未配置Supabase。

集成夹具曾将PG bigint字符串与文件长度数字直接比较，已修正类型转换；失败日志保留为 `tmp/worksheet-fixture-byte-size-failure.log`。Flutter分析首次在中文路径下发生LSP消息解析异常，改在已有ASCII路径映射下运行通过；日志保留。这两项是测试环境问题，与上述真实版本缺陷分开记录。

仍需云端HTTPS/网关、迁移与Edge部署、真实Cron及30天保留期限、华为鸿蒙4.2/iPhone打印分享、设备缓存和iOS构建验收。提前设置合成任务过期时间验证的是清理规则，未实际等待30天；签名链接在物理删除前仍受原有效期约束。
