# 开发进度

更新时间：2026-09-16

## 阶段 0：工程准备

- [x] Flutter Android/iOS 平台壳
- [x] development、staging、production 配置入口
- [x] 格式、静态分析、测试 CI
- [x] Android debug 和 iOS 无签名构建 CI
- [ ] GitHub Actions 平台构建结果确认

## 阶段 1：账号家庭

- [x] 邮箱验证码登录与 Android/iOS 深链回调
- [x] 原子创建家庭并将创建者设为管理员
- [x] 家庭成员与业务表 RLS 基础策略
- [ ] 家庭成员邀请
- [ ] 多孩子档案界面
- [x] 家长 PIN 强哈希、失败计数和十分钟锁定 RPC
- [x] 家长 PIN 客户端状态机单元测试
- [ ] 家长端/孩子端切换界面

## 当前限制

- 本机未安装 Supabase CLI，新增迁移尚未在本地 PostgreSQL 实例执行。
- 本机未配置 Android SDK；Android/iOS 构建由 GitHub Actions 验证。
