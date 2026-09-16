import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../tasks/application/task_providers.dart';

import '../../home/presentation/home_screen.dart';
import '../application/auth_providers.dart';
import '../application/family_providers.dart';
import 'family_management_screen.dart';
import 'family_onboarding_screen.dart';
import '../../tasks/presentation/task_management_screen.dart';
import '../../tasks/presentation/reminder_coordinator.dart';
import '../../tasks/data/notification_scheduler.dart';

class FamilyGate extends ConsumerWidget {
  const FamilyGate({super.key});

  Future<bool> _clearNotifications(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(notificationSchedulerProvider).setScope(null);
      return context.mounted;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清除旧通知失败，请重试：$error')));
      }
      return false;
    }
  }

  Future<bool> _exitParentMode(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(familyRepositoryProvider).revokeParentAuthorization();
      if (!context.mounted) return false;
      ref.read(parentModeProvider.notifier).state = false;
      ref.read(parentFamilyIdProvider.notifier).state = null;
      ref.read(parentAuthorizedUntilProvider.notifier).state = null;
      return true;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('撤销服务端授权失败，请重试：$error')));
      }
      return false;
    }
  }

  Future<void> _enterParentMode(
    BuildContext context,
    WidgetRef ref,
    String familyId,
  ) async {
    var enteredPin = '';
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入家长 PIN'),
        content: TextField(
          onChanged: (value) => enteredPin = value,
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
            onPressed: () => Navigator.pop(context, enteredPin),
            child: const Text('验证'),
          ),
        ],
      ),
    );
    if (pin == null || pin.isEmpty || !context.mounted) return;

    try {
      final result = await ref
          .read(familyRepositoryProvider)
          .verifyParentPin(familyId: familyId, pin: pin);
      if (!context.mounted) return;
      if (result.verified) {
        if (result.authorizedUntil == null) {
          throw StateError('请先部署服务端 PIN 授权迁移');
        }
        ref.read(parentAuthorizedUntilProvider.notifier).state =
            result.authorizedUntil;
        ref.read(parentFamilyIdProvider.notifier).state = familyId;
        ref.read(parentModeProvider.notifier).state = true;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已进入家长模式')));
      } else {
        final message = result.retryAt == null
            ? 'PIN 错误，还可尝试 ${result.remainingAttempts} 次'
            : '尝试次数过多，请稍后再试';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (error) {
      if (!context.mounted) return;
      if (error is PostgrestException &&
          error.message == 'Parent PIN is not configured' &&
          RegExp(r'^\d{4,6}$').hasMatch(pin)) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('首次设置家长 PIN'),
            content: const Text('此家庭尚未设置 PIN。是否将刚输入的数字设为家长 PIN？仅家庭管理员可设置。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认设置'),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        try {
          await ref
              .read(familyRepositoryProvider)
              .setParentPin(familyId: familyId, pin: pin);
          final verified = await ref
              .read(familyRepositoryProvider)
              .verifyParentPin(familyId: familyId, pin: pin);
          if (!verified.verified || verified.authorizedUntil == null) {
            throw StateError('服务端未授予家长授权');
          }
          if (!context.mounted) return;
          ref.read(parentAuthorizedUntilProvider.notifier).state =
              verified.authorizedUntil;
          ref.read(parentFamilyIdProvider.notifier).state = familyId;
          ref.read(parentModeProvider.notifier).state = true;
        } catch (setupError) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('设置失败：$setupError')));
          }
        }
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('验证失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(familiesProvider)
        .when(
          data: (families) {
            if (families.isEmpty) return const FamilyOnboardingScreen();
            final children = families
                .expand((family) => family.children)
                .toList();
            if (children.isEmpty) return const FamilyOnboardingScreen();
            final selectedId = ref.watch(selectedChildIdProvider);
            final parentFamilyId = ref.watch(activeParentFamilyProvider);
            final child = children.firstWhere(
              (item) => item.id == selectedId,
              orElse: () => children.first,
            );
            final isParentMode = parentFamilyId == child.familyId;
            return ReminderCoordinator(
              childId: child.id,
              child: HomeScreen(
                childNickname: child.nickname,
                children: children,
                selectedChildId: child.id,
                onChildSelected: (id) async {
                  if (!await _exitParentMode(context, ref)) return;
                  if (!context.mounted) return;
                  if (!await _clearNotifications(context, ref)) return;
                  ref.read(selectedChildIdProvider.notifier).state = id;
                },
                onManageFamily: () async {
                  if (!isParentMode) {
                    await _enterParentMode(context, ref, child.familyId);
                  }
                  if (!context.mounted ||
                      ref.read(activeParentFamilyProvider) != child.familyId) {
                    return;
                  }
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FamilyManagementScreen(),
                    ),
                  );
                },
                onManageTasks: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TaskManagementScreen(
                        childId: child.id,
                        childNickname: child.nickname,
                        familyId: child.familyId,
                        isParentMode: isParentMode,
                      ),
                    ),
                  );
                  if (!context.mounted) return;
                  ref.invalidate(tasksProvider(child.id));
                  ref.invalidate(walletProvider(child.id));
                },
                isParentMode: isParentMode,
                onParentMode: () {
                  if (isParentMode) {
                    _exitParentMode(context, ref);
                  } else {
                    _enterParentMode(context, ref, child.familyId);
                  }
                },
                onSignOut: () async {
                  if (!await _exitParentMode(context, ref)) return;
                  if (!context.mounted) return;
                  if (!await _clearNotifications(context, ref)) return;
                  ref.read(parentModeProvider.notifier).state = false;
                  ref.read(parentFamilyIdProvider.notifier).state = null;
                  ref.read(selectedChildIdProvider.notifier).state = null;
                  await ref.read(authRepositoryProvider).signOut();
                  ref.invalidate(familiesProvider);
                },
              ),
            );
          },
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (error, stackTrace) =>
              Scaffold(body: Center(child: Text('家庭数据读取失败：$error'))),
        );
  }
}
