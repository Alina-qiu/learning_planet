import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/auth_providers.dart';
import '../application/family_providers.dart';
import '../data/auth_repository.dart';
import '../data/onboarding_repository.dart';
import '../../tasks/application/task_providers.dart';
import '../../tasks/data/notification_scheduler.dart';
import '../../tasks/data/schedule_repository.dart';
import '../../tasks/data/offline_task_repository.dart';
import '../../tasks/data/task_notes.dart';
import '../../tasks/data/task_time_corrections.dart';
import '../../wrong_questions/data/review_repository.dart';
import '../../wrong_questions/data/question_media_repository.dart';
import '../../wrong_questions/data/child_question_submissions.dart';
import '../../wrong_questions/data/question_catalog.dart';
import '../../wrong_questions/data/cleanup_repository.dart';
import '../../worksheets/data/worksheet_repository.dart';
import '../../economy/data/economy_repository.dart';
import '../../economy/data/economy_commands.dart';
import '../../reports/data/family_overview_repository.dart';
import '../../reports/data/report_repository.dart';
import '../../growth/data/growth_repository.dart';
import '../../data_management/data/child_export_repository.dart';
import '../../data_management/data/child_deletion_repository.dart';
import '../../data_management/presentation/account_deletion_gate.dart';
import '../../data_management/data/account_deletion_repository.dart';
import 'login_screen.dart';
import 'entry_recovery_screen.dart';

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(authRepositoryProvider) is UnconfiguredAuthRepository) {
      return Scaffold(
        appBar: AppBar(title: const Text('学习星球')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.construction_outlined, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      '调试版本尚未连接服务',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '当前安装包可用于本机启动验证。登录和家庭功能需连接开发服务后使用。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    ref.listen(authSessionProvider, (previous, next) {
      if (!next.hasValue ||
          previous?.valueOrNull?.userId == next.valueOrNull?.userId) {
        return;
      }
      ref.invalidate(parentModeProvider);
      ref.read(parentAuthorizationRevisionProvider.notifier).state++;
      ref.invalidate(parentFamilyIdProvider);
      ref.invalidate(parentAuthorizedUntilProvider);
      ref.invalidate(selectedChildIdProvider);
      ref.invalidate(familiesProvider);
      ref.invalidate(onboardingProvider);
      ref.invalidate(tasksProvider);
      ref.invalidate(taskNotesProvider);
      ref.invalidate(taskTimeCorrectionsProvider);
      ref.invalidate(childQuestionSubmissionsProvider);
      ref.invalidate(questionCatalogRepositoryProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(familyTodayProvider);
      ref.invalidate(schedulesProvider);
      ref.invalidate(remindersProvider);
      ref.invalidate(reviewQuestionsProvider);
      ref.invalidate(reviewOverviewProvider);
      ref.invalidate(reviewTaskProvider);
      ref.invalidate(questionProvenanceProvider);
      ref.invalidate(questionImageUrlProvider);
      ref.invalidate(imageDraftsProvider);
      ref.invalidate(questionMediaRepositoryProvider);
      ref.invalidate(economyDataProvider);
      ref.invalidate(economyRepositoryProvider);
      ref.invalidate(pendingEconomyCommandProvider);
      ref.invalidate(learningReportProvider);
      ref.invalidate(familyOverviewProvider);
      ref.invalidate(growthProvider);
      ref.invalidate(growthRepositoryProvider);
      ref.invalidate(learningEventsProvider);
      ref.invalidate(childExportPreviewProvider);
      ref.invalidate(childDeletionHistoryProvider);
      ref.invalidate(accountDeletionStatusProvider);
      ref.invalidate(remotelyDeletedChildProvider);
      ref.invalidate(cleanupJobsProvider);
      ref.invalidate(worksheetHistoryProvider);
      ref.invalidate(worksheetBytesProvider);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      // Close imperative editors/detail routes carrying the previous account's data.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
      final tasks = ref.read(taskRepositoryProvider);
      if (tasks is OfflineTaskRepository) tasks.scopeChanged();
      ref.read(notificationSchedulerProvider).setScope(null).catchError((
        Object _,
      ) {
        ref.read(notificationErrorProvider.notifier).state = '清除旧提醒失败，请重试。';
      });
    });
    return ref
        .watch(authSessionProvider)
        .when(
          data: (session) => session == null
              ? const LoginScreen()
              : const AccountDeletionGate(),
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (error, stackTrace) => EntryRecoveryScreen(
            check: EntryCheck.session,
            error: error,
            retrying: ref.watch(authSessionProvider).isLoading,
            onRetry: () => ref.invalidate(authSessionProvider),
          ),
        );
  }
}
