import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/auth_providers.dart';
import '../application/family_providers.dart';
import '../../tasks/data/notification_scheduler.dart';

void clearLocalParentAuthorization(WidgetRef ref) {
  ref.read(parentAuthorizationRevisionProvider.notifier).state++;
  ref.read(parentModeProvider.notifier).state = false;
  ref.read(parentFamilyIdProvider.notifier).state = null;
  ref.read(parentAuthorizedUntilProvider.notifier).state = null;
}

/// Every exit entry uses the same local cleanup and error handling. Logout does
/// not erase account-scoped offline commands; signing in again can sync them.
Future<void> signOutOfApp(BuildContext context, WidgetRef ref) async {
  final busy = ref.read(signingOutProvider.notifier);
  if (busy.state) return;
  final repository = ref.read(authRepositoryProvider);
  final owner = repository.currentSession?.userId;
  final scheduler = ref.read(notificationSchedulerProvider);
  busy.state = true;
  clearLocalParentAuthorization(ref);
  try {
    await scheduler.setScope(null);
    if (!context.mounted || repository.currentSession?.userId != owner) return;
    await repository.signOut();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('退出未完成，本机家长权限已关闭。请重试。')));
    }
  } finally {
    if (busy.mounted) busy.state = false;
  }
}

class AppSignOutButton extends ConsumerWidget {
  const AppSignOutButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    onPressed: ref.watch(signingOutProvider)
        ? null
        : () => signOutOfApp(context, ref),
    child: Text(ref.watch(signingOutProvider) ? '正在退出…' : '退出登录'),
  );
}
