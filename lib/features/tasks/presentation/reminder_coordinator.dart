import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../application/task_providers.dart';
import '../data/schedule_repository.dart';
import '../data/offline_task_repository.dart';
import '../data/notification_scheduler.dart';
import '../../wrong_questions/data/question_media_repository.dart';
import '../../wrong_questions/data/offline_question_media_repository.dart';
import '../../auth_family/application/family_providers.dart';
import '../../notifications/data/parent_notification_device.dart';
import '../../reports/data/family_activity_recorder.dart';
import '../../reports/data/configuration_time_recorder.dart';

class ReminderCoordinator extends ConsumerStatefulWidget {
  const ReminderCoordinator({
    required this.childId,
    required this.familyId,
    required this.child,
    this.familyTimezone = 'Asia/Shanghai',
    super.key,
  });
  final String childId;
  final String familyId;
  final String familyTimezone;
  final Widget child;
  @override
  ConsumerState<ReminderCoordinator> createState() =>
      _ReminderCoordinatorState();
}

class _ReminderCoordinatorState extends ConsumerState<ReminderCoordinator>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true, _working = false, _again = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    ref.read(configurationTimeRecorderProvider)?.setForeground(_foreground);
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_synchronize()),
    );
    final repository = ref.read(taskRepositoryProvider);
    if (repository is OfflineTaskRepository) {
      repository.setForeground(_foreground);
    }
    unawaited(_synchronize());
  }

  @override
  void didUpdateWidget(covariant ReminderCoordinator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.childId != widget.childId ||
        oldWidget.familyId != widget.familyId ||
        oldWidget.familyTimezone != widget.familyTimezone) {
      unawaited(_synchronize());
    }
  }

  Future<void> _synchronize() async {
    if (!_foreground || !mounted) return;
    if (_working) {
      _again = true;
      return;
    }
    _working = true;
    try {
      unawaited(ref.read(configurationTimeRecorderProvider)?.flush());
      final family = widget.familyId;
      unawaited(
        ref
            .read(familyActivityRecorderProvider)
            ?.observe(
              family,
              widget.familyTimezone,
              isCurrent: () =>
                  mounted && _foreground && widget.familyId == family,
            ),
      );
      await _refreshNotifications();
    } finally {
      _working = false;
      if (_again && mounted && _foreground) {
        _again = false;
        unawaited(_synchronize());
      }
    }
  }

  Future<void> _refreshNotifications() async {
    if (taskSupabaseClient(ref.read(taskRepositoryProvider)) == null) return;
    final media = ref.read(questionMediaRepositoryProvider);
    if (media is OfflineQuestionMediaRepository) media.kick();
    final childId = widget.childId;
    final familyId = widget.familyId;
    final scheduler = ref.read(notificationSchedulerProvider);
    try {
      final device = ref.read(parentNotificationDeviceProvider);
      if (device != null &&
          await device.refresh(
            familyId,
            childId,
            isCurrent: () =>
                mounted &&
                _foreground &&
                widget.childId == childId &&
                widget.familyId == familyId,
          )) {
        if (mounted && widget.childId == childId) {
          ref.read(notificationErrorProvider.notifier).state = null;
        }
        return;
      }
      if (!mounted || !_foreground || widget.childId != childId) return;
      await scheduler.setScope(childId);
      final rows = await ref
          .read(scheduleRepositoryProvider)
          .loadReminders(childId);
      if (!mounted || widget.childId != childId) return;
      await scheduler.synchronize(childId, rows);
      if (mounted) ref.read(notificationErrorProvider.notifier).state = null;
    } catch (error) {
      if (mounted && widget.childId == childId) {
        ref.read(notificationErrorProvider.notifier).state = '提醒同步失败：$error';
        if (error is PostgrestException && error.code == '42501') {
          try {
            await scheduler.setScope(null);
          } catch (clearError) {
            if (mounted && widget.childId == childId) {
              ref.read(notificationErrorProvider.notifier).state =
                  '提醒访问已撤销，清理旧通知失败：$clearError';
            }
          }
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    ref.read(configurationTimeRecorderProvider)?.setForeground(_foreground);
    final repository = ref.read(taskRepositoryProvider);
    if (repository is OfflineTaskRepository) {
      repository.setForeground(state == AppLifecycleState.resumed);
      final media = ref.read(questionMediaRepositoryProvider);
      if (media is OfflineQuestionMediaRepository) {
        media.setForeground(state == AppLifecycleState.resumed);
      }
    }
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(familyTodayProvider(widget.childId));
      ref.invalidate(tasksProvider(widget.childId));
      unawaited(_synchronize());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      parentNotificationDeviceRevisionProvider,
      (_, _) => unawaited(_synchronize()),
    );
    ref.listen(activeParentFamilyProvider, (_, family) {
      if (family != null &&
          taskSupabaseClient(ref.read(taskRepositoryProvider)) != null) {
        final media = ref.read(questionMediaRepositoryProvider);
        if (media is OfflineQuestionMediaRepository) {
          media.kick(retryBlocked: true);
        }
      }
    });
    ref.listen(tasksProvider(widget.childId), (_, value) {
      if (value.hasValue) unawaited(_synchronize());
    });
    ref.listen(remindersProvider(widget.childId), (_, value) {
      if (value.hasValue) unawaited(_synchronize());
    });
    return widget.child;
  }
}
