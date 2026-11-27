# 永久清理

当前更新：迁移022新增[孩子永久删除](CHILD_DELETION.md)，迁移023新增[账号注销](ACCOUNT_DELETION.md)。孩子删除会先在同一事务中持久化文件任务并移除业务数据，再完成文件验证；以下014/016的所选题目/PDF清理仍保留原顺序。旧孩子同步删除接口已撤权。

迁移014和permanent-cleanup Edge Function的代码已实现；当前只做本地回归，没有部署至真实Supabase，也没有删除任何线上数据。

## 当前流程

家长验证PIN → 错题本选择最多100题 → 永久清理 / 清理记录 → 服务端范围预览 → 输入“永久删除” → 生成持久任务 → 后台删除真实私有文件 → 验证文件不存在 → SQL清除/脱敏 → 完成记录。

- questions：删除题目、答案、OCR来源与双图；作废包含这些题目的未完成复习，历史题目/作答文字和私有标准答案脱敏，保留题目UUID、判定结果、已完成任务及金融账本。
- originals：仅删除原图；保留处理图、OCR文字、题目与复习，详情明确显示原图已清理。
- abandoned_ocr：只选择本人超过24小时、尚未保存成错题的草稿，不包含其他家长或新的草稿。

删除无法恢复，现有签名链接属于短期持有凭证；下载至其他设备的副本不能由服务端撤回。本设备在确认请求及重试前清除该账号复习只读缓存，并使题目、任务、来源及图片提供器失效。其他离线设备的已有缓存不能远程即时擦除，恢复联网后才能读取清理后的服务端状态。

## 安全与恢复

客户端不能提交任意Storage路径；manifest从数据库可信来源冻结。客户端无Storage删除策略，只有服务worker调用remove，按每批最多1000个对象删除并逐路径exists验证。SQLfinish额外验证Storage索引不存在，不将仅删除索引作为真实文件清理完成证据。

请求UUID重试不重复任务，内容/孩子/操作不匹配拒绝。未完成任务标记阻止编辑/新增上传；上传RLS取得草稿共享锁，和删除标记串行化。任务行锁顺序与作答一致。租约5分钟，错误原因使用固定码，失败退避30秒指数增长、最长6小时；手工重试可立即进行，过期租约可回收。EdgeRuntime.waitUntil处理后台任务，202仅表示已受理，只有数据库completed代表确认完成。

未通过真实文件验证不得清除业务记录。网络/服务失败保留清理任务；刷新记录后重试相同任务。服务端drain仅接受环境中的service_role凭证，最多派发5项。普通用户不可调用派发RPC或finish。旧孩子删除接口在存在真实图片或活动清理任务时拒绝，防止SQL级联造成孤儿文件。

实现依据：[Supabase对象删除](https://supabase.com/docs/guides/storage/management/delete-objects)、[文件存在检查](https://supabase.com/docs/reference/javascript/file-buckets-exists)、[后台任务](https://supabase.com/docs/guides/functions/background-tasks)。

## 部署

1. 审查目标项目，顺序应用未部署迁移（包含014），不要在真实项目运行db reset。
2. 部署permanent-cleanup；verify_jwt=false由函数显式getUser验证用户、再由RPC验证PIN，只有准确匹配环境service_role凭证可走drain。该设置不是匿名授权。
3. 开启pg_cron、pg_net和Vault；在Dashboard配置operations脚本注释所列URL和worker密钥，不在仓库/日志提交密钥。Vault解密视图和pg_net请求数据只应对受信任数据库管理员可见。
4. 审查并执行supabase/operations/enable_cleanup_dispatch.sql；每两分钟补偿queued、到重试时间的failed以及过期running。
5. 检查Cron运行、HTTP状态及任务terminal状态；在staging实际上传/删除文件、断网/失败重试、跨家庭/PIN到期和两设备并发验收。实际云端、Edge类型检查和运行验收尚未完成。

## 完整目标剩余项

上述迁移014初版缺口随后由015–017的PDF/源题关联清理与30天保留、022孩子删除和023账号注销补齐代码。仍需真实Storage/Auth/Cron、备份与设备隐私验收，不能据本地检查认定完整交付。
# PDF 清理补充（迁移016）

PDF 已纳入同一持久化清理队列：组卷历史可显式确认永久删除；源错题永久删除自动清理关联组卷；可信永久清理 drain 每次先将超过30天的组卷入队。worker 对 worksheets 桶调用 Storage API 删除并核实文件不存在，数据库独立检查对象索引已消失后才删除私有快照和标记组卷已删除。保留不可复用 ID 与路径墓碑。

正在生成的 PDF 会先撤销租约，等待旧租约截止再加10分钟后才允许物理清理，覆盖当前托管 Edge worker 最大400秒生命周期；自建部署若改变生命周期需调整等待窗口。有效PIN家长可以重试同一清理记录，不代表受理后立即完成；Cron 派发脚本需由目标环境管理员配置并启用。外部下载/分享副本不能远程擦除。

本地新增验证：79项数据库检查、11项 worker 注入检查，以及真实 SDK/Deno HTTP 对本地模拟后端的失败重试、404缺失校验和可信 drain。云端 Storage/Cron 与孩子/账号整体删除仍待验收或完善。
