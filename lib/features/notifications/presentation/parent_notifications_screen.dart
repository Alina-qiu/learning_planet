import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/offline/network_failure.dart';
import '../../auth_family/application/family_providers.dart';
import '../../auth_family/domain/family.dart';
import '../../economy/presentation/economy_screen.dart';
import '../../reports/presentation/learning_report_screen.dart';
import '../../tasks/presentation/sync_center_screen.dart';
import '../data/parent_notification_repository.dart';
import '../data/parent_notification_device.dart';
import '../data/remote_parent_push.dart';
import '../domain/parent_notification.dart';

class ParentNotificationsScreen extends ConsumerStatefulWidget {
  const ParentNotificationsScreen({required this.familyId, super.key});
  final String familyId;
  @override
  ConsumerState<ParentNotificationsScreen> createState() =>
      _ParentNotificationsScreenState();
}

class _ParentNotificationsScreenState
    extends ConsumerState<ParentNotificationsScreen> {
  bool _busy = false, _unreadOnly = false;
  bool get _authorized =>
      ref.read(activeParentFamilyProvider) == widget.familyId;
  Future<void> _refresh() async {
    ref.invalidate(parentInboxProvider(widget.familyId));
    ref.invalidate(parentSyncIssuesProvider(widget.familyId));
    await ref.read(parentInboxProvider(widget.familyId).future);
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (_busy || !_authorized) return false;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted || !_authorized) return false;
      ref.invalidate(parentInboxProvider(widget.familyId));
      return true;
    } catch (_) {
      if (mounted && _authorized) {
        ref.invalidate(parentInboxProvider(widget.familyId));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('操作结果尚未确认，请刷新消息后重试。')));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(ParentMessage message, ChildProfile child) async {
    if (!_authorized || _busy) return;
    if (message.readAt == null &&
        !await _run(
          () => ref.read(parentNotificationRepositoryProvider).markRead(
            widget.familyId,
            [message.key],
          ),
        )) {
      return;
    }
    if (!mounted || !_authorized) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => message.kind == ParentMessageKind.redemption
            ? EconomyScreen(
                childId: child.id,
                familyId: widget.familyId,
                initialTab: 1,
              )
            : LearningReportScreen(
                childId: child.id,
                familyId: widget.familyId,
                childNickname: child.nickname,
                initialPeriod: 'week',
                initialEndDate: message.anchorDate,
              ),
      ),
    );
    if (mounted && _authorized) {
      ref.invalidate(parentInboxProvider(widget.familyId));
    }
  }

  Future<void> _settings(ParentInbox inbox) async {
    final edited = await showDialog<ParentNotificationSettings>(
      context: context,
      builder: (_) => _SettingsDialog(
        settings: inbox.settings,
        timezone: inbox.timezone,
        familyId: widget.familyId,
      ),
    );
    if (edited == null || !mounted || !_authorized) return;
    await _run(() async {
      await _saveSettings(edited);
    });
  }

  Future<void> _saveSettings(ParentNotificationSettings settings) async {
    final device = ref.read(parentNotificationDeviceProvider);
    try {
      if (device == null) {
        await ref
            .read(parentNotificationRepositoryProvider)
            .save(widget.familyId, settings);
      } else {
        await device.saveSettings(
          widget.familyId,
          settings,
          canConfigure: () => mounted && _authorized,
        );
      }
    } finally {
      if (mounted && _authorized) {
        ref.read(parentNotificationDeviceRevisionProvider.notifier).state++;
        ref.read(remoteParentPushRevisionProvider.notifier).state++;
      }
    }
  }

  Future<void> _deviceMode(ParentInbox inbox, bool enabled) async {
    await _run(() async {
      final device = ref.read(parentNotificationDeviceProvider);
      if (device == null) throw StateError('当前设备不支持');
      if (enabled && !inbox.settings.enabled) {
        await _saveSettings(
          ParentNotificationSettings.fromJson({
            ...inbox.settings.toConfig(),
            'enabled': true,
            'version': inbox.settings.version,
          }),
        );
      }
      if (!mounted || !_authorized) return;
      final changed = await device.setParentMode(
        widget.familyId,
        enabled,
        canConfigure: () => mounted && _authorized,
      );
      if (!mounted || !_authorized) return;
      if (changed) {
        ref.read(parentNotificationDeviceRevisionProvider.notifier).state++;
        ref.read(remoteParentPushRevisionProvider.notifier).state++;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('系统通知未授权或此平台不支持；仍可查看应用内消息。')),
        );
      }
    });
  }

  Widget _remoteControls(ParentInbox inbox) => ref
      .watch(remoteParentPushStatusProvider(widget.familyId))
      .when(
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('后台提醒状态暂时无法读取'),
          trailing: TextButton(
            onPressed: () =>
                ref.invalidate(remoteParentPushStatusProvider(widget.familyId)),
            child: const Text('重试'),
          ),
        ),
        data: (status) {
          final enabled = status == RemotePushStatus.enabled;
          final parentMode =
              ref
                  .watch(parentNotificationDeviceModeProvider(widget.familyId))
                  .valueOrNull ==
              true;
          final supported =
              status != RemotePushStatus.unconfigured &&
              status != RemotePushStatus.unavailable;
          final description = switch (status) {
            RemotePushStatus.unconfigured => '此版本尚未开通后台提醒，可继续查看应用内消息。',
            RemotePushStatus.unavailable => '此设备暂不支持后台提醒，可继续使用应用内消息。',
            RemotePushStatus.revoking => '本机已关闭提醒，联网后继续完成服务端撤销。',
            RemotePushStatus.enabled => '通过华为或苹果推送接收兑换与周报提醒；网络、省电和强制退出可能影响送达。',
            RemotePushStatus.disabled =>
              parentMode && inbox.settings.enabled
                  ? '启用后通过华为或苹果推送接收兑换与周报提醒，锁屏不显示孩子资料。'
                  : '先启用此设备的家长提醒，再开启后台接收。',
          };
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text(enabled ? '后台家长提醒：已启用' : '后台家长提醒'),
            subtitle: Text(description),
            trailing: supported
                ? TextButton(
                    onPressed:
                        _busy ||
                            (!enabled &&
                                (!parentMode || !inbox.settings.enabled))
                        ? null
                        : () => _run(() async {
                            final push = ref.read(remoteParentPushProvider);
                            if (push == null) return;
                            try {
                              if (enabled) {
                                await push.disable();
                              } else {
                                final device = ref.read(
                                  parentNotificationDeviceProvider,
                                );
                                if (device == null ||
                                    !await device.isParentMode(
                                      widget.familyId,
                                    ) ||
                                    !mounted ||
                                    !_authorized) {
                                  return;
                                }
                                await push.enable(
                                  widget.familyId,
                                  inbox.settings,
                                  canConfigure: () => mounted && _authorized,
                                );
                              }
                            } finally {
                              if (mounted) {
                                ref
                                    .read(
                                      remoteParentPushRevisionProvider.notifier,
                                    )
                                    .state++;
                              }
                            }
                          }),
                    child: Text(enabled ? '关闭' : '启用'),
                  )
                : null,
          );
        },
      );

  Widget _syncCards(Map<String, ChildProfile> children) => ref
      .watch(parentSyncIssuesProvider(widget.familyId))
      .when(
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => TextButton(
          onPressed: () =>
              ref.invalidate(parentSyncIssuesProvider(widget.familyId)),
          child: const Text('本机同步状态读取失败，点击重试'),
        ),
        data: (issues) => Column(
          children: [
            for (final issue in issues)
              if (children[issue.childId] case final child?)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.sync_problem_outlined),
                    title: Text('${child.nickname}的本机同步需要关注'),
                    subtitle: Text(issue.summary),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy
                        ? null
                        : () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  SyncCenterScreen(childId: child.id),
                            ),
                          ),
                  ),
                ),
            if (issues.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('本机暂无需要处理的同步问题'),
              ),
          ],
        ),
      );

  Widget _localContent(
    Map<String, ChildProfile> children, {
    required bool loading,
  }) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('本机同步状态', style: Theme.of(context).textTheme.titleLarge),
      const Text('本机队列可以查看；兑换申请和周报需要联网更新。'),
      _syncCards(children),
      const Divider(),
      if (loading)
        const LinearProgressIndicator()
      else
        TextButton(
          onPressed: () => ref.invalidate(parentInboxProvider(widget.familyId)),
          child: const Text('联网后重试家长消息'),
        ),
      ref
          .watch(parentNotificationDeviceModeProvider(widget.familyId))
          .maybeWhen(
            data: (enabled) => enabled
                ? TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final device = ref.read(
                              parentNotificationDeviceProvider,
                            );
                            if (device != null) {
                              await device.setParentMode(
                                widget.familyId,
                                false,
                                canConfigure: () => mounted && _authorized,
                              );
                            }
                            if (mounted && _authorized) {
                              ref
                                  .read(
                                    parentNotificationDeviceRevisionProvider
                                        .notifier,
                                  )
                                  .state++;
                            }
                          }),
                    child: const Text('此设备切换为孩子提醒'),
                  )
                : const SizedBox.shrink(),
            orElse: () => const SizedBox.shrink(),
          ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final authorized = ref.watch(activeParentFamilyProvider) == widget.familyId;
    return Scaffold(
      appBar: AppBar(title: const Text('家长消息')),
      body: !authorized
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : ref
                .watch(familiesProvider)
                .when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => const Center(child: Text('家庭资料暂不可用，请返回重试')),
                  data: (families) {
                    final matches = families.where(
                      (f) => f.id == widget.familyId,
                    );
                    if (matches.isEmpty) {
                      return const Center(child: Text('当前家庭已不可访问'));
                    }
                    final children = {
                      for (final c in matches.first.children) c.id: c,
                    };
                    return ref
                        .watch(parentInboxProvider(widget.familyId))
                        .when(
                          skipLoadingOnRefresh: false,
                          loading: () => _localContent(children, loading: true),
                          error: (error, _) => isNetworkFailure(error)
                              ? _localContent(children, loading: false)
                              : Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text('暂时无法读取家长消息'),
                                      TextButton(
                                        onPressed: () => ref.invalidate(
                                          parentInboxProvider(widget.familyId),
                                        ),
                                        child: const Text('重试'),
                                      ),
                                    ],
                                  ),
                                ),
                          data: (inbox) => RefreshIndicator(
                            onRefresh: () async {
                              try {
                                await _refresh();
                              } catch (_) {
                                /* Error state exposes Retry. */
                              }
                            },
                            child: ListView(
                              padding: const EdgeInsets.all(16),
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                Text(
                                  '兑换申请、同步异常和每周报告',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '消息在打开应用时刷新。标为已读不会审批兑换，也不会清除待同步的数据。',
                                ),
                                ref
                                    .watch(
                                      parentNotificationDeviceModeProvider(
                                        widget.familyId,
                                      ),
                                    )
                                    .when(
                                      loading: () =>
                                          const LinearProgressIndicator(),
                                      error: (_, _) => TextButton(
                                        onPressed: () => ref.invalidate(
                                          parentNotificationDeviceModeProvider(
                                            widget.familyId,
                                          ),
                                        ),
                                        child: const Text('读取设备提醒设置失败，重试'),
                                      ),
                                      data: (parentMode) => ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(
                                          parentMode
                                              ? '此设备：家长提醒'
                                              : '此设备：孩子任务提醒',
                                        ),
                                        subtitle: const Text(
                                          '家长提醒模式下不发送孩子任务提醒。打开或恢复应用后检查新消息。',
                                        ),
                                        trailing: TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => _deviceMode(
                                                  inbox,
                                                  !parentMode,
                                                ),
                                          child: Text(
                                            parentMode ? '切换为孩子提醒' : '启用家长提醒',
                                          ),
                                        ),
                                      ),
                                    ),
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(
                                    Icons.notifications_outlined,
                                  ),
                                  title: const Text('家长通知偏好'),
                                  subtitle: Text(
                                    '安静时段 ${inbox.settings.quietStart}–${inbox.settings.quietEnd} · ${inbox.timezone}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: _busy ? null : () => _settings(inbox),
                                ),
                                _remoteControls(inbox),
                                _syncCards(children),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    ChoiceChip(
                                      label: const Text('全部待办'),
                                      selected: !_unreadOnly,
                                      onSelected: (_) =>
                                          setState(() => _unreadOnly = false),
                                    ),
                                    ChoiceChip(
                                      label: Text('未读 ${inbox.unread}'),
                                      selected: _unreadOnly,
                                      onSelected: (_) =>
                                          setState(() => _unreadOnly = true),
                                    ),
                                  ],
                                ),
                                if (inbox.items
                                    .where(
                                      (m) => !_unreadOnly || m.readAt == null,
                                    )
                                    .isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      '暂无消息。兑换处理后会退出待办，每周一上午更新上一周报告。',
                                    ),
                                  ),
                                for (final message in inbox.items.where(
                                  (m) => !_unreadOnly || m.readAt == null,
                                ))
                                  if (children[message.childId]
                                      case final child?)
                                    Card(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            ListTile(
                                              leading: Icon(
                                                message.kind ==
                                                        ParentMessageKind
                                                            .redemption
                                                    ? Icons.redeem_outlined
                                                    : Icons.summarize_outlined,
                                              ),
                                              title: Text(
                                                '${child.nickname} · ${message.title}',
                                              ),
                                              subtitle: Text(message.detail),
                                              trailing: Text(
                                                message.readAt == null
                                                    ? '未读'
                                                    : '已读',
                                              ),
                                              onTap: _busy
                                                  ? null
                                                  : () => _open(message, child),
                                            ),
                                            if (message.readAt == null)
                                              TextButton(
                                                onPressed: _busy
                                                    ? null
                                                    : () => _run(
                                                        () => ref
                                                            .read(
                                                              parentNotificationRepositoryProvider,
                                                            )
                                                            .markRead(
                                                              widget.familyId,
                                                              [message.key],
                                                            ),
                                                      ),
                                                child: const Text('标为已读'),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                              ],
                            ),
                          ),
                        );
                  },
                ),
    );
  }
}

class _SettingsDialog extends ConsumerStatefulWidget {
  const _SettingsDialog({
    required this.settings,
    required this.timezone,
    required this.familyId,
  });
  final ParentNotificationSettings settings;
  final String timezone;
  final String familyId;
  @override
  ConsumerState<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<_SettingsDialog> {
  late bool enabled = widget.settings.enabled,
      redemptions = widget.settings.redemptions,
      syncErrors = widget.settings.syncErrors,
      weekly = widget.settings.weeklyReports;
  late final start = TextEditingController(text: widget.settings.quietStart),
      end = TextEditingController(text: widget.settings.quietEnd);
  String? error;
  @override
  void dispose() {
    start.dispose();
    end.dispose();
    super.dispose();
  }

  void _save() {
    final result = ParentNotificationSettings(
      enabled: enabled,
      redemptions: redemptions,
      syncErrors: syncErrors,
      weeklyReports: weekly,
      quietStart: start.text.trim(),
      quietEnd: end.text.trim(),
      version: widget.settings.version,
    );
    try {
      result.toConfig();
      Navigator.pop(context, result);
    } catch (_) {
      setState(() => error = '安静时段请使用 HH:mm，例如 21:00');
    }
  }

  @override
  Widget build(BuildContext context) =>
      ref.watch(activeParentFamilyProvider) != widget.familyId
      ? AlertDialog(
          title: const Text('家长授权已到期'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回'),
            ),
          ],
        )
      : AlertDialog(
          title: const Text('家长通知偏好'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('接收家长提醒'),
                  value: enabled,
                  onChanged: (v) => setState(() => enabled = v),
                ),
                SwitchListTile(
                  title: const Text('兑换申请'),
                  value: redemptions,
                  onChanged: (v) => setState(() => redemptions = v),
                ),
                SwitchListTile(
                  title: const Text('同步异常'),
                  value: syncErrors,
                  onChanged: (v) => setState(() => syncErrors = v),
                ),
                SwitchListTile(
                  title: const Text('每周学习报告'),
                  value: weekly,
                  onChanged: (v) => setState(() => weekly = v),
                ),
                TextField(
                  controller: start,
                  decoration: const InputDecoration(labelText: '安静开始 HH:mm'),
                ),
                TextField(
                  controller: end,
                  decoration: const InputDecoration(labelText: '安静结束 HH:mm'),
                ),
                Text(
                  '使用家庭时区 ${widget.timezone}；相同起止时间表示不静默。偏好仅影响提醒，消息列表保留当前待办。',
                ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ],
        );
}
