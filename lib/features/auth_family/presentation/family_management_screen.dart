import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/family_providers.dart';
import '../domain/family.dart';

class FamilyManagementScreen extends ConsumerWidget {
  const FamilyManagementScreen({super.key});

  Future<void> _inviteParent(
    BuildContext context,
    WidgetRef ref,
    String familyId,
  ) async {
    final controller = TextEditingController();
    final email = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('邀请家长'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: '家长邮箱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('发送邀请'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (email == null || !email.contains('@')) return;
    await ref.read(familyRepositoryProvider).inviteParent(
          familyId: familyId,
          email: email,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('邀请已创建，对方登录后将自动加入家庭')),
      );
    }
  }

  Future<void> _setParentPin(
    BuildContext context,
    WidgetRef ref,
    String familyId,
  ) async {
    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置家长 PIN'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '4 至 6 位数字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pin == null || !RegExp(r'^\d{4,6}$').hasMatch(pin)) return;
    await ref.read(familyRepositoryProvider).setParentPin(
          familyId: familyId,
          pin: pin,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('家长 PIN 已更新')),
      );
    }
  }

  Future<void> _editChild(
    BuildContext context,
    WidgetRef ref,
    String familyId, [
    ChildProfile? child,
  ]) async {
    final nicknameController = TextEditingController(text: child?.nickname);
    var grade = child?.grade ?? 1;
    final result = await showDialog<({String nickname, int grade})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(child == null ? '添加孩子' : '编辑孩子档案'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nicknameController,
                decoration: const InputDecoration(labelText: '孩子昵称'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: grade,
                decoration: const InputDecoration(labelText: '年级'),
                items: [
                  for (var value = 1; value <= 6; value++)
                    DropdownMenuItem(value: value, child: Text('$value 年级')),
                ],
                onChanged: (value) =>
                    setDialogState(() => grade = value ?? grade),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final nickname = nicknameController.text.trim();
                if (nickname.isNotEmpty) {
                  Navigator.pop(context, (nickname: nickname, grade: grade));
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nicknameController.dispose();
    if (result == null) return;

    final repository = ref.read(familyRepositoryProvider);
    if (child == null) {
      await repository.createChild(
        familyId: familyId,
        nickname: result.nickname,
        grade: result.grade,
      );
    } else {
      await repository.updateChild(
        childId: child.id,
        nickname: result.nickname,
        grade: result.grade,
      );
    }
    ref.invalidate(familiesProvider);
  }

  Future<void> _deleteChild(
    BuildContext context,
    WidgetRef ref,
    ChildProfile child,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除孩子档案？'),
        content: Text('将删除 ${child.nickname} 的档案及关联数据。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(familyRepositoryProvider).deleteChild(child.id);
    ref.read(selectedChildIdProvider.notifier).state = null;
    ref.invalidate(familiesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('家庭与孩子')),
      body: ref.watch(familiesProvider).when(
            data: (families) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final family in families) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      family.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    subtitle: Text(family.timezone),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        IconButton(
                          tooltip: '邀请家长',
                          onPressed: () =>
                              _inviteParent(context, ref, family.id),
                          icon: const Icon(Icons.group_add_outlined),
                        ),
                        OutlinedButton(
                          onPressed: () =>
                              _setParentPin(context, ref, family.id),
                          child: const Text('家长 PIN'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => _editChild(context, ref, family.id),
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('添加孩子'),
                        ),
                      ],
                    ),
                  ),
                  for (final child in family.children)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.child_care),
                        ),
                        title: Text(child.nickname),
                        subtitle: Text('${child.grade} 年级'),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: '编辑',
                              onPressed: () =>
                                  _editChild(context, ref, family.id, child),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: '删除',
                              onPressed: family.children.length <= 1
                                  ? null
                                  : () => _deleteChild(context, ref, child),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                ],
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Text('家庭数据读取失败：$error'),
            ),
          ),
    );
  }
}
