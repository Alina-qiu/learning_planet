import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/task_providers.dart';
import '../data/schedule_repository.dart';
import '../data/task_repository.dart';
import '../data/notification_scheduler.dart';

class ReminderCoordinator extends ConsumerStatefulWidget {
  const ReminderCoordinator({
    required this.childId,
    required this.child,
    super.key,
  });
  final String childId;
  final Widget child;
  @override
  ConsumerState<ReminderCoordinator> createState() =>
      _ReminderCoordinatorState();
}

class _ReminderCoordinatorState extends ConsumerState<ReminderCoordinator>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_synchronize());
  }

  @override
  void didUpdateWidget(covariant ReminderCoordinator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.childId != widget.childId) unawaited(_synchronize());
  }

  Future<void> _synchronize() async {
    if (ref.read(taskRepositoryProvider) is! SupabaseTaskRepository) return;
    final childId = widget.childId;
    final scheduler = ref.read(notificationSchedulerProvider);
    try {
      await scheduler.setScope(childId);
      final rows = await ref
          .read(scheduleRepositoryProvider)
          .loadReminders(childId);
      if (!mounted || widget.childId != childId) return;
      await scheduler.synchronize(childId, rows);
      if (mounted) ref.read(notificationErrorProvider.notifier).state = null;
    } catch (error) {
      if (mounted) {
        ref.read(notificationErrorProvider.notifier).state = '提醒同步失败：$error';
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(familyTodayProvider(widget.childId));
      ref.invalidate(tasksProvider(widget.childId));
      unawaited(_synchronize());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tasksProvider(widget.childId), (_, value) {
      if (value.hasValue) unawaited(_synchronize());
    });
    ref.listen(remindersProvider(widget.childId), (_, value) {
      if (value.hasValue) unawaited(_synchronize());
    });
    return widget.child;
  }
}
