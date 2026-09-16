import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/auth_providers.dart';
import '../application/family_providers.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/notification_scheduler.dart';
import '../../tasks/data/schedule_repository.dart';
import 'family_gate.dart';
import 'login_screen.dart';

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(authSessionProvider, (previous, next) {
      if (!next.hasValue ||
          previous?.valueOrNull?.userId == next.valueOrNull?.userId) {
        return;
      }
      ref.invalidate(parentModeProvider);
      ref.invalidate(parentFamilyIdProvider);
      ref.invalidate(parentAuthorizedUntilProvider);
      ref.invalidate(selectedChildIdProvider);
      ref.invalidate(familiesProvider);
      ref.invalidate(tasksProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(familyTodayProvider);
      ref.invalidate(schedulesProvider);
      ref.invalidate(remindersProvider);
      ref.read(notificationSchedulerProvider).setScope(null).catchError((
        Object error,
      ) {
        ref.read(notificationErrorProvider.notifier).state = '清除提醒失败：$error';
      });
    });
    return ref
        .watch(authSessionProvider)
        .when(
          data: (session) =>
              session == null ? const LoginScreen() : const FamilyGate(),
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (error, stackTrace) =>
              Scaffold(body: Center(child: Text('登录状态读取失败：$error'))),
        );
  }
}
