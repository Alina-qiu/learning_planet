# 家长远程通知

iPhone 使用 APNs 接收家长远程提醒。客户端通过家庭 PIN 授权注册和撤销，服务端只向有效设备派发。Android 支持应用内家长消息、前台提醒和本地任务闹钟。实际 APNs、签名 iPhone 和托管服务仍待联调。

迁移 074 保留有效的 APNs 和 gateway 注册，关闭已停用通道的设备，清除其投递令牌、有效期及任务内的设备指纹。它会撤销旧投递租约，让仍在处理的消息回到队列。同一账号在该家庭有已授权的 iPhone 时，可在偏好、安静时段和消息有效期允许的情况下重新领取。[迁移](../supabase/migrations/202611260074_parent_push_transports.sql) · [有数据升级检查](../build/acceptance-20261126/database-upgrade.json)

## 平台选择

| 目标 | 已有实现 | 尚需完成 |
|---|---|---|
| iPhone | APNs ES256/HTTP2；Token回调、原生接收、本机校验；entitlements和后台能力已写入工程 | 签名/Provisioning Profile、实际Token和真机接收 |
| 可选其他通道 | 服务端配置的HTTPS gateway适配器 | 具体供应商与协议核对，目前未配置供应商 |

APNs按[Apple发送请求说明](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)使用HTTP/2/TLS。本地已通过实际Deno到仅支持HTTP/2的TLS服务器验证传输和ES256签名，未访问Apple服务。

## 注册、撤销与客户端接入约束

`parent_push_devices`和`parent_push_jobs`是私有表，包括service_role在内的API角色不能直接查询。客户端使用专门RPC，服务端才能领取任务、读取单次发送所需Token。现有39类孩子导出不包含Token、设备密钥和内部队列。

- `prepare_parent_push_device`要求当前家庭的会话PIN。客户端先持久化随机安装UUID、至少32字节随机密钥（base64url后43字符）、递增intent_version和随机scope_nonce，再准备注册。准备有效5分钟，尚不能投递。
- `activate_parent_push_device`核对账号、家庭、密钥、版本和有效PIN；激活有效30天。相同请求可重放，同版本不能换Token/通道；一个Token只属于一个安装，每账号最多100条设备记录。
- `renew_parent_push_device`只允许同一账号及有效家庭成员在已有授权期内续期/更新Token，不能恢复已撤销或过期记录。重新启用须新的PIN注册意图。
- `revoke_parent_push_device`接受单个安装的撤销密钥，可匿名清空该安装的Token，便于离线退出后补传；不暴露记录是否存在。版本只前进，旧退出请求不能撤销新意图。缺失记录不匿名插入，因此客户端必须等待准备成功且本机意图仍有效后才发送激活。
- 同一安装换账号须持有安装密钥、验证新家庭PIN并提高版本；旧账号不能续期。

Flutter现已调用这些RPC。启用必须由家长在消息页单独操作，要求当前PIN、家长提醒设备模式、通知偏好和系统权限。关闭先持久改变原生revision并清除本机投递，再将安装撤销能力存入安全存储；匿名专用客户端补传，不保留旧JWT。前台每分钟、恢复应用及刷新时重试，应用关闭时不承诺服务端立即撤销。旧激活/撤销回包不能覆盖较新的意图。

原生接收器不读取孩子数据库或登录会话，只保存不透明nonce、校准时钟、授权期限、最低设置版本和最多1000个消息ID。显示前检查精确字段白名单、60秒消息期限、授权期限、设置版本、家庭时区安静时段及去重。时钟用服务器时间加包含休眠的单调计时，校准往返不超过10秒，检查上下时间界；设备重启或系统时钟偏差超过30秒后停止接收，须打开应用重新确认。固定文案不含孩子资料，点击进入普通应用入口，不能绕过PIN。

安全存储写入失败时，本机关闭revision仍保留。重启对照原生状态与加密记录中的revision，不会自动恢复旧启用记录；损坏的撤销能力不被新身份替换。前台启动先暂停接收，只有同账号、家庭和已确认的设备模式才续期；每12小时或恢复应用时刷新Token。

## 客户端构建配置

- `PARENT_REMOTE_PUSH`默认为false；仅当 iOS 构建已配置服务端通道并准备联调时设为 true。无配置时不请求设备Token。
- iOS Bundle ID为`com.learningplanet.learningPlanet`，APNs topic必须一致。工程含`remote-notification`后台模式，Debug的`aps-environment`为development，Release/Profile为production；须匹配Apple App ID能力、签名配置和服务端sandbox/production。应用启动时注册Flutter原生生命周期代理，后台消息不依赖Dart数据库。
- iOS使用静默推送后由原生端校验再显示本地提醒，送达受系统预算、省电、网络和用户强退影响。需要可靠确认时以应用内收件箱为准，供应商接受不等同于手机已经显示。
- 各退出入口现已统一本机权限、提醒和安全凭据清理，服务端PIN撤销失败不再阻塞本机退出；加载/错误页也可退出。存储或原生清理失败会提示重试。离线退出不等同于服务端JWT/PIN立即失效，详见[会话隔离](LOCAL_DATA_SECURITY.md#2026-11-05-断网退出与会话隔离)。

## 队列与送达含义

兑换申请和上一完整周报告与前台消息共用权威来源；本机同步异常不进入远程队列。入队检查有效成员/设备、个人总开关和类别、家庭时区静默、已读/已送达回执，每轮最多新增200个事件；已有事件不占新事件配额。按家庭、账号和事件键唯一去重。

每轮最多领取20条，最多4路并发，只领取已配置通道。相同账号和家庭选择最近更新的一台有效设备，其他设备仍可查看收件箱。租约2分钟、最多5次尝试，失败按60/120/240/480秒退避；最后一次中断后也会终止，消息源到期同样终止。

调用供应商前再次检查来源、成员、偏好、设备版本和Token哈希。仅发送`parent-push-v1`的10个白名单字符串字段：随机消息ID、随机范围nonce、类型、签发/到期毫秒、时区、安静起止和设置版本。没有孩子/账号/家庭ID、姓名、兑换内容、题目、答案、深链或服务端可控通知正文。客户端应按类型显示固定文案，详情受PIN保护。

签发窗口最长60秒，APNs `apns-expiration=0`；APNs仅有`content-available`，不带alert/sound/badge。原生接收器已实现本机状态校验后提交本地通知，真实设备行为待验证；服务端授权与外部网络调用之间的竞态不能仅靠数据库消除。

供应商接受后写入现有送达回执，不标为已读。**接受只表示提交给通道，不证明设备显示或用户阅读。** 短有效期、离线或后台限制导致丢弃时，收件箱待办仍可查看，前台不再弹已有送达回执的事件。响应丢失可能导致同一消息ID重发，最终去重还需原生接收器。

[Apple后台通知说明](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)明确后台消息可能被延迟、节流或丢弃，强制结束应用也会影响接收，不能承诺关闭后即时必达。实际iOS的后台、同类合并及频控行为须在目标设备验收。

## 清理与安全

入队先取得成员锁，再按顺序取得孩子清理锁，等待结束后重新检查来源。孩子删除标记立即删除队列，迟到结果不能重建回执。成员移除级联清理注册/队列，注销受理立即清理该账号及其拥有家庭的全部注册/队列。旧Token失败不能关闭已经轮换的Token。

服务端清理RPC删除过期7天的队列、清除到期设备Token、删除90天未更新的非启用设备。实际时限依赖每日任务执行。每次供应商请求8秒超时（含读响应），响应最多16KiB，拒绝重定向；供应商域名固定，gateway仅取服务端配置。日志只含聚合计数或固定错误码，不记凭据/Token/数据/供应商错误原文。生产APNs URL路径含Token，部署时须核对HTTP自动追踪或代理日志不采集该路径；本地未开启此类自动采集。

## 待执行的部署配置

1. 按顺序应用项目中的数据库迁移，并部署`supabase/functions/parent-push`。
2. 在服务端Secrets配置通道；私密凭据不放入Dart定义、APK、仓库或客户端配置。无通道时返回`PUSH_NOT_CONFIGURED`且不领取任务，部分缺失配置拒绝派发。
3. 端侧完成并通过真实项目/设备验证后，运行`supabase/operations/enable_parent_push.sql`。复用Vault的`learning_planet_project_url`和`learning_planet_cleanup_worker_key`，每分钟派发、03:31清理，核对目标Cron时区。

| 通道 | 服务端环境变量 |
|---|---|
| APNs | `PARENT_PUSH_APNS_KEY`（PKCS8 .p8全文）、`PARENT_PUSH_APNS_KEY_ID`、`PARENT_PUSH_APNS_TEAM_ID`、`PARENT_PUSH_APNS_TOPIC`、`PARENT_PUSH_APNS_ENVIRONMENT`（明确sandbox/production，与签名环境一致） |
| gateway | `PARENT_PUSH_GATEWAY_URL`、`PARENT_PUSH_GATEWAY_KEY`；HTTPS且无用户信息/查询串/片段；响应须有`outcome: accepted/retry/rejected/invalid_token` |

入口仅接受服务角色Bearer及`{"mode":"drain"}`，不接受客户端指定Token、正文、任务或URL。202表示后台处理已受理，终态看数据库和聚合日志。真实供应商权限、额度、网络和项目配置均待联调；本轮未执行本节步骤。

## 本地验证

- 迁移001–045全量266组数据库检查通过，新增15组覆盖双worker、删除并发、跨账号、撤销、回执、清理和批次边界。
- 12项worker测试通过，覆盖APNs签名、白名单载荷、超时/响应大小、缓存/错误映射、4路并发及租约恢复。
- 真实Deno Edge本地HTTP模拟通过：服务鉴权、缺配置、Supabase RPC、失败重试、重放及撤销。
- 真实Deno HTTP/2 TLS模拟通过；保持证书校验，JDK17 keytool生成的一次性证书仅加入该测试进程信任，测试后删除。需`JAVA_HOME`或PATH里的keytool。
- 服务端未在本轮改变，沿用迁移045的266组SQL、12项worker和5个Edge入口回归结果。
- 接入阶段全量383项Flutter测试通过，新增24项覆盖注册/撤销、真实SDK匿名传输、迟到回包、存储故障、重启、状态UI、PIN和前后台重试；后续退出修复后的全量402项通过、完整分析无问题，核心覆盖率4122/4763（86.54%），见[测试记录](TESTING.md)。

命令：`npm run test:db`、`npm run test:parent-push`、`npm run check:edge`、`npm run test:edge`。隔离数据库为PostgreSQL18.4 beta，云端目标配置为15；目标环境实际部署仍待验证。
