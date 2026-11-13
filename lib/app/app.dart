import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth_family/application/auth_providers.dart';
import '../features/auth_family/application/family_providers.dart';
import '../features/auth_family/data/auth_repository.dart';
import '../features/auth_family/data/family_repository.dart';
import '../features/auth_family/presentation/auth_gate.dart';
import '../features/tasks/application/task_providers.dart';
import '../features/tasks/data/task_repository.dart';
import '../features/tasks/data/notification_scheduler.dart';
import '../features/notifications/data/remote_parent_push.dart';
import '../features/notifications/presentation/remote_push_lifecycle.dart';
import 'theme.dart';

class LearningPlanetApp extends StatelessWidget {
  const LearningPlanetApp({
    required this.authRepository,
    required this.familyRepository,
    required this.taskRepository,
    this.notificationScheduler = const DisabledNotificationScheduler(),
    this.remotePush,
    super.key,
  });

  final AuthRepository authRepository;
  final FamilyRepository familyRepository;
  final TaskRepository taskRepository;
  final NotificationScheduler notificationScheduler;
  final RemoteParentPush? remotePush;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(authRepository),
        familyRepositoryProvider.overrideWithValue(familyRepository),
        taskRepositoryProvider.overrideWithValue(taskRepository),
        notificationSchedulerProvider.overrideWithValue(notificationScheduler),
        remoteParentPushProvider.overrideWithValue(remotePush),
      ],
      child: MaterialApp(
        title: '学习星球',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        builder: (context, child) => Consumer(
          builder: (context, ref, _) {
            final busy = ref.watch(signingOutProvider);
            return Stack(
              children: [
                if (child != null)
                  ExcludeSemantics(excluding: busy, child: child),
                if (busy) ...[
                  const ModalBarrier(
                    dismissible: false,
                    color: Color(0x66000000),
                  ),
                  Center(
                    child: Semantics(
                      label: '正在安全退出登录',
                      child: const CircularProgressIndicator(),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        home: RemotePushLifecycle(
          controller: remotePush,
          child: const AuthGate(),
        ),
      ),
    );
  }
}
