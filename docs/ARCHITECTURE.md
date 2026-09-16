# 架构说明

## 总体结构

```text
Flutter iOS/Android
  ├─ Riverpod 状态管理
  ├─ Drift 本地数据库和同步队列
  └─ Supabase Client
        ├─ Auth
        ├─ PostgreSQL + RLS
        ├─ Storage
        └─ Edge Functions / Cron
              ├─ 每日错题复习任务
              ├─ 奖励事务
              ├─ OCR/AI 网关
              └─ PDF 生成
```

## 模块边界

- `auth_family`：身份、家庭、成员、孩子和家长 PIN。
- `tasks`：模板、实例、计时、长期计划和提醒。
- `wrong_questions`：错题、复习调度、自动任务和组卷。
- `economy`：钱包、账本、XP、软上限和审计。
- `rewards`：商品、申请、冻结、审批和履约。
- `reports`：聚合指标和 AI 建议。
- `sync`：离线命令、冲突规则和重试。

## 不变量

1. 客户端不能直接修改钱包余额。
2. 每个奖励结算操作必须具有唯一幂等键。
3. 同一孩子同一天最多一条 `automatic_wrong_review` 任务。
4. 自动复习任务开始后，题目集合不可变。
5. 家长调账和补签必须有审计记录。
6. AI 输出不能直接改变金币、任务完成或掌握状态。
7. 所有儿童数据按家庭 RLS 隔离。

## 同步策略

本地先写入命令队列并给予界面反馈。服务端接受命令后返回权威版本；普通文本采用最后写入优先，任务完成和积分使用幂等命令与追加账本，兑换使用服务端事务。发生无法自动合并的内容冲突时保留两版并交给家长处理。

## 自动错题复习任务

定时函数使用家庭时区计算业务日期，并为每个孩子调用 `generate_daily_wrong_review_task(child_id, date, max_questions)`。数据库唯一约束负责最终防重。App 每次从离线恢复时可调用同一 RPC 作为补偿；由于 RPC 幂等，不会重复创建。生成后的题目通过 `task_review_items` 保存快照。
