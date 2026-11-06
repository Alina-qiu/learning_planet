import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/family_providers.dart';
import '../application/auth_providers.dart';
import '../domain/family.dart';
import 'app_sign_out.dart';
import 'child_profile_editor.dart';
import 'family_members_screen.dart';
import 'family_time_screen.dart';
import '../../ai/presentation/ai_settings_screen.dart';
import '../../notifications/presentation/parent_notifications_screen.dart';
import 'child_profile_fields.dart';
import '../../data_management/presentation/child_export_screen.dart';
import '../../data_management/presentation/child_deletion_screen.dart';
import '../../data_management/presentation/account_deletion_screen.dart';

class FamilyManagementScreen extends ConsumerStatefulWidget {
  const FamilyManagementScreen({super.key});

  @override
  ConsumerState<FamilyManagementScreen> createState() =>
      _FamilyManagementScreenState();
}

class _FamilyManagementScreenState
    extends ConsumerState<FamilyManagementScreen> {
  bool _changingPin = false;

  Future<void> _guard(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    }
  }

  Future<void> _setParentPin(
    BuildContext context,
    WidgetRef ref,
    String familyId,
  ) async {
    if (_changingPin) return;
    final auth = ref.read(authRepositoryProvider);
    final owner = auth.currentSession?.userId;
    final repository = ref.read(familyRepositoryProvider);
    final revision = ref.read(parentAuthorizationRevisionProvider);
    bool current() =>
        mounted &&
        context.mounted &&
        owner != null &&
        identical(ref.read(authRepositoryProvider), auth) &&
        auth.currentSession?.userId == owner &&
        identical(ref.read(familyRepositoryProvider), repository) &&
        !ref.read(signingOutProvider) &&
        ref.read(parentAuthorizationRevisionProvider) == revision &&
        ref.read(activeParentFamilyProvider) == familyId;
    if (!current()) return;
    setState(() => _changingPin = true);
    var submitted = false, saved = false;
    try {
      var input = '';
      final form = GlobalKey<FormState>();
      final pin = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('设置家长 PIN'),
          content: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('仅家庭管理员可修改。其他设备下次进入家长模式时请使用新 PIN。'),
                  const SizedBox(height: 12),
                  TextFormField(
                    onChanged: (value) => input = value,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: '新 PIN',
                      helperText: '4至6位数字',
                      helperMaxLines: 2,
                      errorMaxLines: 2,
                    ),
                    validator: (value) =>
                        RegExp(r'^\d{4,6}$').hasMatch(value ?? '')
                        ? null
                        : '请输入4至6位数字',
                  ),
                  TextFormField(
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 6,
                    decoration: const InputDecoration(labelText: '再次输入新 PIN'),
                    validator: (value) => value == input && input.isNotEmpty
                        ? null
                        : '两次 PIN 不一致',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(dialogContext, input);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (pin == null || !current()) return;
      submitted = true;
      await repository.setParentPin(familyId: familyId, pin: pin);
      saved = true;
      if (!current()) return;
      final verified = await repository.verifyParentPin(
        familyId: familyId,
        pin: pin,
      );
      if (!context.mounted || !current()) return;
      if (!verified.verified ||
          verified.authorizedUntil == null ||
          !verified.authorizedUntil!.isAfter(DateTime.now())) {
        clearLocalParentAuthorization(ref);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN 已保存，但未取得有效家长授权。请返回首页重新验证 PIN。')),
        );
        return;
      }
      ref.read(parentFamilyIdProvider.notifier).state = familyId;
      ref.read(parentAuthorizedUntilProvider.notifier).state =
          verified.authorizedUntil;
      ref.read(parentModeProvider.notifier).state = true;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('家长 PIN 已更新')));
    } catch (error) {
      if (!context.mounted || !current()) return;
      // A transport error can happen after the server committed. Do not retry
      // the mutation or claim success; close only this still-current elevation.
      if (submitted) clearLocalParentAuthorization(ref);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? 'PIN 已保存，但重新验证未完成。请返回首页重新验证 PIN。'
                : error is PostgrestException &&
                      const {'42501', 'P0001', '22023'}.contains(error.code)
                ? 'PIN 修改未被服务端接受。请确认管理员权限后重新验证家长 PIN。'
                : '尚未确认 PIN 是否保存。请返回首页先用新 PIN 核对；不要连续猜测。',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _changingPin = false);
    }
  }

  Future<void> _editChild(
    BuildContext context,
    WidgetRef ref,
    String familyId, [
    ChildProfile? child,
  ]) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ChildProfileEditor(familyId: familyId, child: child),
      ),
    );
    if (!context.mounted) return;
    ref.invalidate(familiesProvider);
  }

  Future<void> _deleteChild(
    BuildContext context,
    WidgetRef ref,
    ChildProfile child,
  ) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChildDeletionScreen(
          familyId: child.familyId,
          childId: child.id,
          nickname: child.nickname,
        ),
      ),
    );
    if (context.mounted) ref.invalidate(familiesProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('家庭与孩子'),
        actions: [
          IconButton(
            tooltip: '注销我的账号',
            icon: const Icon(Icons.person_remove_outlined),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const AccountDeletionScreen()),
            ),
          ),
        ],
      ),
      body: ref.watch(activeParentFamilyProvider) == null
          ? const Center(child: Text('家长授权已到期，请返回首页重新验证 PIN'))
          : ref
                .watch(familiesProvider)
                .when(
                  data: (families) => ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final family in families.where(
                        (f) => f.id == ref.watch(activeParentFamilyProvider),
                      )) ...[
                        ListTile(
                          leading: const Icon(Icons.notifications_outlined),
                          title: const Text('家长消息'),
                          subtitle: const Text('兑换申请、同步异常与周报'),
                          onTap: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ParentNotificationsScreen(
                                familyId: family.id,
                              ),
                            ),
                          ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.privacy_tip_outlined),
                          title: const Text('AI 与隐私'),
                          subtitle: const Text('分析开关、额度与正文保留期限'),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  AiSettingsScreen(familyId: family.id),
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              family.name,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(family.timezone),
                            TextButton.icon(
                              onPressed: () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      FamilyTimeScreen(familyId: family.id),
                                ),
                              ),
                              icon: const Icon(Icons.public),
                              label: const Text('家庭时区'),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                IconButton(
                                  tooltip: '孩子删除记录',
                                  icon: const Icon(Icons.history),
                                  onPressed: () =>
                                      Navigator.of(context).push<void>(
                                        MaterialPageRoute(
                                          builder: (_) => ChildDeletionScreen(
                                            familyId: family.id,
                                          ),
                                        ),
                                      ),
                                ),
                                IconButton(
                                  tooltip: '家庭成员与邀请',
                                  onPressed: () =>
                                      Navigator.of(context).push<void>(
                                        MaterialPageRoute(
                                          builder: (_) => FamilyMembersScreen(
                                            familyId: family.id,
                                          ),
                                        ),
                                      ),
                                  icon: const Icon(Icons.group_add_outlined),
                                ),
                                OutlinedButton(
                                  onPressed: _changingPin
                                      ? null
                                      : () => _guard(
                                          context,
                                          () => _setParentPin(
                                            context,
                                            ref,
                                            family.id,
                                          ),
                                        ),
                                  child: Text(
                                    _changingPin ? 'PIN 设置中…' : '家长 PIN',
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: () => _guard(
                                    context,
                                    () => _editChild(context, ref, family.id),
                                  ),
                                  icon: const Icon(Icons.person_add_alt_1),
                                  label: const Text('添加孩子'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                        for (final child in family.children)
                          Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ListTile(
                                  leading: ChildAvatar(
                                    avatarKey: child.avatarKey,
                                  ),
                                  title: Text(child.nickname),
                                  subtitle: Text(
                                    '${child.grade} 年级${child.textbookLabels.isEmpty ? '' : '\n${child.textbookLabels.entries.map((entry) => '${textbookSubjects[entry.key]}：${entry.value}').join(' · ')}'}',
                                  ),
                                ),
                                Wrap(
                                  alignment: WrapAlignment.end,
                                  children: [
                                    IconButton(
                                      tooltip: '编辑',
                                      onPressed: () => _guard(
                                        context,
                                        () => _editChild(
                                          context,
                                          ref,
                                          family.id,
                                          child,
                                        ),
                                      ),
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                    IconButton(
                                      tooltip: '导出孩子数据',
                                      onPressed: () =>
                                          Navigator.of(context).push<void>(
                                            MaterialPageRoute(
                                              builder: (_) => ChildExportScreen(
                                                childId: child.id,
                                                familyId: family.id,
                                                nickname: child.nickname,
                                              ),
                                            ),
                                          ),
                                      icon: const Icon(Icons.download_outlined),
                                    ),
                                    IconButton(
                                      tooltip: '删除',
                                      onPressed: () => _guard(
                                        context,
                                        () => _deleteChild(context, ref, child),
                                      ),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 20),
                      ],
                    ],
                  ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, stackTrace) =>
                      Center(child: Text('家庭数据读取失败：$error')),
                ),
    );
  }
}
